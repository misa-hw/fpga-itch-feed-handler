# FPGA ITCH feed handler

A Hardcaml market-data receive pipeline for the QMTech Wukong XC7A100T. It
accepts GMII bytes at 1 Gb/s or MII nibbles at 100 Mb/s carrying
Ethernet/IPv4/UDP/MoldUDP64/Nasdaq ITCH 5.0,
tracks eight configurable symbols, and emits top-of-book changes. An OCaml
reference book and a bit-accurate architectural model live alongside the RTL.
[DESIGN.md](DESIGN.md) explains the data structures and trade-offs.

```text
GMII/MII -> MAC/FCS -> Ethernet/IP/UDP -> MoldUDP64 -> ITCH -> symbol map
                                                        |
                                              FIFO -> order BRAM
                                                   -> level BRAM
                                                   -> top cache -> event/UART
```

The parser consumes one byte per clock without backpressure. The
order table uses two hashed four-way BRAM banks with bounded cuckoo
displacement. Price levels use two more hashed banks. Each book side has a
sorted eight-level prefix; when it empties, a full level-table scan restores it.
Capacity failures are counted.

## Reproduce

Developed with OCaml 5.2+Ox, dune 3.24, Hardcaml
`v0.18~preview.130.106+341`, Verilator 5.032, and openXC7 (Yosys 0.52 and
nextpnr-xilinx). FPGA scripts expect `/opt/openxc7` and the already built
chip database at `~/hardcaml-tutorial/fpga/build/xc7a100tfgg676.bin`.

```bash
eval "$(opam env --switch=oxcaml)"
make data
make test
make pcaps
make board-pcap
dune exec bin/itch_tool.exe -- profile data/07302019.prefix.raw
dune exec bin/itch_tool.exe -- hwmodel data/07302019.prefix.raw
dune exec bin/verify.exe -- build/tracked.pcap -verilator -report results/verify_tracked.txt
./fpga/timing.sh
```

[`fetch_itch.sh`](scripts/fetch_itch.sh) downloads a compressed prefix of
Nasdaq's public [07302019 ITCH 5.0 sample](https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/).
The measured local prefix has SHA-256
`546e9e4b522556533387e574ce1ba632beebe83701b72251a6600893f46a1ec6`.
Tests use separate dune roots for `ppx_expect`. Tests requiring the sample or
generated pcaps skip if those inputs are absent.

## Verification

The reference book uses an order-reference table and per-side price maps.
It is property-tested against a naive rescan. The architectural model
reproduces hardware hashes, capacities, collisions and cache rules; random
tests and a full-sample replay compare it with the reference. Hardware tests
exercise the parsers, book, GMII/MII MAC and UART. Full-pipeline verification
sends pcap bytes at 1 Gb/s line rate, compares every hardware book event by
Mold sequence number, and measures cycles from the message's last input byte
to its event. The tracked pcap holds 1,752,946 messages in 1,655,589 packets
from a 32.6-million-message prefix.

Board-level simulation also checks the PHY-facing MAC and UART: 400 GMII
frames produced the same 39 event lines and `6debb1d9` hash as the model;
a 100 Mb/s MII nibble-stream test matched two event lines and detected a
deliberately corrupted FCS.

The strict full replay with the eight-level configuration is recorded in
[`results/verify_tracked.txt`](results/verify_tracked.txt): 1,740,696
hardware and reference book commands, 1,043,727 top-of-book changes, zero
mismatches, missing events or overflows. Event latency, from the last byte
of a message on the MAC stream to the book's event, was 20 cycles median,
31 at p99, 41 at p99.9 and 2,739 at most; 117 commands (0.0067%) took more
than 64 cycles. Cache refills run in the background, so a command waits only
when its book side's cache empties before a refill finishes (10,756 cycles
in the whole replay). With the earlier blocking refill
([`results/verify_tracked_blocking.txt`](results/verify_tracked_blocking.txt))
p99 was 672, p99.9 2,078 and the maximum 6,016. These are simulation results
at a modeled 125 MHz receive clock; the routed board clock is measured
separately.

| Measured item | Result |
| --- | ---: |
| Peak live orders | 27,573 / 32,768 slots |
| Peak live price levels | 7,633 / 16,384 slots |
| Event latency, full replay (cycles) | p50 20, p99 31, p99.9 41, max 2,739 |
| FIFO maximum occupancy in full replay | 25 / 512 commands |
| Background cache refills in full replay | 4,905 (10,756 cycles waited) |
| Core at 125 MHz, **Vivado** | **met**: WNS +0.021 ns, hold met (retiming, aggressive directives) |
| Core resources, Vivado | 14,582 LUTs (23%), 8,972 FFs (7%), 98 BRAM tiles (73%) |
| Core openXC7 routed Fmax | 78.59 MHz (93.36 MHz before the board workarounds); not trustworthy on silicon, see below |
| Core logic cells estimated by Yosys | 13,023 |
| Core block RAM | 67 RAMB36 + 62 RAMB18 |
| 1 Gb/s board, full dataset over a cable | 1,043,727 changes, hash equal to the reference ([details](results/board_gigabit.txt)) |
| 1 Gb/s board image, Vivado | met: WNS +0.009 ns; GMII inputs +0.44 / +0.45 ns setup / hold |
| 100 Mb/s board routed Fmax | 94.23 MHz receive / 111.92 MHz UART; 25 / 50 MHz targets met |

