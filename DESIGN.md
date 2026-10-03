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

  | K | refills when a cache empties | cache storage (16 sides) |
  |---|---|---|
  | 4 | 4,731 | 4.2 Kb |
  | 8 | 1,097 | 8.3 Kb |
  | 16 | 191 | 16.6 Kb |
  | 32 | 31 | 33 Kb in LUT RAM |

  A blocking refill stalls the book for about 2,060 cycles (16 us at
  125 MHz). At K=8 that happened 1,097 times in 1.74M commands, and commands
  queued behind successive refills reached 6,016 cycles of end-to-end
  latency (p99 672).

- **Background refill.** The scan does not need to stop the book:
  - It starts when a side's cache holds half its capacity (4 of 8) or less
    while the side has more levels, so it usually finishes before the cache
    runs dry.
  - It reads the level table only between commands (Idle, Finish, Emit),
    because a command relies on the BRAM output holding its row until it
    writes it back. Rows in flight land in the sorter before the next
    command's cache update.
  - Every cache update of the side being scanned is also applied to the
    sorter: an insert or size change updates it, an emptied level is
    removed. A winner whose price is already in the sorter only updates it,
    so a row read before and after a change cannot insert a level twice.
  - The merge keeps the longer of the two prefixes (cache or scan result).
    A command waits only when its side's cache is empty. If a scan was
    already running then, its result can be empty too (it may have
    discarded the levels that are now best), so the command starts a fresh
    scan.
  - On the full replay: 4,903 refills, 10,902 cycles in total that commands
    spent waiting, p99 latency 31 cycles (was 672), p99.9 41 (was 2,078),
    maximum 2,761 (was 6,016). Starting at 2 of 8 instead of 4 waited
    36,411 cycles. The architectural model starts refills at the same point
    but completes them at once; the property tests check that the RTL equals
    it event by event with 0, 3 and 11 idle cycles between commands.

## 6. Verification strategy

Five layers, each checked against the one above:

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
   - Waveform expect tests for each stage. The order book's, from
     `tests/hw/test_book_hw.ml` (a bid of 100 at 190.10, a better one of 50
     at 190.12, then that one deleted; one event per command, the best bid
     following):

     ```text
     ┌Signals───────────┐┌Waves───────────────────────────────────────────────────────────────────────────────────┐
     │cmd_valid         ││──────┐                                                                                 │
     │                  ││      └─────────────────────────────────────────────────────────────────────────        │
     │                  ││────┬───────────────────────────────────────────────────────────────────────────        │
     │cmd_kind          ││ 1  │5                                                                                  │
     │                  ││────┴───────────────────────────────────────────────────────────────────────────        │
     │event_valid       ││                        ┌─┐                   ┌─┐                         ┌─┐           │
     │                  ││────────────────────────┘ └───────────────────┘ └─────────────────────────┘ └───        │
     │event_changed     ││                        ┌───────────────────────────────────────────────────────        │
     │                  ││────────────────────────┘                                                               │
     │                  ││────────────────────────┬─────────────────────┬───────────────────────────┬─────        │
     │event_seq         ││ 0                      │2                    │3                          │4            │
     │                  ││────────────────────────┴─────────────────────┴───────────────────────────┴─────        │
     │                  ││────────────────────────┬─────────────────────┬───────────────────────────┬─────        │
     │event_bid_price   ││ 0                      │1901000              │1901200                    │1901.        │
     │                  ││────────────────────────┴─────────────────────┴───────────────────────────┴─────        │
     │                  ││────────────────────────┬─────────────────────┬───────────────────────────┬─────        │
     │event_bid_shares  ││ 0                      │100                  │50                         │100          │
     │                  ││────────────────────────┴─────────────────────┴───────────────────────────┴─────        │
     ```
