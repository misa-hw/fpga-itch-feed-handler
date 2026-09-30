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
mismatches, missing events or overflows, and 1,097 cache refills. Median
event latency was 20 cycles, p99 was 672, and the maximum was 6,016. The
latency tail includes time spent queued behind refills. These are simulation
results at a modeled 125 MHz receive clock; the routed board clock is
measured separately.

| Measured item | Result |
| --- | ---: |
| Peak live orders | 27,573 / 32,768 slots |
| Peak live price levels | 7,633 / 16,384 slots |
| FIFO maximum occupancy in full replay | 54 / 512 commands |
| Cache refills in full replay | 1,097 |
| Core openXC7 routed Fmax | 93.36 MHz; 125 MHz target missed |
| Core logic cells estimated by Yosys | 13,023 |
| Core block RAM | 67 RAMB36 + 62 RAMB18 |
| 100 Mb/s board routed Fmax | 89.61 MHz receive / 120.39 MHz UART; 25 / 50 MHz targets met |

The complete synthesis and timing numbers are in
[`results/timing.txt`](results/timing.txt).

[`Timing_top`](src/hw/timing_top.ml) measures the complete receive core with
registered MAC-stream inputs and folded outputs. The board top adds the
GMII/MII MAC, UART, clock crossing and
status logic. Physical 1 Gb/s throughput requires a 125 MHz board route.

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
- FCS, IP and UDP checksums do not gate cut-through book writes. The MAC
  counts bad FCS for diagnostics.
- Order references are limited to 32 bits, shares to 24 bits per order, and
  capacity to the selected eight symbols. Unsupported values are counted.
- A 2,048-row level scan causes the long latency tail when a cache empties.
- openXC7 workarounds, found on the board: yosys FSM extraction is disabled
  in every build, and no BRAM table is deeper than 2,048 rows (RAMB36E1 in
  4K x 9 mode read back wrong).
- The sample prefix is not a complete trading day.
