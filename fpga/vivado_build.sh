#!/usr/bin/env bash
# Vendor-flow implementation (Vivado, non-project batch mode) of a generated
# board Verilog, to cross-check the openXC7 flow on the same design.
#   fpga/vivado_build.sh VERILOG OUT_DIR [RX_PERIOD_NS]
# RX_PERIOD_NS: 40 for the 100 Mb/s MII build (default), 8 for gigabit
# (which also constrains the GMII receive inputs).
# TOP=timing_top XDC=fpga/timing_top.xdc: the core timing wrapper instead of
# the board (its XDC is used as is; no bitstream is needed but one is written).
# SYNTH_OPTS: extra synth_design options (e.g. "-retiming").
# OPT_OPTS: opt_design options (default: all of opt_design's defaults; e.g.
#   "-retarget -propconst -sweep" leaves out BRAM power gating, which puts a
#   LUT on each BRAM enable).
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
set_clock_groups -asynchronous -group [get_clocks -of_objects [get_ports clk50]] -group [get_clocks -quiet -include_generated_clocks -of_objects [get_ports e_rxc]]
XDC
if [[ $rx_period == 8 ]]; then
cat >> "$out/board.xdc" <<'XDC'
# GMII receive at 1 Gb/s, RTL8211EG datasheet rev 1.6 table 64: RXD, RXDV and
# RXER are valid from 2.5 ns before to 0.5 ns after each RXC rising edge
# (the RXDLY strap only applies to RGMII).
set_input_delay -clock [get_clocks -of_objects [get_ports e_rxc]] -max 5.5 [get_ports {e_rxd[*] e_rxdv e_rxer}]
set_input_delay -clock [get_clocks -of_objects [get_ports e_rxc]] -min 0.5 [get_ports {e_rxd[*] e_rxdv e_rxer}]
# capture in the input flip-flops of the IO blocks: fixed, short data path
set_property IOB TRUE [get_ports {e_rxd[*] e_rxdv e_rxer}]
# GMII transmit (table 64: TXD and TXEN set up 2 ns before and held 0 ns
# after GTX_CLK rising). GTX_CLK is the receive clock inverted by an ODDR,
# so the PHY samples half a cycle after the IOB output registers launch.
create_generated_clock -name gtx_clk -invert -divide_by 1 \
  -source [get_pins -hierarchical -filter {NAME =~ *gtx_clk_oddr/C}] [get_ports e_gtxc]
set_output_delay -clock gtx_clk -max 2.0 [get_ports {e_txd[*] e_txen e_txer}]
set_output_delay -clock gtx_clk -min 0.0 [get_ports {e_txd[*] e_txen e_txer}]
set_property IOB TRUE [get_ports {e_txd[*] e_txen}]
XDC
fi
fi
cat > "$out/build.tcl" <<TCL
read_verilog $(realpath "$v")
read_xdc $(realpath "$out")/board.xdc
synth_design -top $top -part xc7a100tfgg676-1 ${SYNTH_OPTS:-}
opt_design ${OPT_OPTS:-}
place_design -directive ${PLACE_DIRECTIVE:-Default}
phys_opt_design -directive ${PHYS_DIRECTIVE:-Default}
route_design -directive ${ROUTE_DIRECTIVE:-Default}
if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]] < 0} { phys_opt_design -directive AggressiveExplore }
report_timing_summary -file $(realpath "$out")/timing.rpt
report_timing -max_paths 50 -nworst 1 -file $(realpath "$out")/paths.rpt
report_timing -from [all_inputs] -to [all_registers] -max_paths 12 -nworst 1 -delay_type min_max -file $(realpath "$out")/inputs.rpt
report_utilization -file $(realpath "$out")/utilization.rpt
# how much of the design is near-critical, not just the single worst path
set hist [open $(realpath "$out")/slack_histogram.txt w]
foreach t {0.1 0.2 0.3 0.5 1.0} {
  puts \$hist "setup endpoints with slack below \$t ns: [llength [get_timing_paths -setup -max_paths 100000 -nworst 1 -slack_lesser_than \$t]]"
}
close \$hist
write_checkpoint -force $(realpath "$out")/routed.dcp
write_bitstream -force $(realpath "$out")/$top.bit
TCL
(cd "$out" && "$vivado" -mode batch -nojournal -log vivado.log -source build.tcl > /dev/null)
grep -A3 "Design Timing Summary" "$out/timing.rpt" | tail -1 || true
grep -E "WNS\(ns\)" -A2 "$out/timing.rpt" | head -3
ls -l "$out/$top.bit"
