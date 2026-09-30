#!/usr/bin/env bash
# Bitstream for the on-board block RAM check (src/hw/bram_probe.ml).
# Extra yosys options: YOSYS_PRE (commands before synth_xilinx), YOSYS_OPTS
# (synth_xilinx flags); SUFFIX names the output; PROBE=bram_probe_x9 builds
# the single-RAMB36E1 variant. The synthesized netlist is also written as
# $stem.net.v (for a Vivado place-and-route of the identical primitives).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
eval "$(opam env --switch=oxcaml)"
source /opt/openxc7/export.sh
b=fpga/build
stem=$b/bram_probe${SUFFIX:-}
dune build ./bin/gen_verilog.exe
./_build/default/bin/gen_verilog.exe ${PROBE:-bram_probe} $stem.v
yosys -q -l $stem.yosys.log -p "read_verilog $stem.v; ${YOSYS_PRE:-} synth_xilinx -flatten -abc9 -arch xc7 ${YOSYS_OPTS:-} -top bram_probe; stat; write_json $stem.json; write_verilog -noattr $stem.net.v"
nextpnr-xilinx --chipdb $b/xc7a100tfgg676.bin --xdc fpga/bram_probe.xdc --json $stem.json \
  --fasm $stem.fasm --freq 50 -l $stem.nextpnr.log -q
fpga-as --prjxray_db_path="$PRJXRAY_DB_DIR/artix7" --part xc7a100tfgg676-1 $stem.fasm > $stem.bit
grep -E "RAMB|Max frequency" $stem.yosys.log $stem.nextpnr.log | tail -4
ls -l $stem.bit
