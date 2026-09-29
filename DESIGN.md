# Design notes

How the design works and why it ended up this way, with the measurements
behind each decision. Numbers are from the Nasdaq
TotalView-ITCH 5.0 sample of 2019-07-30 (first 32.6M messages, 04:00 to 09:47 ET)
and the eight default symbols QQQ, SPY, IWM, DIA, TQQQ, SQQQ, AMD, UVXY.

## 1. Why this pipeline shape

```
MAC bytes -> Frame_parser -> Mold_parser -> Itch_decoder -> Symbol_filter -> FIFO -> Order_book -> event
            (1 byte/cycle, no back-pressure, cut-through)                   (one command at a time)
```

Everything up to the FIFO runs at one byte per cycle with no back-pressure,
because a MAC cannot be stalled: at 1 Gb/s with a 125 MHz byte clock there is
exactly one byte per cycle while a frame is on the wire. Each stage is a byte
counter plus comparisons against fixed offsets. Nothing is buffered, so a
message's fields are decoded a few registered stages after its last byte
arrives; `verify` measures the exact end-to-end latency.

The order book is a sequential state machine that takes one command at a time
from a FIFO. The smallest message that touches the book is an Order Delete:
19 bytes plus a 2-byte length, so 21 cycles on the wire at the very least,
and more once packet headers and gaps are counted. The FIFO absorbs command
bursts and the rare level-table refill. The full-replay test reports its
peak occupancy, overflows, and per-command latency.
Pipelining the book (overlapping commands) would be the next step for a
10 Gb/s version, at the cost of hazard logic between commands that touch the
same bucket.

## 2. Cut-through: the FCS arrives last

The Ethernet FCS, the IPv4 header checksum and the UDP checksum are not
checked before messages are acted on. The FCS arrives after the payload, so
waiting for it means buffering the whole frame (up to ~12 us at 1 Gb/s for
a 1500-byte frame) before the first message can be processed. Commercial
feed handlers generally process cut-through as well. They rely on the rarity
of corrupt frames on a short, clean link, and on MoldUDP64 sequence numbers
to detect loss. The receive MAC here still computes the CRC and counts bad
frames (`fcs=` on the board), so a bad link shows up immediately. A safer
variant would hold the book's writes for a frame until its FCS arrives. That
adds only the frame's remaining length to the latency, not a full
store-and-forward.

## 3. Sizing: what has to fit in the FPGA

`itch_tool profile` and `itch_tool hwmodel` measured this before any RTL was written:

| | measured | capacity |
|---|---|---|
| live orders, 8 default symbols, peak | 27,573 | 32,768 (84% at peak) |
| price levels, all book sides, peak | 7,633 | 16,384 (47%) |
| price levels on one book side, peak | 1,672 (QQQ bids) | shared pool |
| price range seen | $0.0001 to $199,999.99 | 32 bits |
| new levels created ≥ 64 levels behind the best | 20% | |

The last two rows rule out the two textbook structures:
- **A price-indexed ladder** (an array indexed by price, plus a bitmap to
  find the best level) cannot cover $0.0001 to $200,000 exactly. Stub quotes
  far from the market are real orders, and they become the best price
  whenever a thin pre-market book empties.
- **Keeping all levels sorted** in a BRAM array, or in a linked list walked
  from the best level, costs time proportional to how far behind the best a
  new level lands, and that is often hundreds of levels.

The big single stocks (AAPL, AMZN, TSLA) each carry 20–28K resting orders.
The XC7A100T's 4.86 Mb of BRAM therefore caps the book at about 32K orders.
The default symbol set is busy ETFs, which have high message rates and thin
books, plus AMD. A larger part, or UltraRAM, removes this limit without any
change to the design.

## 4. Order table: hashing and collisions

- **Key:** the order reference (32 bits; references past 2^32 are counted as
  unsupported and ignored; in a full day they stay below 2^31).
- **Hash:** H3 universal hashing. Bucket-index bit *i* is the parity of the
  key ANDed with a fixed random mask. In hardware that is one XOR tree per
  index bit: two LUT levels, no DSP, no pipeline. References are assigned
  sequentially across all 8,000 stocks, so the tracked subset is effectively
  random, and H3 spreads 65,536 sequential references at 15–17 per bucket
  (ideal: 16).
