(* Capture-only top level for tuning the GMII input delays (bring-up tool).
   It has the board's ports and only the Gmii_clock capture, folded into
   the LED so nothing is optimised away, which lets Vivado report the input
   timing for a given tap count in a few minutes instead of a full build. *)

open! Core
open! Hardcaml
open Signal

let create ~taps _scope (i : _ Board_top.I.t) : _ Board_top.O.t =
  let clear50 = Board_top.domain_clear ~clock:i.clk50 ~reset_n:i.reset_n in
  let g =
    Gmii_clock.create
      ~taps
      ~clk50:i.clk50
      ~clear50
      ~e_rxc:i.e_rxc
      ~e_rxd:i.e_rxd
      ~e_rxdv:i.e_rxdv
      ~e_rxer:i.e_rxer
  in
  let spec = Reg_spec.create ~clock:g.rxc () in
  let fold = reg_fb spec ~width:10 ~f:(fun a -> a ^: concat_msb [ g.rx_er; g.rx_dv; g.rxd ]) in
  { Board_top.O.uart_tx = vdd
  ; e_reset = vdd
  ; e_mdc = gnd
  ; e_txen = gnd
  ; e_txer = gnd
  ; led = reg spec (tree ~arity:4 ~f:(reduce ~f:( ^: )) (bits_lsb fold) |: g.ready)
  }
;;
