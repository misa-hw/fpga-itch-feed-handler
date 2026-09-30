#!/usr/bin/env bash
# Simulation library for yosys-synthesized Xilinx netlists: yosys's
# cells_sim.v, except RAMB18E1/RAMB36E1, which there are timing-only shells
# with no memory behaviour, taken from Vivado's unisims instead.
set -euo pipefail
out=$1
y=$(dirname "$(dirname "$(which yosys)")")/share/yosys/xilinx/cells_sim.v
u=${UNISIMS:-$(find "$HOME/Xilinx" -path '*data/verilog/src/unisims' -type d | head -1)}
python3 - "$y" "$out.tmp" <<'PY'
import sys
s = open(sys.argv[1]).read()
for m in ["RAMB18E1", "RAMB36E1"]:
    a = s.index("module %s (" % m)
    b = s.index("endmodule", a) + len("endmodule")
    s = s[:a] + "// %s: functional model from unisims\n" % m + s[b:]
open(sys.argv[2], "w").write(s)
PY
# Verilator does not support procedural assign/deassign. The unisims use it
# only to force the ECC outputs (unused here) to 0 and, during GSR, the data
# outputs to their INIT values; stimulus starts long after GSR, and the
# design clears its tables itself.
cat "$out.tmp" "$u/RAMB18E1.v" "$u/RAMB36E1.v" "$u/../glbl.v" \
  | grep -vE '^[[:space:]]*(de)?assign (dbiterr_out|sbiterr_out|rdaddrecc_out|doa_out|dopa_out|dob_out|dopb_out)\b' > "$out"
rm "$out.tmp"
