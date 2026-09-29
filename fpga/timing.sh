#!/usr/bin/env bash
# Synthesis + place & route of the core pipeline (Timing_top) at 125 MHz:
# the resource and Fmax numbers in the README.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
B=fpga/build
mkdir -p $B
eval "$(opam env --switch=oxcaml 2>/dev/null)" || true
source /opt/openxc7/export.sh
dune build ./bin/gen_verilog.exe
./_build/default/bin/gen_verilog.exe timing_top $B/timing_top.v
yosys -q -l $B/timing_top.yosys.log -p "read_verilog $B/timing_top.v; synth_xilinx -flatten -abc9 -arch xc7 -top timing_top; stat; write_json $B/timing_top.json"
if grep -qi "self-resetting" $B/timing_top.yosys.log; then echo "ERROR: self-resetting FSM"; exit 1; fi
nextpnr-xilinx --chipdb $B/xc7a100tfgg676.bin --xdc fpga/timing_top.xdc --json $B/timing_top.json \
  --fasm $B/timing_top.fasm --report $B/timing_top.report.json --freq 125 -l $B/timing_top.nextpnr.log -q || true
grep -E "Max frequency" $B/timing_top.nextpnr.log | tail -1
