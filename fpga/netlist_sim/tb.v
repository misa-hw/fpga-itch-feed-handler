// Gate-level test bench for the board top (built with gen_verilog
// board_top_mii_sim: 4-cycle UART bits, 20k-cycle status period).
// Two real clocks: 25 MHz MII RX_CLK and the 50 MHz oscillator. The MII
// stimulus comes from make_stim.py; the UART pin is decoded to uart.txt.
`timescale 1ns/1ps
module tb;
  reg clk50 = 0, rxc = 0;
  always #10 clk50 = ~clk50;
  always #20 rxc = ~rxc;

  reg reset_n = 1;
  reg [7:0] rxd = 0;
  reg rxdv = 0, rxer = 0;
  wire uart_tx, e_reset, e_mdc, e_txen, e_txer, led;

  board_top dut (
    .clk50(clk50), .reset_n(reset_n), .e_rxc(rxc), .e_rxd(rxd), .e_rxdv(rxdv),
    .e_rxer(rxer), .uart_tx(uart_tx), .e_reset(e_reset), .e_mdc(e_mdc),
    .e_txen(e_txen), .e_txer(e_txer), .led(led));

  reg [7:0] stim [0:`STIM_LEN-1];
  integer i, f;
  initial begin
    $readmemh("stim.hex", stim);
    f = $fopen("uart.txt", "w");
    for (i = 0; i < `STIM_LEN; i = i + 1) begin
      @(negedge rxc);
      rxdv = stim[i][4];
      rxd = {4'b0, stim[i][3:0]};
    end
    @(negedge rxc); rxdv = 0;
    // let the book finish and a status line or two print
    repeat (`TAIL_CYCLES) @(posedge clk50);
    $fclose(f);
    $finish;
  end

  // UART receiver, 4 clk50 cycles per bit, sampled mid-bit
  integer k;
  reg [7:0] byte_;
  always begin
    @(negedge uart_tx);
    repeat (2) @(posedge clk50);           // middle of the start bit
    for (k = 0; k < 8; k = k + 1) begin
      repeat (4) @(posedge clk50);
      byte_[k] = uart_tx;
    end
    repeat (4) @(posedge clk50);           // stop bit
    $fwrite(f, "%c", byte_);
    $fflush(f);
  end
endmodule
