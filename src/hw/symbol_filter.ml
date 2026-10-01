(* Maps decoded messages to book slots and drops everything else.

   The tracked symbols are an input (8-byte, space-padded ASCII each, plus an
   enable bit). Stock locate codes are assigned per day by Nasdaq and only
   announced in Stock Directory ('R') messages at the start of the day, so
   the filter learns them: when an 'R' message names a tracked symbol, that
   slot's locate register is loaded. Every order message then matches its
   locate against the [num_slots] registers in parallel (a tiny CAM: eight
   16-bit comparators), which replaces a 64K-entry locate table. *)

open! Core
open! Hardcaml
open Signal

let num_slots = 8
let slot_bits = 3

module Command = struct
  (* What the order book consumes. Directory and other messages never get here. *)
  type 'a t =
    { valid : 'a
    ; kind : 'a [@bits Itch_decoder.Kind.width]
    ; slot : 'a [@bits slot_bits]
    ; order_ref : 'a [@bits 64]
    ; new_ref : 'a [@bits 64]
    ; sell : 'a
    ; shares : 'a [@bits 32]
    ; price : 'a [@bits 32]
    ; seq : 'a [@bits 64]
    }
  [@@deriving hardcaml]
end

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; symbols : 'a array [@length num_slots] [@bits 64]
    ; symbol_enable : 'a [@bits num_slots]
    ; decoded : 'a Itch_decoder.Decoded.t [@rtlmangle "_"]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { cmd : 'a Command.t [@rtlmangle "_"]
    ; mapped : 'a [@bits num_slots] (* which slots have seen their directory message *)
    ; locates : 'a array [@length num_slots] [@bits 16] (* each slot's stock locate *)
    }
  [@@deriving hardcaml]
end

let create _scope (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let d = i.decoded in
  let is k = d.kind ==: Itch_decoder.Kind.const k in
  let directory = d.valid &: is Directory in
  (* NB: Hardcaml's [&:] and [==:] share OCaml's comparison precedence and
     associate to the left, hence the parentheses. *)
  let slots =
    Array.init num_slots ~f:(fun s ->
      let named =
        directory &: (i.symbols.(s) ==: d.stock) &: bit i.symbol_enable ~pos:s
      in
      let locate = reg spec ~enable:named d.locate in
      let mapped = reg_fb spec ~width:1 ~f:(fun v -> v |: named) in
      (mapped, locate), mapped &: (locate ==: d.locate))
  in
  let locates = Array.map slots ~f:(fun ((_, l), _) -> l) in
  let slots = Array.map slots ~f:(fun ((m, _), hit) -> m, hit) in
  let mapped = concat_lsb (Array.to_list (Array.map slots ~f:fst)) in
  let slots = Array.map slots ~f:snd in
  let hit = Array.to_list slots |> List.reduce_exn ~f:( |: ) in
  let slot = onehot_to_binary (concat_lsb (Array.to_list slots)) in
  let book_kind = ~:(is Other) &: ~:(is Directory) in
  let cmd =
    { Command.valid = d.valid &: book_kind &: hit
    ; kind = d.kind
    ; slot = uresize slot ~width:slot_bits
    ; order_ref = d.order_ref
    ; new_ref = d.new_ref
    ; sell = d.sell
    ; shares = d.shares
    ; price = d.price
    ; seq = d.seq
    }
    |> Command.map ~f:(reg spec)
  in
  { O.cmd; mapped; locates }
;;

let hierarchical scope =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical ~scope ~name:"symbol_filter" create
;;
