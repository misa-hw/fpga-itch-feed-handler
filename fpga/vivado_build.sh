#!/usr/bin/env bash
# Vendor-flow implementation (Vivado, non-project batch mode) of a generated
# board Verilog, to cross-check the openXC7 flow on the same design.
#   fpga/vivado_build.sh VERILOG OUT_DIR [RX_PERIOD_NS]
# RX_PERIOD_NS: 40 for the 100 Mb/s MII build (default), 8 for gigabit.
# TOP=timing_top XDC=fpga/timing_top.xdc: the core timing wrapper instead of
# the board (its XDC is used as is; no bitstream is needed but one is written).
# SYNTH_OPTS: extra synth_design options (e.g. "-retiming").
# PLACE_DIRECTIVE / PHYS_DIRECTIVE / ROUTE_DIRECTIVE: Vivado strategy
# directives (default: Default); a post-route phys_opt runs if setup fails.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
v=$1; out=$2; rx_period=${3:-40}
vivado=${VIVADO:-$(find "$HOME/Xilinx" -maxdepth 4 -path '*Vivado/bin/vivado' -type f | head -1)}
top=${TOP:-board_top}
mkdir -p "$out"
if [[ -n ${XDC:-} ]]; then
  cp "$XDC" "$out/board.xdc"
else
sed "s/create_clock -period 8.000 \[get_ports e_rxc\]/create_clock -period $rx_period.000 [get_ports e_rxc]/" \
  fpga/wukong.xdc > "$out/board.xdc"
cat >> "$out/board.xdc" <<'XDC'
# The two domains only meet through the asynchronous event FIFO and the
# counter handshake (both synchronised), so they are not timed against each other.
set_clock_groups -asynchronous -group [get_clocks -of_objects [get_ports clk50]] -group [get_clocks -quiet -of_objects [get_ports e_rxc]]
XDC
fi
cat > "$out/build.tcl" <<TCL
read_verilog $(realpath "$v")
read_xdc $(realpath "$out")/board.xdc
synth_design -top $top -part xc7a100tfgg676-1 ${SYNTH_OPTS:-}
opt_design
place_design -directive ${PLACE_DIRECTIVE:-Default}
phys_opt_design -directive ${PHYS_DIRECTIVE:-Default}
route_design -directive ${ROUTE_DIRECTIVE:-Default}
if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]] < 0} { phys_opt_design -directive AggressiveExplore }
report_timing_summary -file $(realpath "$out")/timing.rpt
report_timing -max_paths 50 -nworst 1 -file $(realpath "$out")/paths.rpt
report_utilization -file $(realpath "$out")/utilization.rpt
write_bitstream -force $(realpath "$out")/$top.bit
TCL
(cd "$out" && "$vivado" -mode batch -nojournal -log vivado.log -source build.tcl > /dev/null)
grep -A3 "Design Timing Summary" "$out/timing.rpt" | tail -1 || true
grep -E "WNS\(ns\)" -A2 "$out/timing.rpt" | head -3
ls -l "$out/$top.bit"
