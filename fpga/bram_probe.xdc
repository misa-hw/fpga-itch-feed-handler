# BRAM probe (src/hw/bram_probe.ml): 50 MHz clock, KEY0, UART only
set_property -dict {PACKAGE_PIN M21 IOSTANDARD LVCMOS33} [get_ports clk50]
create_clock -period 20.000 [get_ports clk50]
set_property -dict {PACKAGE_PIN H7 IOSTANDARD LVCMOS33 PULLUP true} [get_ports reset_n]
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports uart_tx]
