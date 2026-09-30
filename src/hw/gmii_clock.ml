(* GMII receive capture for the 1 Gb/s board image.

   The RTL8211EG drives RXD, RXDV and RXER valid only from 2.5 ns before to
   0.5 ns after each RXC rising edge (datasheet rev 1.6, table 64), a 3 ns
   window at 125 MHz. Vivado's analysis of the alternatives, with that
   window constrained (fpga/vivado_build.sh):

   - RXC through a BUFG into IOB flip-flops: meets it only because Vivado
     applies the IOB's fixed zero-hold input delay; setup +0.35 ns, hold
     +0.17 ns.
   - A deskewing MMCM: no output phase meets both, the setup and hold
     slacks sum to about -1.6 ns across process corners.
   - This module, the 7-series source-synchronous scheme: setup +0.44 ns,
     hold +0.45 ns at 26 taps.

   How it works:
   - RXC arrives on an SRCC pin (P4) in bank 34, the same bank as the data
     pins. A BUFIO clocks the input flip-flops of that bank's IO blocks
     through a short, low-variation path.
   - Each data pin passes an IDELAYE2 (fixed taps of 78 ps, calibrated by an
     IDELAYCTRL running from a 200 MHz clock made from the 50 MHz
     oscillator), which places the data window around the BUFIO edge.
   - RXC also drives a BUFG for the rest of the receive domain. Captured
     bytes cross from the BUFIO clock to the BUFG clock through a
     falling-edge register, which gives the transfer about half a cycle of
     margin each way. *)

open! Core
open! Hardcaml
open Signal

let prim ?(parameters = []) name ~inputs ~outputs =
  let p (n, v) = Parameter.create ~name:n ~value:v in
  Instantiation.create () ~name ~parameters:(List.map parameters ~f:p) ~inputs ~outputs
;;

let bufg i = Instantiation.output (prim "BUFG" ~inputs:[ "I", i ] ~outputs:[ "O", 1 ]) "O"
let bufio i = Instantiation.output (prim "BUFIO" ~inputs:[ "I", i ] ~outputs:[ "O", 1 ]) "O"

(* 200 MHz IDELAYCTRL reference from the 50 MHz oscillator (VCO 1 GHz) *)
let refclk200 ~clk50 ~rst =
  let fb = wire 1 in
  let m =
    prim
      "MMCME2_BASE"
      ~parameters:
        [ "CLKIN1_PERIOD", Real 20.0
        ; "DIVCLK_DIVIDE", Int 1
        ; "CLKFBOUT_MULT_F", Real 20.0
        ; "CLKOUT0_DIVIDE_F", Real 5.0
        ]
      ~inputs:[ "CLKIN1", clk50; "CLKFBIN", fb; "RST", rst; "PWRDWN", gnd ]
      ~outputs:[ "CLKOUT0", 1; "CLKFBOUT", 1; "LOCKED", 1 ]
  in
  assign fb (Instantiation.output m "CLKFBOUT");
  bufg (Instantiation.output m "CLKOUT0"), Instantiation.output m "LOCKED"
;;

let idelayctrl ~refclk ~rst =
  Instantiation.output
    (prim "IDELAYCTRL" ~inputs:[ "REFCLK", refclk; "RST", rst ] ~outputs:[ "RDY", 1 ])
    "RDY"
;;

let idelay ~taps d =
  Instantiation.output
    (prim
       "IDELAYE2"
       ~parameters:
         [ "IDELAY_TYPE", String "FIXED"
         ; "DELAY_SRC", String "IDATAIN"
         ; "IDELAY_VALUE", Int taps
         ; "HIGH_PERFORMANCE_MODE", String "TRUE"
         ; "SIGNAL_PATTERN", String "DATA"
         ; "REFCLK_FREQUENCY", Real 200.0
         ; "CINVCTRL_SEL", String "FALSE"
         ; "PIPE_SEL", String "FALSE"
         ]
       ~inputs:
         [ "IDATAIN", d
         ; "DATAIN", gnd
         ; "C", gnd
         ; "CE", gnd
         ; "INC", gnd
         ; "LD", gnd
         ; "LDPIPEEN", gnd
         ; "REGRST", gnd
         ; "CINVCTRL", gnd
         ; "CNTVALUEIN", zero 5
         ]
       ~outputs:[ "DATAOUT", 1; "CNTVALUEOUT", 5 ])
    "DATAOUT"
;;

type t =
  { rxc : Signal.t (* BUFG'd RXC, for the receive domain *)
  ; rxd : Signal.t
  ; rx_dv : Signal.t
  ; rx_er : Signal.t
  ; ready : Signal.t (* IDELAYCTRL calibrated; asynchronous *)
  }

(* [clear50]: the 50 MHz domain's power-on/KEY0 reset. *)
let create ~taps ~clk50 ~clear50 ~e_rxc ~e_rxd ~e_rxdv ~e_rxer =
  let refclk, locked = refclk200 ~clk50 ~rst:clear50 in
  let ready = idelayctrl ~refclk ~rst:~:locked in
  let rxc = bufg e_rxc in
  let io = Reg_spec.create ~clock:(bufio e_rxc) () in
  let fall = Reg_spec.create ~clock_edge:Falling ~clock:rxc () in
  let rise = Reg_spec.create ~clock:rxc () in
  let capture s =
    bits_lsb s |> List.map ~f:(fun b -> reg io (idelay ~taps b)) |> concat_lsb |> reg fall |> reg rise
  in
  { rxc; rxd = capture e_rxd; rx_dv = capture e_rxdv; rx_er = capture e_rxer; ready }
;;
