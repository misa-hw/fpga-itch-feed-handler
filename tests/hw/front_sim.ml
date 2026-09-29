(* Cyclesim testbench for Rx_front. *)

open! Core
open! Hardcaml
open Feed_hw
module Sim = Cyclesim.With_interface (Rx_front.I) (Rx_front.O)

type t =
  { sim : Sim.t
  ; i : Bits.t ref Rx_front.I.t
  ; o : Bits.t ref Rx_front.O.t
  ; mutable cur : Buffer.t
  ; mutable on_message : seq:int -> string -> unit
  }

let create ?(waves = false) ~(cfg : Front_ref.cfg) () =
  let scope = Scope.create ~flatten_design:true () in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all (Rx_front.create scope) in
  let waves, sim =
    if waves
    then (
      let w, s = Cyclesim.Waveform.create sim in
      Some w, s)
    else None, sim
  in
  let i = Cyclesim.inputs sim and o = Cyclesim.outputs sim in
  i.cfg.mac := Bits.of_int_trunc ~width:48 (Net.Packet.Mac.to_int cfg.mac);
  i.cfg.ip := Bits.of_int_trunc ~width:32 cfg.ip;
  i.cfg.port := Bits.of_int_trunc ~width:16 cfg.port;
  i.clear := Bits.vdd;
  Cyclesim.cycle sim;
  i.clear := Bits.gnd;
  waves, { sim; i; o; cur = Buffer.create 64; on_message = (fun ~seq:_ _ -> ()) }
;;

let cycle t =
  Cyclesim.cycle t.sim;
  let m = t.o.msg in
  if Bits.to_bool !(m.valid)
  then (
    if Bits.to_bool !(m.first) then Buffer.clear t.cur;
    Buffer.add_char t.cur (Char.of_int_exn (Bits.to_int_trunc !(m.data)));
    if Bits.to_bool !(m.last)
    then t.on_message ~seq:(Bits.to_int_trunc !(m.seq)) (Buffer.contents t.cur))
;;

let idle t n =
  t.i.rx.valid := Bits.gnd;
  for _ = 1 to n do
    cycle t
  done
;;

(* Send one frame. [stall] decides, per byte, how many idle cycles precede it
   (valid low inside a frame, as with a 10/100 MAC). *)
let send ?(err = false) ?(stall = fun () -> 0) t frame =
  let n = String.length frame in
  String.iteri frame ~f:(fun k c ->
    idle t (stall ());
    t.i.rx.valid := Bits.vdd;
    t.i.rx.data := Bits.of_int_trunc ~width:8 (Char.to_int c);
    t.i.rx.first := Bits.of_bool (k = 0);
    t.i.rx.last := Bits.of_bool (k = n - 1);
    t.i.rx.err := Bits.of_bool (err && k = n - 1);
    cycle t);
  t.i.rx.valid := Bits.gnd;
  t.i.rx.first := Bits.gnd;
  t.i.rx.last := Bits.gnd;
  t.i.rx.err := Bits.gnd
;;

let counters t =
  let g r = Bits.to_int_trunc !r in
  let f = t.o.frame_counters and m = t.o.mold_counters in
  sprintf
    "frames=%d accepted=%d filtered=%d errors=%d | packets=%d messages=%d dups=%d gaps=%d malformed=%d"
    (g f.frames)
    (g f.accepted)
    (g f.filtered)
    (g f.errors)
    (g m.packets)
    (g m.messages)
    (g m.duplicates)
    (g m.gaps)
    (g m.malformed)
;;

let ref_counters (r : Front_ref.t) =
  sprintf
    "frames=%d accepted=%d filtered=%d errors=%d | packets=%d messages=%d dups=%d gaps=%d malformed=%d"
    r.frames
    r.accepted
    r.filtered
    r.errors
    r.packets
    r.messages
    r.duplicates
    r.gaps
    r.malformed
;;
