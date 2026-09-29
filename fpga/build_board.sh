#!/usr/bin/env bash
# Build a volatile SRAM bitstream for the Wukong XC7A100T. Does not program it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
eval "$(opam env --switch=oxcaml)"
source /opt/openxc7/export.sh
b=fpga/build
target_mhz="${TARGET_MHZ:-125}"
case "$target_mhz" in
  50|125) ;;
  *) echo 'TARGET_MHZ must be 50 or 125' >&2; exit 2 ;;
esac
stem="$b/board_top_${target_mhz}"
mkdir -p "$b"
cp fpga/wukong.xdc "$stem.xdc"
if [[ $target_mhz == 50 ]]; then
  # At a negotiated 100 Mb/s link the PHY presents MII nibbles at 25 MHz.
  sed -i 's/create_clock -period 8.000 \[get_ports e_rxc\]/create_clock -period 40.000 [get_ports e_rxc]/' "$stem.xdc"
  top_kind=board_top_mii
else
  top_kind=board_top
fi
if [[ ! -s $b/xc7a100tfgg676.bin ]]; then
  tutorial_chipdb="${TUTORIAL_CHIPDB:-$HOME/hardcaml-tutorial/fpga/build/xc7a100tfgg676.bin}"
  cp "$tutorial_chipdb" "$b/xc7a100tfgg676.bin"
fi
dune build ./bin/gen_verilog.exe
./_build/default/bin/gen_verilog.exe "$top_kind" "$stem.v"
yosys -q -l "$stem.yosys.log" -p "read_verilog $stem.v; synth_xilinx -flatten -abc9 -arch xc7 -top board_top; stat; write_json $stem.json"
if grep -qi 'self-resetting' "$stem.yosys.log"; then
  echo 'ERROR: self-resetting FSM in synthesized design' >&2
  exit 1
fi
nextpnr-xilinx --chipdb "$b/xc7a100tfgg676.bin" --xdc "$stem.xdc" \
  --json "$stem.json" --fasm "$stem.fasm" \
  --report "$stem.report.json" --freq "$target_mhz" \
  -l "$stem.nextpnr.log" -q
fpga-as --prjxray_db_path="$PRJXRAY_DB_DIR/artix7" \
  --part xc7a100tfgg676-1 "$stem.fasm" > "$stem.bit"
ls -lh "$stem.bit"
