# FPGA ITCH feed handler

[![tests](https://github.com/misa-hw/fpga-itch-feed-handler/actions/workflows/test.yml/badge.svg)](https://github.com/misa-hw/fpga-itch-feed-handler/actions/workflows/test.yml)

> **About this project.** I started it to get familiar with Hardcaml, the
> OCaml toolchain and my QMTech Wukong board, and because I was curious how
> far its Ethernet port could be pushed. It was also an experiment: most of
> the code and documentation were written by Claude Opus 5.5 (Claude Code,
> medium thinking), and I wanted to see whether an agent could take a
> hardware project end to end, from the first parser to measured results on
> a real board. Commits made with it carry a `Co-Authored-By: Claude` line.

A Nasdaq market-data feed handler written in
[Hardcaml](https://github.com/janestreet/hardcaml), running on a QMTech
Wukong board (Xilinx Artix-7 XC7A100T, RTL8211EG gigabit PHY).

Ethernet frames come straight in from the PHY. The FPGA parses
IPv4/UDP/MoldUDP64/ITCH 5.0 one byte per clock, keeps full-depth order books
for eight symbols in block RAM, and emits a top-of-book event after every
book update. A deliberately simple trading rule watches those events and
sends OUCH 5.0 orders back out of the same PHY, and the board measures its
own tick-to-trade latency.

Everything is checked against an OCaml reference book and a bit-accurate
model of the hardware, from unit tests all the way to the board.
[DESIGN.md](DESIGN.md) has the longer story: the data structures, the
trade-offs, and the bugs that only showed up on silicon.

## Results

- **Tick-to-trade: 72 ns, measured on the board.** That's 9 cycles at
  125 MHz, from the last byte of the triggering market-data message on the
  FPGA's GMII receive pins to the first byte of the order on its transmit
  pins. It holds for all 53 orders the rule sends on the dataset, and each
  order is byte-identical to the model's
  ([`results/board_recovery.txt`](results/board_recovery.txt)). It started
  at 112 ns; it went down once the receive MAC stopped holding bytes back
  for the FCS and orders stopped going through a queue. Waiting for the
  order book instead would cost 288 ns median, 384 ns worst
  ([`results/board_gigabit.txt`](results/board_gigabit.txt)).
- **The whole dataset over a real 1 Gb/s link.** 1,655,585 frames of real
  Nasdaq data (1.75 million messages) produce 1,043,727 top-of-book
  changes. The count and CRC-32 computed on chip are exactly the reference
  book's ([`results/board_gigabit.txt`](results/board_gigabit.txt)).
- **Book latency: 160 ns median, 248 ns at p99** (20 and 31 cycles), from a
  message's last byte to its top-of-book event. It's measured on chip for
  every one of the 1.74 million book commands, and matches the cycle-exact
  simulation. The worst case is 1,059 cycles (8.5 µs): a command whose
  side's cache ran empty before its refill finished. Chip and simulation
  agree on that too.
- **Timing closes at 125 MHz** in Vivado, both for the core and for the
  gigabit board image, with the GMII inputs constrained to the 3 ns window
  from the PHY datasheet.
- **No mismatches anywhere.** In simulation the RTL equals the reference
  book on all 1,043,727 changes, and it equals the architectural model
  event by event (internal counters included) on random sequences with tiny
  tables.

## How it works

```mermaid
flowchart LR
  PHY["RTL8211EG PHY"] -->|"GMII, 8 bits at 125 MHz"| CAP["GMII capture<br/>BUFIO + IDELAY"]
  subgraph RX["receive clock, 125 MHz: one byte per cycle"]
    CAP --> MAC["MAC<br/>preamble, FCS"]
    MAC --> NET["Ethernet, IPv4, UDP<br/>address filter"]
    NET --> MOLD["MoldUDP64<br/>A/B arbitration, gap recovery"]
    MOLD --> ITCH["ITCH 5.0 decoder"]
    ITCH --> SYM["symbol map<br/>8 slots"]
    SYM --> FIFO["command FIFO"]
    FIFO --> ORD["order table<br/>2 hashed 4-way BRAM banks"]
    ORD --> LVL["level table<br/>2 hashed 4-way BRAM banks"]
    LVL --> TOP["top 8 levels per side<br/>background refill"]
    TOP --> EV["top-of-book event"]
    EV --> HASH["change count<br/>CRC-32 of every change"]
    EV --> RULE["trading rule<br/>buy when the ask reaches a limit"]
    RULE --> OUCH["OUCH 5.0 Enter Order<br/>in a UDP frame"]
    OUCH --> TXMAC["transmit MAC<br/>preamble, FCS"]
    MOLD -->|"re-requests"| TXMAC
  end
  TXMAC -->|"GMII out, GTX_CLK forwarded"| PHY
  subgraph SLOW["50 MHz"]
    UART["UART: event lines,<br/>status lines"]
  end
  EV -->|"async FIFO"| UART
  HASH -->|"handshake"| UART
```

- **Parsing** is cut-through: one byte per clock, no backpressure, so a
  message is fully decoded the moment its last byte arrives.
- **Orders** (up to 32,768) live in two hashed four-way BRAM banks with
  bounded cuckoo displacement.
- **Price levels** (up to 16,384) live in two more hashed banks, keyed by
  symbol, side and price.
- **Top of book** comes from a small cache per side holding the best eight
  levels, kept sorted. When a cache runs low, a background scan of the
  level table refills it while the book keeps working.
- **Order entry** is one rule on one symbol: when the best offer drops to a
  limit (on the board, 100 SPY at $300.00), send one immediate-or-cancel buy
  at the offer, once per crossing. A sell Add at or below the limit causes
  the crossing by itself, so that case is decided straight from the message
  bytes as the price arrives, without waiting for the book. By then the
  order's preamble is already on the wire: it starts as soon as the message
  looks like a candidate, and gets dropped before the SFD if the price turns
  out too high. The Ethernet/IPv4/UDP header is a constant (zero UDP
  checksum), so the frame goes straight from registers into the transmit
  MAC on the receive clock, with no clock crossing on the way out.
- **Capacity failures** (a full table, an unsupported field value) are
  always counted, never silent.

## How it is verified

Five layers, each checked against the one above it
([DESIGN.md section 6](DESIGN.md#6-verification-strategy)):

1. **Reference book** (`src/model/book.ml`): a hash table plus per-side
   price maps, property-tested against a naive model that rescans every
   order.
2. **Architectural model** (`src/model/hw_book.ml`): the hardware's hashes,
   capacities, collisions and cache rules, without timing. It equals the
   reference on random sequences and on the full sample.
3. **RTL tests** (`tests/hw`): every stage against a reference, with
   waveform expect tests. The order book is compared with the architectural
   model on random sequences with tiny tables and several command spacings,
   internal counters included. Real frames go through the GMII MAC at the
   minimum inter-frame gap. Gap recovery is tested with two lines that each
   lose 10 to 20% of packets, reordered packets, and a retransmission server
   that answers always, half the time or never, both alone and through the
   whole board. The output is always in sequence, and complete whenever the
   server answers.
4. **Full pipeline** (`bin/verify.ml`, Verilator): every frame of the
   tracked pcap at exact 1 Gb/s line rate. Every book event is compared with
   the reference by MoldUDP64 sequence number, and latency is measured per
   message.
5. **Board** (`scripts/board_recovery.sh`, `scripts/board_linerate.sh`): the
   pcap over a cable, checked through an on-chip count and CRC-32 of every
   change.

The data is a 32.6-million-message prefix of Nasdaq's public
[07302019 ITCH 5.0 sample](https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/),
filtered down to the eight tracked symbols: 1,752,946 messages in 1,655,589
MoldUDP64 packets (`build/tracked.pcap`).

| Measured | Result |
| --- | --- |
| Full replay, simulation ([`verify_tracked.txt`](results/verify_tracked.txt)) | 1,740,696 book commands, 1,043,727 changes, 0 mismatches, 0 overflows |
| Event latency, 125 MHz cycles | p50 20, p99 31, p99.9 41, max 1,059 (2,761 before level windows and scan pre-emption); 72 commands (0.0041%) over 64 |
| Peak table occupancy | 27,573 / 32,768 orders; 7,633 / 16,384 levels |
| Book FIFO peak | 25 / 512 commands |
| Background cache refills | 5,322; commands waited 6,413 cycles in total |
| Core at 125 MHz, Vivado ([`timing.txt`](results/timing.txt)) | met, WNS +0.095 ns; 14,543 LUTs (23%), 8,983 FFs (7%), 98 BRAM tiles (73%) |
| 1 Gb/s board image (order entry, gap recovery), Vivado | met, WNS +0.044 ns, WHS +0.025 ns; 20,941 LUTs (33%), 117.5 BRAM tiles (87%); GMII inputs +0.44 / +0.45 ns, outputs +1.65 / +3.69 ns setup / hold |
| 1 Gb/s board, whole dataset over a cable | 1,043,727 changes, count and hash equal to the reference |
| Orders on the board, whole dataset | 53 of 53 equal to the model's; tick-to-trade 72 ns pin to pin for every order (112 ns before the cuts of DESIGN.md section 11) |
| Gap recovery on the board ([`board_recovery.txt`](results/board_recovery.txt)) | two lines each losing 2% of packets (643 lost on both), at 60,000 frames/s and at the host's top speed (138,000 frames/s, ~100,000 gaps, 80,000 re-requests): all 1,752,946 messages recovered in sequence, changes and hash equal to the reference, 53 of 53 orders |
| Book latency on the board (every command) | p50 20, p99 31, p99.9 40 cycles, as in simulation |
| 100 Mb/s board, cable and on-chip self-test | 39 changes, all equal to the model |
| Orders, whole board in simulation ([`test_board.ml`](tests/hw/test_board.ml)) | 27 of 27 frames at the transmit pins equal to the model's; tick-to-trade 7 or 8 cycles (21 orders decided from the message), up to 42 |

Latency is counted from the cycle the last byte of a message leaves the MAC
to the cycle its event is valid. The tail comes from commands that find
their side's cache empty and have to wait for the refill scan. With a
blocking refill, p99 was 672 cycles and the maximum 6,016
([`verify_tracked_blocking.txt`](results/verify_tracked_blocking.txt)).

## On the board

The Wukong's RTL8211EG PHY hands over received bytes on an 8-bit GMII bus
at 125 MHz. The pinout comes from QMTech's
[schematic](https://github.com/ChinaQMTECH/QM_XC7A100T_WUKONG_BOARD/blob/master/V3/Hardware/QMTECH-XC7A100T_200T-Wukong-Board-V03-20240121.pdf)
and [example](https://github.com/ChinaQMTECH/QM_XC7A100T_WUKONG_BOARD/blob/master/V3/Software/XC7A100T/Test08_GMII_Ethernet.zip);
it's in [`fpga/wukong.xdc`](fpga/wukong.xdc). The receive path runs on the
PHY's clock. A separate 50 MHz domain drives a UART that prints an `E` line
for each top-of-book change and, once a second, an `S` line with every
counter. At full rate the UART can't keep up and drops `E` lines, so the
receive domain also keeps a count and a CRC-32 of every change. Comparing
those two numbers with the reference book (`pcapgen expect`) still checks
every single change.

**1 Gb/s, whole dataset.** Over a direct 1000 Mb/s cable at 60,000
frames/s, the board received 1,655,585 of the 1,655,589 frames (the PC
dropped the last four): 1,752,942 messages, with no duplicates, gaps, FCS
errors or overflows. Its count and hash, 1,043,727 changes and `186f6e17`,
equal the reference book's for the complete pcap.

**1 Gb/s, top speed.** At 132,000 frames/s (99.5 Mb/s on average, frames
reaching the NIC as little as 0.95 µs apart), the PC itself starts dropping
and reordering frames before they reach its NIC, while tcpreplay still
reports them as sent. So the test records what actually leaves the host
with tcpdump, rebuilds the stream in that order, and runs the reference
book on it with the hardware's MoldUDP64 rule (a late message counts as a
duplicate). The board matches it exactly: 1,655,466 frames, 729,207
duplicates, 45,278 gaps, 2,948 changes, hash `6e0f8b00`. That same
comparison is what showed that the sender, not the board, was the one
reordering
([DESIGN.md section 10](DESIGN.md#10-the-1-gbs-test-when-the-counters-pointed-at-the-sender)).

**Latency on chip.** The board image timestamps every book command as it
enters the book, and computes its latency when the matching event comes
out (commands and events are one to one and in order). It adds the fixed
5-cycle pipeline in front of the book, so each sample is exactly the
simulation's latency. Samples go into a histogram in block RAM, and a small
hardware scanner walks it continuously to publish the count, p50, p99,
p99.9 and maximum in the UART status line (`lat`, `l50`, `l99`, `l999`,
`lmax`). `scripts/board_linerate.sh` prints them. In simulation, every
sample and every percentile is checked against the definition the
Verilator replay uses
([`tests/hw/test_latency.ml`](tests/hw/test_latency.ml)).

**Orders out.** The gigabit image also carries order entry, with the rule
built in: buy 100 SPY when the offer comes down to $300.00, which fires 53
times on the tracked pcap. `scripts/board_linerate.sh` captures the frames
the board sends and requires them, in order, to equal the model's orders
for the stream that was actually sent (`pcapgen orders`). It also prints
the tick-to-trade the board measured between its GMII pins (`osent`,
`odrop`, `tt`, `t50`, `t99`, `tmax`). The transmit side runs on the receive
clock, with GTX_CLK forwarded inverted through an ODDR so the PHY samples
the IOB output registers mid-cycle; Vivado checks that against the
datasheet's 2 ns setup and 0 ns hold. On the board, all 53 orders reached
the PC equal to the model's, each one 72 ns pin to pin.

**Receiving at 125 MHz.** The PHY only guarantees each byte from 2.5 ns
before to 0.5 ns after its clock edge. The board image captures it with
BUFIO-clocked input registers behind a 26-tap IDELAY on every data pin.
Vivado times that against the window with +0.44 ns setup and +0.45 ns hold
margin. A phase-shifted MMCM can't meet both
([DESIGN.md section 8](DESIGN.md#8-clocking-and-reset-on-the-board)).

**Bring-up.** The first cable test decoded every frame, but the book
processed nothing, even though every simulation passed. To find out why, the
board image got an on-chip self-test (frames played from a ROM, no PHY or network)
and a BRAM probe. They turned up three problems that only exist on silicon,
all in the open-source toolchain
([DESIGN.md section 9](DESIGN.md#9-board-bring-up-what-simulation-did-not-catch)):
yosys's FSM re-encoding, a nextpnr bug that left one BRAM parity pin
unconnected (fixed upstream in
[openXC7/nextpnr#63](https://github.com/openXC7/nextpnr/pull/63)), and
bitstreams that failed at speed despite 2-4x reported margin. Because of
that, board images are built with Vivado. Its builds of the same Verilog
work on the self-test at 50 MHz
([`board_toolchains.txt`](results/board_toolchains.txt)), over the cable at
100 Mb/s ([`board_cable_vivado.txt`](results/board_cable_vivado.txt)), and
at 1 Gb/s.

## How it got here

The project went through six stages between September 29 and October 3,
2026. Each one started with something that didn't work; the commit history
has the details.

1. **The core pipeline.** Parsers, ITCH decoder and order book, checked
   against the reference book in Verilator. The architectural model showed
   that the first hashing scheme, plain two-choice, would overflow the order
   table 99,187 times over the day at 84% load, so the table uses cuckoo
   displacement instead: 0 overflows
   ([DESIGN.md §4](DESIGN.md#4-order-table-hashing-and-collisions)).
2. **First contact with the board.** Every simulation passed, but on the
   board the book processed nothing. An on-chip self-test and a BRAM probe
   found two toolchain problems: yosys's FSM re-encoding, and a nextpnr bug
   that left a BRAM parity pin unconnected. The second one is fixed upstream
   ([openXC7/nextpnr#63](https://github.com/openXC7/nextpnr/pull/63)), and
   since openXC7 bitstreams still failed at speed, board images moved to
   Vivado ([DESIGN.md §9](DESIGN.md#9-board-bring-up-what-simulation-did-not-catch)).
3. **The latency tail.** The first top-of-book cache stopped the book while
   it refilled from the level table: p99 672 cycles, worst case 6,016. A
   background refill brought p99 down to 31, and level windows with scan
   pre-emption brought the worst case down to 1,059
   ([DESIGN.md §5](DESIGN.md#5-levels-and-top-of-book-the-cache-and-why-it-is-exact)).
4. **1 Gb/s.** The first full gigabit replay reported 715,441 duplicate
   messages, which looked like a MAC bug. It wasn't: the PC was reordering
   frames before they reached its NIC. The board test now records what
   actually leaves the host and checks the board against that, and at
   60,000 frames/s the board reproduces the whole dataset
   ([DESIGN.md §10](DESIGN.md#10-the-1-gbs-test-when-the-counters-pointed-at-the-sender)).
5. **Sending orders.** Going through the book, an order took 288 ns median
   pin to pin. Deciding straight from the message brought that to 112 ns,
   and three more cuts (the receive MAC no longer holds bytes back for the
   FCS, a decided order skips the queue, the preamble is pre-formed) got it
   to 72 ns ([DESIGN.md §11](DESIGN.md#11-order-entry-and-tick-to-trade)).
6. **Gap recovery.** A/B lines, re-requests and a replay buffer. On the
   board, the first version's 16 KB buffer ran out, and its 8 retries over
   8 ms weren't enough for a retransmission server that sometimes stalled
   for 13.5 ms. With a 32 KB buffer and 32 retries over 32 ms, it recovers
   every message at 60,000 frames/s and at the host's top speed
   ([DESIGN.md §12](DESIGN.md#12-gap-recovery-ab-lines-and-retransmission)).

## Reproduce

Developed with OCaml 5.2+Ox, dune 3.24, Hardcaml
`v0.18~preview.130.106+341`, Verilator 5.032, Vivado 2026.1, and openXC7
(Yosys 0.52 and nextpnr-xilinx; its scripts expect `/opt/openxc7` and a chip
database at `~/hardcaml-tutorial/fpga/build/xc7a100tfgg676.bin`).

```bash
eval "$(opam env --switch=oxcaml)"
make data          # fetch a prefix of the Nasdaq sample (scripts/fetch_itch.sh)
make test          # model and hardware tests
make pcaps         # build/tracked.pcap and friends
dune exec bin/verify.exe -- build/tracked.pcap -verilator -report results/verify_tracked.txt
TOP=timing_top XDC=fpga/timing_top.xdc SYNTH_OPTS=-retiming PLACE_DIRECTIVE=ExtraTimingOpt \
  PHYS_DIRECTIVE=AggressiveExplore ROUTE_DIRECTIVE=AggressiveExplore \
  ./fpga/vivado_build.sh fpga/build/timing_top.v fpga/build/vivado_timing   # core timing
```

The sample prefix used has SHA-256
`546e9e4b522556533387e574ce1ba632beebe83701b72251a6600893f46a1ec6`. Each
test directory is its own dune root (`ppx_expect` needs that), and tests
that need the sample or the pcaps skip themselves when those are missing.
`fpga/build/timing_top.v` comes from
`dune exec bin/gen_verilog.exe -- timing_top fpga/build/timing_top.v`.

**1 Gb/s board test**, with the Wukong on a direct cable to `eno1` and
`tcpreplay` installed (the scripts make the `sudo` network changes and undo
them afterwards):

```bash
dune exec bin/gen_verilog.exe -- board_top_gmii 26 fpga/build/board_top_gmii.v
SYNTH_OPTS=-retiming OPT_OPTS="-retarget -propconst -sweep" PLACE_DIRECTIVE=ExtraTimingOpt \
  PHYS_DIRECTIVE=AggressiveExplore ROUTE_DIRECTIVE=AggressiveExplore \
  ./fpga/vivado_build.sh fpga/build/board_top_gmii.v fpga/build/vivado_gmii 8   # 8: the receive clock period, ns
cp fpga/build/vivado_gmii/board_top.bit fpga/build/board_top_gmii.bit
./scripts/fpga_connect.sh      # program; send lines A and B with losses; answer re-requests; compare
./scripts/fpga_disconnect.sh   # after unplugging: eno1 back to NetworkManager
```

`fpga_connect.sh` runs `scripts/board_recovery.sh`. `pcapgen ab` builds the
two lines (2% of packets lost on each, `DROP_A`/`DROP_B`), and
`scripts/mold_server.py` (root, raw sockets) answers the board's
re-requests with the recorded session. Whatever the lines, the host's
sender and the retransmissions do, the board has to end up with the
reference book's changes and orders over the whole session. `AB=0` sends
the recorded feed on one line, `PPS=R` paces it, and `LIMIT=N` replays a
prefix. For an image without recovery, `TEST=linerate` runs
`scripts/board_linerate.sh` instead (the model runs on what the host really
sent; `scripts/board_sweep.sh` runs several rates).

**100 Mb/s board test** (MII image, 400 packets through the host's UDP
stack, every `E` line compared):

```bash
make board-pcap                        # build/board_slow.pcap
TARGET_MHZ=50 ./fpga/build_board.sh    # writes fpga/build/board_top_50.v (and an openXC7 image)
./fpga/vivado_build.sh fpga/build/board_top_50.v fpga/build/vivado_board50 40
sudo nmcli device set eno1 managed no && sudo ip link set eno1 up
sudo ethtool -s eno1 advertise 0x008 autoneg on        # 100 Mb/s only
sudo ip address add 192.168.10.1/24 dev eno1
BITSTREAM=fpga/build/vivado_board50/board_top.bit make replay
sudo ip address del 192.168.10.1/24 dev eno1
sudo ethtool -s eno1 advertise 0x02f autoneg on && sudo nmcli device set eno1 managed yes
```

**On-chip self-test** (no PHY or network needed):

```bash
SELFTEST_PCAP=build/board_subset.pcap TARGET_MHZ=50 ./fpga/build_board.sh
openFPGALoader-xpcu -c xilinxPlatformCableUsb fpga/build/board_top_50_selftest.bit
./fpga/netlist_sim/run.sh selftest     # the same netlist in gate-level simulation
```

## Repository

| Path | Contents |
| --- | --- |
| `src/model` | ITCH 5.0 codec, reference book, architectural model of the hardware book, CRC-32 |
| `src/net` | Ethernet/IPv4/UDP/MoldUDP64 frames and pcap files |
| `src/hw` | the RTL: GMII/MII MAC, frame and MoldUDP64 parsers, ITCH decoder, symbol filter, order book, board top with UART and GMII capture |
| `bin` | `verify` (full-pipeline replay), `pcapgen` (pcaps, expected board output), `itch_tool` (data profiling), `gen_verilog` |
| `tests` | model, network and hardware test suites (separate dune roots) |
| `fpga` | constraints, Vivado and openXC7 builds, gate-level simulation |
| `scripts` | data download, board replay and line-rate tests |
| `results` | every measurement quoted here |

## Limits

- **Sender:** the 1 Gb/s board test is limited by my PC, which averages
  about 100 Mb/s with tcpreplay and drops and reorders frames above roughly
  60,000 frames/s. Sustained 1 Gb/s traffic has only been simulated.
- **Feed recovery:** the board takes lines A and B and asks for whatever
  both miss, but its buffer only holds 2,048 messages (32 KB). If a
  retransmission takes longer than that buffer lasts at the feed's rate, it
  costs more requests, or messages get given up (counted, and flagged as
  stale).
- **Orders:** the rule is a demo, not a strategy: one symbol, one limit, no
  position or risk limits. OUCH 5.0 messages go out in UDP datagrams, while
  a real venue takes them over SoupBinTCP. Tick-to-trade is measured
  between the FPGA's GMII pins and doesn't include the PHY's own receive and
  transmit latency.
- **Checksums:** FCS, IP and UDP checksums don't gate cut-through book
  writes; the MAC counts bad FCS for diagnostics.
- **Field widths and capacity:** order references up to 32 bits, shares up
  to 24 bits per order, eight symbols. Unsupported values are counted.
- **Latency tail:** a command whose side's cache empties before the
  background refill finishes waits for the 2,048-row level scan; 63 of the
  1.74 million commands waited more than 1,000 cycles.
- **Toolchain:** board images need Vivado. The openXC7 builds carry two
  workarounds (no yosys FSM re-encoding; no BRAM table deeper than 2,048
  rows) and still failed at speed on the board
  ([`board_toolchains.txt`](results/board_toolchains.txt)).
- **Data:** the sample prefix is not a complete trading day.