4. **Full pipeline** (`bin/verify.ml`, Verilator): every frame of a pcap at
   exact 1 Gb/s line rate (20-byte preamble plus inter-frame gap). Every book
   event is compared with the reference by MoldUDP64 sequence number, and
   latency is measured per message. It starts after the GMII MAC;
   `tests/hw/test_gmii_stream.ml` sends real frames through the MAC into the
   whole pipeline at the minimum inter-frame gap (and an 8-byte gap, and a
   5-byte preamble).
5. **Board at 1 Gb/s** (`scripts/board_linerate.sh`): the pcap over a cable.
   The board also measures the latency of every command on chip
   (`src/hw/latency_monitor.ml`): a timestamp FIFO beside the book's command
   FIFO pairs each command with its event, a block-RAM histogram collects
   the samples, and a hardware scanner publishes the percentiles with the
   Verilator replay's exact definition (checked per sample in
   `tests/hw/test_latency.ml`).
   The board's change count and CRC-32 over every change must equal the
   reference book's on the frames that actually left the PC, recorded with
   tcpdump, because the PC drops and reorders frames at speed. At 60,000
   frames/s it sends them in order, and the board produced all 1,043,727
   changes of the dataset with the reference's hash. The same
   counter comparison is what showed that: running the hardware's MoldUDP64
   rule over the PC's real sending order reproduced the board's 44,115
   duplicates and 2,711 gaps exactly.

Bugs found by this process before hardware (the board found three more; see
§9):
- The MoldUDP64 message count used the wrong register byte. This was
  invisible below 256 messages per packet, and caught by the end-of-session
  marker 0xFFFF in a directed test.
- A register slice in the order-book sorter read index -1 for entry 0.
- Greedy two-choice hashing overflowed at 84% load; see §4.
- Background refill: a command that found its side's cache empty waited for
  the scan already running for that side. That scan could have discarded
  the levels that had just become best, so its result was empty and the
  command emitted an empty side. The property test (tiny tables, several
  command spacings) caught it; the command now starts a fresh scan.
- Hardcaml's `&:` and `==:` have the same OCaml precedence and associate to
  the left, so `a &: b ==: c` means `(a &: b) ==: c`. Hardware code in this
  repo parenthesises every mixed expression.

## 7. Timing

**The core meets 125 MHz with Vivado** (`fpga/vivado_build.sh` on
`src/hw/timing_top.ml`: WNS +0.095 ns with synthesis retiming,
ExtraTimingOpt placement and AggressiveExplore physical optimisation and
routing), using 23% of the LUTs and 73% of the block RAM. The 1 Gb/s board
image, which adds the MACs, the GMII capture, the latency monitor, the
order entry, the UART and the counters, meets it too: WNS +0.075 ns, WHS
+0.016 ns, two endpoints within 0.1 ns, and the worst paths four logic
levels into BRAM pins, mostly routing. With gap recovery (section 12):
WNS +0.044 ns, WHS +0.025 ns.

That image had first closed at WNS +0.016 ns, WHS +0.001 ns, and the margin
turned out to depend on how synthesis retiming happened to partition the
design: the same order book closed at +0.038 ns in one run and not at all
in another. Two paths were long in the logic itself, not just the routing:
- **The refill sorter.** Inserting a scan winner compared it with every
  entry (32-bit keys, 32-bit prices for duplicates), ORed the duplicate
  matches and drove the shift multiplexers, 10 to 12 levels in one cycle.
  The winner now reaches the sorter one cycle later, and its comparisons
  are made during that cycle against what each entry will hold next (its
  own value, its upper neighbour's, or the winner being inserted), so
  inserting starts from registered flags. Rows land one cycle later, so the
  scan no longer issues a read on the cycle a command is popped: its cache
  update must see every row applied.
- **Starting a refill.** Finish read the cache row, counted its entries,
  compared the count with the low-water mark and started the scan in the
  same cycle; the decision is now registered there and the scan starts
  from Emit, which costs nothing on the event's path.
Vivado's BRAM power optimisation is also left out (`OPT_OPTS`): it gates
each BRAM enable through a LUT, a level on paths that are already mostly
routing. The full replay is unchanged apart from refill timing (section 6).

The refill tournament
computes each node's runner-up (the largest of two runners-up and the
loser) with all comparisons in parallel; as two chained compare-and-selects
it was the board image's critical path. The background refill needed two register
stages to close: the sorter eviction is registered before it joins the
discard maximum, and the merge decision (which scan entries survive, and
whether they beat the cache) is registered before it drives the LUT-RAM
cache write enable. The blocking-refill design had met it with WNS
+0.019 ns (-0.628 ns with default directives).

