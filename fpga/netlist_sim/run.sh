#!/usr/bin/env bash
# Gate-level simulation of the synthesized MII board design, to separate
# synthesis problems from physical ones.
#   PCAP=build/board_subset.pcap fpga/netlist_sim/run.sh [rtl|fsm|nofsm|nobram|selftest] [PACKETS]
# selftest: the ROM self-test variant; frames come from $PCAP inside the chip
# rtl   : no synthesis, the Hardcaml Verilog itself (checks the test bench)
# fsm   : synth_xilinx exactly as fpga/build_board.sh does
# nofsm : same, but every wire marked fsm_encoding="none" first, so yosys
#         does not extract and re-encode state registers
# nobram: same, but no block RAM (memories in LUT RAM)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
mode=${1:-fsm}
n=${2:-400}
pcap=${PCAP:-build/board_subset.pcap}
d=fpga/build/netlist_sim_$mode
mkdir -p $d
eval "$(opam env --switch=oxcaml 2>/dev/null)" || true
source /opt/openxc7/export.sh
dune build ./bin/gen_verilog.exe ./bin/pcapgen.exe
if [[ $mode == rtl ]]; then
  # no synthesis: simulate the Hardcaml Verilog that yosys reads
  ./_build/default/bin/gen_verilog.exe board_top_mii_sim $d/rtl.v
  cp $d/rtl.v $d/netlist.v
elif [[ ! -s $d/netlist.v || -n ${RESYNTH:-} ]]; then
  if [[ $mode == selftest ]]; then
    ./_build/default/bin/gen_verilog.exe board_top_selftest_sim $pcap $d/rtl.v
  else
    ./_build/default/bin/gen_verilog.exe board_top_mii_sim $d/rtl.v
  fi
  pre=""; opts=""
  case $mode in
    fsm|selftest) ;;
    nofsm) pre='setattr -set fsm_encoding "none" w:*;' ;;
    nobram) opts="-nobram" ;;   # memories in LUT RAM: isolates the BRAM mapping
    *) echo "mode: rtl|fsm|nofsm|nobram|selftest" >&2; exit 2 ;;
  esac
  yosys -q -l $d/yosys.log -p "read_verilog $d/rtl.v; $pre synth_xilinx -flatten -abc9 -arch xc7 $opts -top board_top; write_verilog -noattr $d/netlist.v"
  grep -c "Recoding FSM" $d/yosys.log || true
fi
if [[ $mode == selftest ]]; then
  # the frames come from the on-chip ROM: keep the PHY silent
  python3 -c "print(\"00\\n\" * 60000, end=\"\")" > $d/stim.hex
else
  python3 fpga/netlist_sim/make_stim.py $pcap $n ${GAP:-200} $d/stim.hex
fi
len=$(wc -l < $d/stim.hex)
cells=fpga/build/netlist_sim_cells.v
[[ -s $cells ]] || fpga/netlist_sim/cells.sh $cells
top=sim_top; extra="fpga/netlist_sim/sim_top.v"
if [[ $mode == rtl ]]; then cells=""; top=tb; extra=""; fi
# Verilator: a 10 MB gate netlist is far too slow in iverilog
verilator --binary --timing -O2 -j 4 -Wno-fatal -Wno-lint -Wno-style --top-module $top \
  -DSTIM_LEN=$len -DTAIL_CYCLES=60000 --Mdir $d/obj \
  fpga/netlist_sim/tb.v $extra $d/netlist.v $cells > $d/verilator.log 2>&1 || { tail -30 $d/verilator.log; exit 1; }
(cd $d && time ./obj/V$top > sim.log)
echo "--- board UART ($mode)"
grep '^S' $d/uart.txt | tail -1
echo "E lines: $(grep -c '^E ' $d/uart.txt || true)"
echo "--- model"
./_build/default/bin/pcapgen.exe expect $pcap -max-packets $n -summary
