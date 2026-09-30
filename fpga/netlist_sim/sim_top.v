// Top for the gate-level run: the test bench plus Xilinx glbl (global
// set/reset used by the unisim block RAM models).
module sim_top;
  tb tb ();
  glbl glbl ();
endmodule
