(* Cyclesim testbench for Order_book on its own: ITCH messages are turned
   into book commands by a software copy of Symbol_filter, pushed into the
   book's FIFO, and the book's events are collected. *)

open! Core
open! Hardcaml
open Feed_hw
open Itch_model
module Sim = Cyclesim.With_interface (Order_book.I) (Order_book.O)
module Kind = Itch_decoder.Kind

type event =
  { seq : int
  ; changed : bool
  ; tob : Book.Tob.t
  }

type t =
  { sim : Sim.t
  ; i : Bits.t ref Order_book.I.t
  ; o : Bits.t ref Order_book.O.t
  ; slot_locate : int option array
  ; symbols : string array
  ; events : event Queue.t
  ; mutable cycle : int
  ; mutable next_seq : int
  }

let create ?waves ?(p = Hw_book.default_params) ?fifo_capacity symbols =
  let scope = Scope.create ~flatten_design:true () in
  let sim = Sim.create (Order_book.create ~p ?fifo_capacity scope) in
  let initial_inputs = Cyclesim.inputs sim in
  initial_inputs.clear := Bits.vdd;
  Cyclesim.cycle sim;
  initial_inputs.clear := Bits.gnd;
  (* Put the waveform window around actual book activity. The book zeroes
     both BRAM tables after reset, which otherwise fills the displayed
     window with thousands of uninteresting init cycles. *)
  (match waves with
   | Some true ->
     for _ = 1 to (1 lsl Int.max p.order_bucket_bits p.level_bucket_bits) + 4 do
       Cyclesim.cycle sim
     done
   | _ -> ());
  let waves, sim =
    match waves with
    | Some true ->
      let w, s = Cyclesim.Waveform.create sim in
      Some w, s
    | _ -> None, sim
  in
  let i = Cyclesim.inputs sim and o = Cyclesim.outputs sim in
  ( waves
  , { sim
    ; i
    ; o
    ; slot_locate = Array.create ~len:8 None
    ; symbols = Array.of_list_map symbols ~f:Itch.pad_stock
    ; events = Queue.create ()
    ; cycle = 0
    ; next_seq = 1
    } )
;;

let cycle t =
  Cyclesim.cycle t.sim;
  t.cycle <- t.cycle + 1;
  let e = t.o.event in
  if Bits.to_bool !(e.valid)
  then (
    let g r = Bits.to_int_trunc !r in
    Queue.enqueue
      t.events
      { seq = g e.seq
      ; changed = Bits.to_bool !(e.changed)
      ; tob =
          { slot = g e.slot
          ; bid_price = g e.bid_price
          ; bid_shares = g e.bid_shares
          ; ask_price = g e.ask_price
          ; ask_shares = g e.ask_shares
          }
      })
;;

(* The command the hardware Symbol_filter would produce for [m], if any. *)
let command t (m : Itch.t) =
  match m.body with
  | Stock_directory { stock; _ } ->
    Array.iteri t.symbols ~f:(fun s sym ->
      if String.equal sym stock then t.slot_locate.(s) <- Some m.header.locate);
    None
  | Other _ -> None
  | body ->
    Array.findi t.slot_locate ~f:(fun _ l -> Option.equal Int.equal l (Some m.header.locate))
    |> Option.map ~f:(fun (slot, _) ->
      let kind, order_ref, new_ref, sell, shares, price =
        match body with
        | Add_order { order_ref; side; shares; price; _ } ->
          Kind.Add, order_ref, 0, Itch.equal_side side Sell, shares, price
        | Order_executed { order_ref; shares; _ } -> Executed, order_ref, 0, false, shares, 0
        | Order_executed_with_price { order_ref; shares; price; _ } ->
          Executed_with_price, order_ref, 0, false, shares, price
        | Order_cancel { order_ref; shares } -> Cancel, order_ref, 0, false, shares, 0
        | Order_delete { order_ref } -> Delete, order_ref, 0, false, 0, 0
        | Order_replace { orig_ref; new_ref; shares; price } ->
          Replace, orig_ref, new_ref, false, shares, price
        | Stock_directory _ | Other _ -> assert false
      in
      kind, slot, order_ref, new_ref, sell, shares, price)
;;

let drive t (kind, slot, order_ref, new_ref, sell, shares, price) ~seq =
  let c = t.i.cmd in
  let set r ~width v = r := Bits.of_int_trunc ~width v in
  c.valid := Bits.vdd;
  set c.kind ~width:3 (Kind.to_int kind);
  set c.slot ~width:3 slot;
  set c.order_ref ~width:64 order_ref;
  set c.new_ref ~width:64 new_ref;
  c.sell := Bits.of_bool sell;
  set c.shares ~width:32 shares;
  set c.price ~width:32 price;
  set c.seq ~width:64 seq;
  cycle t;
  c.valid := Bits.gnd
;;

(* Push one message; [gap] idle cycles afterwards. Returns its seq if it
   became a command. *)
let send ?(gap = 0) t m =
  let seq = t.next_seq in
  t.next_seq <- t.next_seq + 1;
  let r =
    match command t m with
    | None -> None
    | Some c ->
      drive t c ~seq;
      Some seq
  in
  for _ = 1 to gap do
    cycle t
  done;
  r
;;

(* Run until [n] events have been collected (or [timeout] cycles pass). *)
let wait_events ?(timeout = 1_000_000) t n =
  let start = t.cycle in
  while Queue.length t.events < n && t.cycle - start < timeout do
    cycle t
  done
;;

let stats t =
  let s = t.o.stats in
  let g r = Bits.to_int_trunc !r in
  ( g s.processed
  , g s.kicks
  , g s.max_kicks
  , g s.refills
  , g s.refill_levels
  , g s.order_overflows
  , g s.level_overflows
  , g s.orders
  , g s.levels
  , g s.fifo_overflows
  , g s.fifo_max_used )
;;