Most of the timing work was done earlier against nextpnr-xilinx (openXC7),
whose numbers were later found not to hold on silicon (section 9). The
first place-and-route closed at 57.9 MHz with a 32-entry cache, and a later
route at 64.16 MHz. The critical path ran through the cache update, whose
"shift after the deleted entry" mask had become a 32-long OR chain. The
changes that followed, all still in the design:
- Compute the prefix OR log-depth.
- Move the prefix OR, the insert condition and the "cache holds every level"
  test into the compare stage, so the write stage is a shallow per-entry
  multiplexer.
- Register the 284-bit BRAM rows before comparing against them: a
  4,096-deep bank is 8 BRAMs deep plus an output mux.
- Give the frame parser and ITCH decoder an input register stage.
- Split the refill's discard tracking into two accumulators.
- Reduce the sorted cache to eight levels per side, a measured trade of
  refills for a shorter combinational path (1,097 blocking refills instead
  of 191 at 16 levels; a four-level version needed 4,731).

openXC7's best route of that design reached 93.36 MHz, with its critical
path ending at a level-bank BRAM data input (10.71 ns, 72% routing);
registering the BRAM write port did not help (92.65 MHz). With the board
workarounds of section 9 (no FSM re-encoding, 2,048-deep BRAM pieces) it
routes at 78.59 MHz. The 100 Mb/s board build needs only 25 MHz.

## 8. Clocking and reset on the board

- **Receive domain:** everything in the receive path runs on the PHY's
  RX_CLK (125 MHz for 8-bit GMII at 1 Gb/s, or 25 MHz for low-nibble-first
  MII at 100 Mb/s; pin P4 is clock capable). The MII variant assembles each
  pair of nibbles into a byte before the same MAC. There is no clock
  crossing or elastic buffer in the latency path; the gigabit capture below
  adds one register stage.
- **GMII capture at 1 Gb/s** (`src/hw/gmii_clock.ml`). The RTL8211EG
  guarantees RXD, RXDV and RXER only from 2.5 ns before to 0.5 ns after each
  RXC rising edge (datasheet rev 1.6, table 64), a 3 ns window in an 8 ns
  cycle. With that window as input constraints, Vivado compared three
  captures:

  | capture | worst input setup / hold |
  |---|---|
  | RXC through a BUFG into IOB flip-flops | +0.35 / +0.17 ns, only thanks to the IOB's automatic zero-hold delay |
  | RXC through a deskewing MMCM, phase-shifted | no phase works: the two slacks sum to about -1.6 ns across process corners |
  | BUFIO-clocked IOB flip-flops, data through IDELAYE2 (used) | +0.44 / +0.45 ns at 26 taps |

  RXC arrives on an SRCC pin in bank 34, the bank of all the data pins, so
  a BUFIO can clock that bank's input registers over a short path with
  little variation. The IDELAYs (78 ps taps, calibrated by an IDELAYCTRL on
  a 200 MHz clock made from the 50 MHz oscillator) move the data window onto
  that edge. A capture-only top (`src/hw/gmii_probe.ml`) builds in about
  three minutes, and 0 taps (+2.72 / -1.33 ns) showed that 26 balances the
  two. RXC also drives a BUFG for the rest of the receive domain; the bytes
  cross from the BUFIO clock to it through a falling-edge register, half a
  cycle of margin each way, at a cost of one cycle of latency. The
  100 Mb/s image keeps the direct capture: at 25 MHz the window is wide.
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
    RX_CLK comes from the PHY and can stop or glitch meanwhile, so the
    receive domain is held in clear for the whole PHY reset and 256 clean
    RX_CLK cycles after it (`Board_top.rx_domain_clear`).