- **Organisation:** two banks, each with 4,096 buckets × 4 ways, and a
  different hash per bank. A lookup reads bucket h0(ref) of bank 0 and
  h1(ref) of bank 1 in the same cycle: 8 candidates, 8 comparators.
- **Collisions:** an insert goes to whichever of the two buckets has more
  free ways. The first design stopped there, as greedy two-choice hashing.
  The architectural model showed that at 84% load this overflows 99,187
  times over the day. With four ways per bucket, the fullest bucket under
  greedy two-choice sits about ln ln n / ln 2 above the mean, which is more
  than four.
- **Fix: cuckoo displacement.** When both buckets are full, the new entry
  takes a victim's place (round-robin way). The victim moves to its bucket in
  the other bank, possibly displacing another, for at most 32 moves. On the
  full day that needed 243,441 moves in total, at most 19 for one insert, and
  **0 overflows**. Orders can move because nothing points at them.
- **Overflow is detected, never silent.** If 32 moves are not enough, the
  order is dropped and `order_overflows` is counted. The book no longer
  matches the exchange from that point, which the verification catches.
  A small stash CAM would be the production answer.

## 5. Levels and top of book: the cache, and why it is exact

- **Level table:** keyed by (book side, price), organised like the order
  table (2 banks × 2,048 buckets × 4 ways, H3). Entries **never move**,
  because every order stores a 14-bit pointer (bank, bucket, way) to its
  level. An Execute or Delete therefore reads its order, then its level
  directly by pointer, with no second hash lookup. At 47% peak load,
  two-choice alone never overflowed.
- **Top-of-book cache:** each of the 16 book sides (8 symbols × bid/ask)
  keeps up to K=8 levels by default, sorted best first, in LUT RAM. The invariant is
  that **the cache holds exactly the best n levels of its book side, for
  some n ≤ 32**. The rules keep it true:
  - **New level.** Better than the worst cached level: insert it (the worst
    falls out if the cache is full; the result is still a prefix). Worse
    than every cached level: insert it only if the cache is known to hold
    every level of that side.
  - **Level emptied.** Remove it from the cache if it is there; a prefix
    minus one element is still a prefix.
  - **Size changed.** Update the cached copy.
  - **Cache empties while the side still has levels.** This happens only
    when many consecutive best levels empty without new ones arriving above
    the old worst cached level. Refill by scanning the level table: 2,048
    rows, both banks at once. A pipelined tournament takes the best of each
    row's 8 candidates into a K-entry insertion sorter. The result keeps
    only levels strictly better than the best level *not* kept: every
    per-row runner-up and every sorter eviction is tracked. That makes the
    result a prefix again, and it is never empty.
- **Why it is exact:** the best level is always cached, so top of book never
  needs an ordered structure over all levels. The architectural model
  (`src/model/hw_book.ml`) proves this on the data: 1,043,727 top-of-book
  events, 0 differences from the reference book.
- **Cost of K:**

  | K | refills in the dataset | cache storage (16 sides) |
  |---|---|---|
  | 4 | 4,731 | 4.2 Kb |
  | 8 | 1,097 | 8.3 Kb |
  | 16 | 191 | 16.6 Kb |
  | 32 | 31 | 33 Kb in LUT RAM |

  A refill stalls the book for about 2,060 cycles (16 us at 125 MHz).
  At K=8 that is 1,097 times in 1.74M commands. Commands queued behind
  successive refills reached 6,016 cycles of end-to-end event latency.
  The refill could run in the background, and the design supports it: the
  cache stays valid while its best level is known, and the scan result merges
  as a prefix. That would remove the tail entirely.

## 6. Verification strategy

Four layers, each checked against the one above:

1. **Reference book** (`src/model/book.ml`): a Hashtbl plus a Map, obviously
   correct. It is Quickcheck-tested against an even more naive model that
   rescans every order after every message.