The complete synthesis and timing numbers are in
[`results/timing.txt`](results/timing.txt).

[`Timing_top`](src/hw/timing_top.ml) measures the complete receive core with
registered MAC-stream inputs and folded outputs. The board top adds the
GMII/MII MAC, UART, clock crossing and
status logic. The 1 Gb/s board image also meets 125 MHz, including the PHY's
GMII input window (below).

## Board path

The [QMTech schematic](https://github.com/ChinaQMTECH/QM_XC7A100T_WUKONG_BOARD/blob/master/V3/Hardware/QMTECH-XC7A100T_200T-Wukong-Board-V03-20240121.pdf)
and [GMII example](https://github.com/ChinaQMTECH/QM_XC7A100T_WUKONG_BOARD/blob/master/V3/Software/XC7A100T/Test08_GMII_Ethernet.zip)
identify an RTL8211EG PHY on **GMII/MII**, with RX clock on P4 and RX data on
M4/N3/N4/P3/R3/T3/T4/T5. [`fpga/wukong.xdc`](fpga/wukong.xdc) records
the board pinout. The [RTL8211EG datasheet](https://datasheet.lcsc.com/lcsc/1810010421_Realtek-Semicon-RTL8211E-VB-CG_C90735.pdf)
specifies 8-bit GMII bytes at 125 MHz for 1 Gb/s. At 100 Mb/s, it sends
the low and high MII nibbles on RXD[3:0] at 25 MHz. The `board_top_mii`
build assembles them into bytes. The board top uses the PHY RX clock for the
feed and 50 MHz for UART, with an asynchronous event FIFO and power-on reset in both
domains. UART emits `E` lines for changes and `S` lines for counters. At full
traffic rate it may drop `E` lines; the status includes a count and CRC over
all changes for comparison with `pcapgen expect`. The `S1` prefix means the
receive clock responded to a status request; this PHY also runs that clock
without an Ethernet link.

`fpga/build_board.sh` builds a volatile bitstream. `TARGET_MHZ=50` selects
the MII variant and constrains the 25 MHz receive and 50 MHz UART clocks.
The board testbench feeds frames with FCS in both modes and compares the UART
stream to the model. The [physical idle test](results/board_idle.txt)
programmed the MII bitstream over JTAG and captured complete UART status
lines with zero error counters.

**Over a real Ethernet cable, the board matches the model.** The PC sends
400 MoldUDP64 packets of real ITCH data over a direct 100 Mb/s link to the
Vivado-built image; the board accepts all 400 frames with no FCS errors,
processes 97 book commands, and prints 39 top-of-book changes identical to
the OCaml model's, with the same on-chip change count and hash (`6debb1d9`)
([`results/board_cable_vivado.txt`](results/board_cable_vivado.txt)).

**Over a 1 Gb/s link, the board reproduces the whole dataset.** The
gigabit image received the tracked pcap over a direct 1000 Mb/s cable at
60,000 frames/s: 1,655,585 of its 1,655,589 frames (the PC dropped the last
four), 1,752,942 messages, no duplicates, gaps, FCS errors or overflows. The
board's on-chip count and CRC-32 hash of every top-of-book change,
1,043,727 changes and `186f6e17`, are exactly the reference book's for the
complete pcap, and the Verilator replay's
([`results/board_gigabit.txt`](results/board_gigabit.txt)).

At top speed (132,000 frames/s, 99.5 Mb/s on average, frames reaching the
NIC as little as 0.95 us apart) the PC itself drops and reorders frames
before they reach the NIC (123 dropped and 65,262 out of order over the
whole pcap), and tcpreplay still reports them as sent. The test therefore
records the frames leaving the host with tcpdump, rebuilds them in that
order, and runs the reference book on them with the hardware's MoldUDP64
rule (a late message is a duplicate). The board matches it exactly there
too: 729,207 duplicates, 45,278 gaps, 2,948 changes, hash `6e0f8b00`.

Capturing the GMII bytes at 125 MHz needed the 7-series source-synchronous
scheme: a BUFIO-clocked input register behind a 26-tap IDELAY on every data
pin, which Vivado times against the RTL8211EG's datasheet window with
+0.44 ns setup and +0.45 ns hold margin
([DESIGN.md section 8](DESIGN.md#8-clocking-and-reset-on-the-board)).

**On silicon, the feed handler core matches the model.** An on-chip self-test
bitstream plays 108 real frames from a ROM into the pipeline, with no PHY,
cable or network configuration. Its UART status reports 97 book commands and
the model's exact change count and hash (`6debb1d9`). The printed event lines
are an ordered subsequence of the model's
([`results/board_selftest.txt`](results/board_selftest.txt)). Getting there
took three fixes that no simulation could show: the receive domain is now
held in reset while the PHY resets, yosys FSM re-encoding is disabled, and
4,096-deep tables are built from 2,048-deep BRAMs. See
[DESIGN.md section 9](DESIGN.md#9-board-bring-up-what-simulation-did-not-catch)
and [`results/bram_probe.txt`](results/bram_probe.txt).

Only the Vivado bitstreams are reliable on the board (see the toolchain
comparison in DESIGN.md section 9). The cable image:

```bash
TARGET_MHZ=50 ./fpga/build_board.sh            # generates fpga/build/board_top_50.v (and an openXC7 image)
./fpga/vivado_build.sh fpga/build/board_top_50.v fpga/build/vivado_board50 40
BITSTREAM=fpga/build/vivado_board50/board_top.bit make replay   # after the network setup below
```

The gigabit image and test (with the Wukong cabled to `eno1`; the scripts
run the `sudo` network changes and undo them):

```bash
./_build/default/bin/gen_verilog.exe board_top_gmii 26 fpga/build/board_top_gmii.v
SYNTH_OPTS=-retiming PLACE_DIRECTIVE=ExtraTimingOpt PHYS_DIRECTIVE=AggressiveExplore \
  ROUTE_DIRECTIVE=AggressiveExplore ./fpga/vivado_build.sh fpga/build/board_top_gmii.v fpga/build/vivado_gmii 8
cp fpga/build/vivado_gmii/board_top.bit fpga/build/board_top_gmii.bit
./scripts/fpga_connect.sh      # program, replay the whole pcap at top speed, compare
./scripts/fpga_disconnect.sh   # after unplugging: eno1 back to NetworkManager
```

`LIMIT=N` and `PPS=R` replay a prefix at a fixed rate;
`scripts/board_sweep.sh` runs several rates.

The self-test:

```bash
SELFTEST_PCAP=build/board_subset.pcap TARGET_MHZ=50 ./fpga/build_board.sh
openFPGALoader-xpcu -c xilinxPlatformCableUsb fpga/build/board_top_50_selftest.bit
./fpga/netlist_sim/run.sh selftest   # the same netlist in gate-level simulation
```

The first direct-cable replay (before these fixes) accepted all 400 frames
with no FCS errors and decoded all 403 messages, but the book processed none;
the self-test reproduced and localised that. On an earlier attempt,
NetworkManager restarted DHCP and removed the temporary host address before
replay could send a packet; the script now checks the address and negotiated
100 Mb/s link before and after programming.
For a direct cable from the Wukong to `eno1`, swap the PC's LAN cable for the
Wukong cable. [NetworkManager can temporarily stop managing an interface](https://networkmanager.dev/docs/admins/),
which keeps it from replacing the static address when the link changes.
These network changes need root:

```bash
sudo nmcli device set eno1 managed no
sudo ip link set eno1 up
sudo ethtool -s eno1 advertise 0x008 autoneg on
sudo ip address add 192.168.10.1/24 dev eno1
ip -4 -br address show eno1  # confirm 192.168.10.1/24
cat /sys/class/net/eno1/speed # confirm 100
BITSTREAM=fpga/build/board_top_50.bit make replay
sudo ip address del 192.168.10.1/24 dev eno1  # run even if replay fails
sudo ethtool -s eno1 advertise 0x02f autoneg on
sudo nmcli device set eno1 managed yes
```

Reconnect the LAN cable after restoring NetworkManager management. If the
address has already disappeared, the `ip address del` command can report
that it was not found; continue the remaining restore commands.

`make replay` uses ordinary multicast UDP sockets, so no static ARP entry,
raw-socket privilege or `tcpreplay` package is needed. It sends the first
400 packets at a UART-friendly rate and writes `results/board_uart.txt`.

## Limits

- There is no MoldUDP64 retransmission client or gap recovery; duplicates
  and sequence gaps are counted.
- The 1 Gb/s board test is limited by its sender: this PC averages about
  100 Mb/s with tcpreplay, and drops and reorders frames above about
  60,000 frames/s, so the board is checked against what was actually sent.
  Sustained 1 Gb/s traffic has only been simulated.
- FCS, IP and UDP checksums do not gate cut-through book writes. The MAC
  counts bad FCS for diagnostics.
- Order references are limited to 32 bits, shares to 24 bits per order, and
  capacity to the selected eight symbols. Unsupported values are counted.
- A command whose book side's cache empties before the background refill
  finishes waits for the 2,048-row level scan: 63 commands of 1.74M waited
  over 1,000 cycles.
- openXC7 bitstreams failed at speed on the board although nextpnr reported
  2-4x timing margin ([`results/board_toolchains.txt`](results/board_toolchains.txt));
  the Vivado build of the same Verilog is correct. Board images are built
  with Vivado.
- openXC7 workarounds, found on the board: yosys FSM extraction is disabled
  in every build, and no BRAM table is deeper than 2,048 rows (RAMB36E1 in
  4K x 9 mode read back wrong). The BRAM bug is fixed upstream-bound in
  [openXC7/nextpnr#63](https://github.com/openXC7/nextpnr/pull/63).
- The sample prefix is not a complete trading day.