## 9. Board bring-up: what simulation did not catch

The first physical replay decoded every frame and learned all eight locate
codes, but the book processed no commands. Every simulation passed: RTL in
Cyclesim and Verilator, and even the synthesized netlist. The investigation
separated the layers one at a time:

1. **Gate-level simulation** (`fpga/netlist_sim/`): the yosys netlist,
   simulated with two independent clocks and MII stimulus. yosys's
   `cells_sim.v` declares RAMB18E1/RAMB36E1 as timing shells with no memory
   behaviour, so they are replaced with Vivado's functional unisim models.
   Without that, every BRAM read returns 0, which briefly looked like a
   synthesis bug. A plain Verilog RAM run through the same flow is the
   control that exposed this. With functional models the netlist matched the
   model exactly, so logic synthesis was correct.
2. **On-chip self-test** (`SELFTEST_PCAP=... fpga/build_board.sh`): the test
   frames are stored in a ROM and played into the pipeline after reset, so
   the silicon is tested over JTAG and UART with no PHY, cable or network
   setup. It reproduced the fault. New counters showed that 97 commands
   reached the book's FIFO (`fcmd`, `fmax`) and none left it, with the state
   machine at code 0 (`bst`).
3. **BRAM probe** (`src/hw/bram_probe.ml`): memories of exactly the order-
   and level-bank shapes, written and read back on the 50 MHz clock only.
   Two separate toolchain problems showed up:
   - **Re-encoded FSMs do not run on this board.** yosys extracts state
     registers (including plain 2- and 3-bit registers that only take
     constant values) and re-encodes them as one-hot. With this flow they
     never left their reset state on silicon, even with a power-on clear.
     All builds now mark every wire `fsm_encoding="none"` before synthesis.
   - **RAMB36E1 in 4K x 9 mode reads back wrong.** A 4,096-deep, 284-bit
     order bank maps to 32 RAMB36E1 in TDP 4K x 9 mode. On the board, half
     of the addresses (every odd address) came back with a parity-position
     bit wrong. The 2,048-deep level-bank shape (RAMB18E1, 2K x 9) was
     perfect. Tables deeper than 2,048 rows are now built from 2,048-deep
     pieces, with a registered read-side select. BRAM use is unchanged.
     Root cause, found afterwards: at width 9 a RAMB36E1 keeps the parity bit
     of odd addresses in its upper half, which reads it from `DIPADIP1`, and
     nextpnr left that pin unconnected (it already duplicated the data pin
     for width 1). A 14-line packer fix took a single 4K x 9 BRAM from 1,024
     wrong words to 0 on this board; submitted upstream as
     [openXC7/nextpnr#63](https://github.com/openXC7/nextpnr/pull/63) with a
     regression test.

The self-test then matched the model on silicon: 97 commands, 95 live
orders, 84 levels, no kicks, and the change count and hash `6debb1d9` equal
to `pcapgen expect` (`results/board_selftest.txt`).

4. **At speed, openXC7's timing does not hold.** That self-test ran at
   2.5 MHz (the PHY's clock without a link). On the cable at 25 MHz, the
   book was exact (all 39 events equal the model's) but the on-chip hash
   register was wrong. Clocked at 50 MHz, the symbol filter never matched.
   nextpnr reported 2-4x margin for all of them, and every simulation is
   correct. The Vivado build of the same Verilog is correct at 50 MHz
   (`results/board_toolchains.txt`), so board images are built with Vivado
   (`fpga/vivado_build.sh`), which also closes the core at 125 MHz.

With the Vivado image, the direct-cable replay of 400 real packets matches
the model exactly: all 39 top-of-book events and the on-chip change count and
hash `6debb1d9` (`results/board_cable_vivado.txt`).

## 10. The 1 Gb/s test: when the counters pointed at the sender

The first full replay over the gigabit link failed badly: 1,914 frames
missing, 715,441 messages counted as MoldUDP64 duplicates, a book that
diverged from the reference. Every frame that arrived was intact (no FCS
or frame errors), and the Verilator replay of the same pcap was exact.

- **A pattern in the counters.** The duplicate count was within 0.1% of the
  pcap's 715,926 frames of 83 and 87 bytes, the single-message frames that
  carry an Order Delete or an Order Cancel. That looked like a
  frame-length bug in the MAC, which the Verilator replay never exercises
  (it starts after the MAC). A new test sent real frames through the GMII
  MAC at the minimum inter-frame gap, an 8-byte gap and a 5-byte preamble:
  no duplicates, no gaps (`tests/hw/test_gmii_stream.ml`).
- **A rate sweep.** The first 10,000 frames at 500 frames/s and the first
  100,000 at 20,000 and 60,000 frames/s gave no duplicates; at top speed (127,000 frames/s) they came
  back. So it depended on rate, not on the frames.
- **What the host sent.** tcpdump on the sending interface records the
  frames at the kernel's transmit tap, after the qdisc. They were out of
  order: two in-order streams interleaved about 1,900 frames apart, and
  frames missing, all counted as sent by tcpreplay. Replacing the default
  `fq_codel` qdisc with a FIFO did not change it; the NIC has a single
  transmit queue.
- **The proof.** The board's MoldUDP64 rule (a message below the next
  expected sequence number is a duplicate; above it, a gap) applied to the
  captured order reproduces the board's counters exactly, in every run: for
  example 44,115 duplicates and 2,711 gaps for 100,000 frames at top speed.
  The board had received and processed exactly what was sent. The 83- and 87-byte frames were most of the
  frames overtaken by the interleaved stream.

The test (`scripts/board_linerate.sh`) now records what leaves the host,
rebuilds those frames in order from the pcap by sequence number, and runs
the reference book on them with the hardware's rule. At 60,000 frames/s
the host sends everything in order except the last few frames, and the
board produces all 1,043,727 changes of the dataset with the reference's
count and hash.

Two smaller things this run exposed:
- tcpdump runs under an AppArmor profile that refuses signals from
  processes confined as VS Code's terminal, even as root, so a capture
  started from that terminal could not be stopped by `kill`, `pkill` or
  Ctrl-C; the test now runs it as a transient systemd unit.
- After the FPGA is programmed, its PHY comes out of reset and the gigabit
  link can take minutes and several speeds to settle; restricting the NIC
  to advertise 1000BASE-T only made it worse. The test restarts
  autonegotiation from the host and waits for 1000 Mb/s.

## 11. Order entry and tick-to-trade

The board can react as well as listen. `src/hw/order_entry.ml` watches the
book's events and sends an OUCH 5.0 Enter Order back out of the PHY.

- **The rule** (`Itch_model.Ouch.Strategy`, and the same in hardware): for
  one symbol, when the best offer is present and at or below a limit, buy
  a fixed quantity at the offer, immediate-or-cancel, once per crossing.
  The board's: 100 SPY at $300.00, 53 orders on the tracked pcap. It is a
  demonstration of the path, not a strategy.
- **The message**: 47 bytes laid out as in the specification's section
  2.1 (checked field by field in `tests/model/test_ouch.ml`). UserRefNum
  counts from 1, strictly increasing as OUCH requires; ClOrdID carries the
  ITCH sequence number of the triggering message.
- **The frame**: with a zero UDP checksum (allowed over IPv4) the
  Ethernet, IPv4 and UDP headers do not depend on the order, so the whole
  header, IP checksum included, is a constant computed by
  `Net.Packet.frame`. The frame is loaded into the transmit MAC's shift
  register in one cycle; nothing wide is selected per byte at 125 MHz. A
  16-deep queue holds triggers while a frame is still going out.
- **Transmit clocking**: the transmit side runs on the receive clock, so
  there is no clock crossing between a market-data byte and the order it
  triggers. GTX_CLK goes to the PHY through an ODDR, inverted, so the PHY
  samples TXD half a cycle after the IOB output registers launch it; the
  output constraints use the datasheet's 2 ns setup and 0 ns hold.

**Deciding earlier.** Waiting for the book costs 17 to 28 cycles, but for
this rule most crossings do not need it: a sell Add at or below the limit
makes the best ask cross by itself (the new ask is its price). So when the
book is up to date (idle, nothing queued, no event in flight) and the rule
is armed, a small detector on the MoldUDP64 message stream decides on the
message's last byte, comparing the price as that byte arrives. The order
is the one the book path would send; every other crossing (the best ask
deleted or executed, a busy book) still comes from the book's event, and
the event of an order already sent does not fire again.

**Pre-forming the preamble.** By byte 23 of an Add (shares complete) the
detector knows whether the message is a candidate: an Add, on the rule's
symbol, a sell, with shares. Then the transmit MAC starts sending preamble
and holds it until the decision, 12 bytes later; if the order fires, the
SFD and the frame follow at once instead of 8 bytes of preamble, and if the
price is above the limit, transmit is released before any SFD, which no
receiver takes for a frame (`tests/hw/test_gmii_tx.ml` checks that the
receive MAC sees nothing and counts no error). The cost is a burst of
preamble on the order link for every candidate that does not fire.

**Tick-to-trade** is measured on every order, from the cycle the last byte
of the triggering message is on the GMII receive pins to the cycle the
order frame's first byte is on the transmit pins, into the same hardware
histogram as the book latency. In simulation of the whole board
(`tests/hw/test_board.ml`), the board's own figure equals the one measured
at the pins: 13 cycles (104 ns) for the 21 of 27 orders decided from the
message, up to 46 for those that need the book. Of the 13:

| stage | cycles |
|---|---|
| receive pins to the MAC's output stream: input register, and the MAC holding back 4 bytes until it knows they are not the FCS | 7 |
| MAC stream to the MoldUDP64 message stream | 2 |
| last byte to the order frame's first byte at the transmit MAC: decide (price compared as its last byte arrives), queue, SFD on the held preamble, first byte | 3 |
| through the IOB output register to the pin | 1 |

Orders that need the book took 35 to 46 cycles at the pins in the same
run: the book's 17 or more cycles, and a full 8-byte preamble once the
event arrives. The gigabit image's input capture adds one more cycle (its BUFIO
input register feeds a falling-edge and then a rising-edge register): 14
cycles, 112 ns.

**On the board** (`results/board_gigabit.txt`), over the whole dataset at
60,000 frames/s: all 53 orders equal to the model's, and every one took
exactly 14 cycles, 112 ns, pin to pin. The previous image, which waited
for the book for every order, measured 36 cycles median and 48 worst (288
and 384 ns) on the same data. The PHY's own receive and transmit latency
comes on top and is not measured here.

## 12. Gap recovery: A/B lines and retransmission

A UDP feed loses packets, and a book that misses one Add or Delete is wrong
until the session ends. Exchanges therefore send each feed twice, on two
multicast groups (lines A and B) over separate paths, and run a
retransmission server that answers MoldUDP64 requests. The board uses
both (`src/hw/mold_parser.ml`, with `~recovery`; the gigabit image has it).

**Where it lives.** Only the MoldUDP64 stage sees every sequence number,
including those of messages the symbol map later drops, so recovery is
done there, on whole messages, and everything downstream is unchanged:
the decoder, the book and the order path still see one message after
another in sequence, with no added cycle when nothing is missing. The
frame filter accepts the B group and the retransmission address as extra
endpoints, each with its own comparison chain.

**Two counters.** E is the next message to pass on; L is the next one the
feed has not yet shown. Messages between E and L are parked in a buffer or
missing. For each arriving message, numbered S:

| case | action |
|---|---|
| S = E, and not already parked | straight through, as without recovery |
| S ≥ L | parked; L = S + 1 (a hole appears if S > L) |
| otherwise | dropped: a duplicate (the other line, a retransmission already served), or a missing message arriving out of order, which will be asked for |

The buffer is a byte RAM for message bodies (32 KB) and a FIFO of
(sequence number, length) for 2,048 messages; a message is committed only
once its last byte is in, and a full buffer drops the newcomer, which just
makes another hole. Parked messages are in increasing order by
construction, so the head of the FIFO is the oldest. A replay engine passes
it on as soon as it is numbered E; the decision rules keep the replay and a
live message from ever going out on the same cycle, and the replay reads
the RAM one byte per cycle like a live packet.

**Asking for the missing.** While E is missing, a timer runs. After 16 µs
(the window for the B line to catch up) the board asks for E up to the
buffer's head (or L), at most 1,024 messages; again every 1 ms without
progress, up to 32 times (32 ms: the host's server, under the replay's load,
was measured stalling for up to 13.5 ms). The request is a MoldUDP64 header (session,
sequence number, count) in a UDP frame from the transmit MAC, which it
shares with the orders: a request waits while an order is queued or a
preamble is pre-formed. An order can still wait for a request already on
the wire: on the board at top speed, with 81,000 requests, the slowest of 53
orders took 21 cycles instead of 14. The frame is built
the way orders are, a constant header and three registered fields, padded
to the order frame's length. The session is the one of the last complete
packet header.

**Giving up.** After the last request, the missing messages are counted as
lost, a sticky stale flag is set, and the parked messages go on: the book
may be wrong from then on, and the flag says so. Heartbeat and
end-of-session packets carry the next sequence number, so a loss at the
very end of a burst is seen too.

**What it costs.** No latency: a message that arrives in sequence goes
through with the same 2 cycles as before, and the fast path is unchanged
(it acts on messages in sequence). In the board image: 1,333 LUTs and 12.5
BRAM tiles (20,941 LUTs, 33%, and 117.5 of 135 tiles in all), and it still
meets 125 MHz (WNS +0.044 ns, WHS +0.025 ns). Closing it took two
registers: the decision on a message's first byte compares its number with
L a cycle ahead (both are settled at least two bytes earlier, during the
block length), and the "most parked at once" statistic follows the
registered count a cycle late. The tests in `tests/hw/test_recovery.ml`
send random feeds on two lines that each lose 10 to 20% of packets, with
packets out of order and a retransmission server that answers always, half
the time, or never; the output is always in sequence, every body intact,
and messages out plus lost equals the session. `tests/hw/test_board.ml` does
the same through the whole board, the server answering the requests seen
on the transmit pins: the change count, hash and orders equal the model's
over every message.

**On the board** (`results/board_recovery.txt`): the whole session on two
lines, each losing about 2% of packets and 643 packets lost on both, with
`scripts/mold_server.py` answering re-requests from the host. At 60,000
frames/s the board passed on all 1,752,946 messages in sequence (about
21,000 requests, none given up) and ended with the same changes, hash and
53 orders as a run with no losses. At the host's top speed, 138,000
frames/s, the host's own drops and reorders raise the gaps to about
100,000 and the requests to 80,000, and it passes too: 447,443 messages
replayed, 1,694 turned away by the full buffer and recovered later, and
943 answer frames lost on the way and asked for again.

Getting there took three changes, each found from the board's counters.
The 16 KB buffer ran out of bytes (peak 586 messages): now 32 KB. With a
crashed server, every hole waited out its retries while the full buffer
turned the feed away: a full buffer now gives up the open hole at once
once a hole has gone unanswered. And the host's server, sharing the CPU
with the replay, stalls for up to 13.5 ms (measured from the capture of
each request and its answer at the host's transmit tap), longer than the
8 requests over 8 ms the board first allowed: the same feed gave up 96,
1,718 and 0 messages in three runs. With 32 requests over 32 ms, both
rates pass.