2. **Architectural model** (`src/model/hw_book.ml`): the same tables, hashes,
   replacement and cache rules as the RTL, untimed. It equals the reference
   on random sequences with tiny tables (2-entry cache, 32-entry order
   table, so kicks and refills happen constantly) and on the full dataset.
3. **RTL unit tests** (`tests/hw`): every stage against a reference.
   - The order book is compared with the architectural model on random
     sequences with tiny tables, **including its internal counters** (kicks,
     refills, overflows, live orders and levels), so a cache or hashing bug
     cannot hide behind matching output.
   - Waveform expect tests for each stage.
4. **Full pipeline** (`bin/verify.ml`, Verilator): every frame of a pcap at
   exact 1 Gb/s line rate (20-byte preamble plus inter-frame gap). Every book
   event is compared with the reference by MoldUDP64 sequence number, and
   latency is measured per message.

Bugs found by this process, all before hardware:
- The MoldUDP64 message count used the wrong register byte. This was
  invisible below 256 messages per packet, and caught by the end-of-session
  marker 0xFFFF in a directed test.
- A register slice in the order-book sorter read index -1 for entry 0.
- Greedy two-choice hashing overflowed at 84% load; see §4.
- Hardcaml's `&:` and `==:` have the same OCaml precedence and associate to
  the left, so `a &: b ==: c` means `(a &: b) ==: c`. Hardware code in this
  repo parenthesises every mixed expression.

## 7. Timing

Fmax is reported by nextpnr-xilinx for the core pipeline (`fpga/timing.sh`,
`src/hw/timing_top.ml`). The first place-and-route closed at 57.9 MHz with
a 32-entry cache; a later route reached 64.16 MHz, still short of the
125 MHz target. The critical path ran through the cache update, whose
"shift after the deleted entry" mask had become a 32-long OR chain. The
subsequent changes were:
- Compute the prefix OR log-depth.
- Move the prefix OR, the insert condition and the "cache holds every level"
  test into the compare stage, so the write stage is a shallow per-entry
  multiplexer.
- Register the 284-bit BRAM rows before comparing against them: a
  4,096-deep bank is 8 BRAMs deep plus an output mux.
- Give the frame parser and ITCH decoder an input register stage.
- Split the refill's discard tracking into two accumulators.
- Reduce the sorted cache to eight levels per side, a measured trade of
  1,097 refills for a shorter combinational path. A four-level version
  routed at 92.92 MHz but needed 4,731 refills. The final eight-level route
  reached 93.36 MHz, with 1,097 refills and no overflow in the strict
  1.74-million-command replay. The 125 MHz gigabit target remains unmet.

The final routed critical path ends at a level-bank BRAM data input:
10.71 ns total (3.00 ns logic, 7.71 ns routing). A further gigabit version would need
to restructure the level-bank write datapath and placement, or bank the
update across more cycles; it cannot claim 1 Gb/s physical throughput from
the current Fmax.

Registering the BRAM write port was also tried: the eight-level core routed
at 92.65 MHz, so that extra pipeline stage was removed.

## 8. Clocking and reset on the board

- **Receive domain:** everything in the receive path runs on the PHY's
  RX_CLK (125 MHz for 8-bit GMII at 1 Gb/s, or 25 MHz for low-nibble-first
  MII at 100 Mb/s; pin P4 is clock capable). The MII variant assembles each
  pair of nibbles into a byte before the same MAC. There is no clock
  crossing or elastic buffer in the latency path.
- **UART domain:** the UART and status logic run from the 50 MHz oscillator,
  because RX_CLK stops when the link is down.
  - Book events cross into it through an asynchronous FIFO (Gray-coded
    pointers).
  - Counters cross with a request/acknowledge handshake: the snapshot
    registers change only on a request, so they are stable once the
    acknowledge arrives.
- **Reset:** each domain has a power-on reset, a 5-bit counter without a
  reset of its own that holds `clear` for 16 cycles. The FPGA configures
  every flip-flop to 0, which is not a valid state for one-hot state machines.
  KEY0 resets both domains.
  - **BRAM:** reset does not clear BRAM, so the order book zeroes its tables
    (4,096 cycles) in an `Init` state after every reset.
  - **PHY:** held in reset for about 20 ms after configuration or KEY0.
