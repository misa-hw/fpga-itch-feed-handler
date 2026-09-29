(* ITCH 5.0 message decoder, one byte per cycle.

   Each output field is a shift register that shifts in the current byte when
   the message type and byte offset say that byte belongs to the field. The
   (types, offset, length) table below is the ITCH 5.0 layout of the eight
   message types the book needs; the hardware is generated from it. Decoded
   fields are presented for one cycle, the cycle after the message's last
   byte (plus one input register stage). Messages whose length does not
   match their type are dropped and counted; other types are ignored. *)

open! Core
open! Hardcaml
open Signal

module Kind = struct
  type t =
    | Other
    | Add (* 'A' and 'F' *)
    | Executed (* 'E' *)
    | Executed_with_price (* 'C' *)
    | Cancel (* 'X' *)
    | Delete (* 'D' *)
    | Replace (* 'U' *)
    | Directory (* 'R' *)
  [@@deriving sexp_of, compare, equal, enumerate]

  let width = 3

  let to_int t =
    List.findi_exn all ~f:(fun _ x -> equal x t) |> fst
  ;;

  let of_int i = List.nth_exn all i
  let const t = of_unsigned_int ~width (to_int t)

  let of_char = function
    | 'A' | 'F' -> Add
    | 'E' -> Executed
    | 'C' -> Executed_with_price
    | 'X' -> Cancel
    | 'D' -> Delete
    | 'U' -> Replace
    | 'R' -> Directory
    | _ -> Other
  ;;
end

module Decoded = struct
  type 'a t =
    { valid : 'a
    ; kind : 'a [@bits Kind.width]
    ; locate : 'a [@bits 16]
    ; order_ref : 'a [@bits 64] (* original reference for Replace *)
    ; new_ref : 'a [@bits 64] (* Replace only *)
    ; sell : 'a (* Add only: 1 = sell, 0 = buy *)
    ; shares : 'a [@bits 32]
    ; price : 'a [@bits 32] (* Add, Replace; the print price for Executed_with_price *)
    ; stock : 'a [@bits 64] (* Add, Directory *)
    ; seq : 'a [@bits 64]
    }
  [@@deriving hardcaml]
end

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; msg : 'a Stream.Message.t [@rtlmangle "_"]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { decoded : 'a Decoded.t [@rtlmangle "_"]
    ; bad_length : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

(* field -> list of (message types, first byte offset, length in bytes) *)
let layout : (string * (string * int * int) list) list =
  [ "locate", [ "AFECXDUR", 1, 2 ]
  ; "order_ref", [ "AFECXDU", 11, 8 ]
  ; "new_ref", [ "U", 19, 8 ]
  ; "side", [ "AF", 19, 1 ]
  ; "shares", [ "AF", 20, 4; "ECX", 19, 4; "U", 27, 4 ]
  ; "price", [ "AF", 32, 4; "C", 32, 4; "U", 31, 4 ]
  ; "stock", [ "AF", 24, 8; "R", 11, 8 ]
  ]
;;

let lengths = List.map (String.to_list "AFECXDUR") ~f:(fun c -> c, Option.value_exn (Itch_model.Itch.length_of_type c))

let create _scope (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  (* stage 0: register the byte with its offset and its message's type *)
  let idx_reg = wire 6 in
  let idx0 = mux2 i.msg.first (zero 6) idx_reg in
  idx_reg <-- reg spec ~enable:i.msg.valid (mux2 (idx0 ==:. 63) idx0 (idx0 +:. 1));
  let typ_reg = reg spec ~enable:(i.msg.valid &: i.msg.first) i.msg.data in
  let typ0 = mux2 i.msg.first i.msg.data typ_reg in
  let m = Stream.Message.map i.msg ~f:(reg spec) in
  let idx = reg spec idx0 and typ = reg spec typ0 in
  let is c = typ ==:. Char.to_int c in
  let is_any s = String.to_list s |> List.map ~f:is |> List.reduce_exn ~f:( |: ) in
  let field name ~bytes =
    let spans = List.Assoc.find_exn layout name ~equal:String.equal in
    let take =
      List.map spans ~f:(fun (types, off, len) ->
        is_any types &: (idx >=:. off) &: (idx <:. off + len))
      |> List.reduce_exn ~f:( |: )
    in
    reg_fb spec ~width:(8 * bytes) ~f:(fun v ->
      let shifted = if bytes = 1 then m.data else drop_top v ~width:8 @: m.data in
      mux2 (m.valid &: take) shifted v)
    -- ("field_" ^ name)
  in
  let kind =
    List.fold lengths ~init:(Kind.const Other) ~f:(fun acc (c, _) ->
      mux2 (is c) (Kind.const (Kind.of_char c)) acc)
  in
  let expected_len =
    List.fold lengths ~init:(zero 6) ~f:(fun acc (c, l) ->
      mux2 (is c) (of_unsigned_int ~width:6 l) acc)
  in
  let known = expected_len <>:. 0 in
  let length_ok = idx +:. 1 ==: expected_len in
  let at_end = m.valid &: m.last in
  let decoded =
    { Decoded.valid = reg spec (at_end &: known &: length_ok)
    ; kind = reg spec ~enable:at_end kind
    ; locate = field "locate" ~bytes:2
    ; order_ref = field "order_ref" ~bytes:8
    ; new_ref = field "new_ref" ~bytes:8
    ; sell = field "side" ~bytes:1 ==:. Char.to_int 'S'
    ; shares = field "shares" ~bytes:4
    ; price = field "price" ~bytes:4
    ; stock = field "stock" ~bytes:8
    ; seq = reg spec ~enable:at_end m.seq
    }
  in
  let bad_length =
    reg_fb spec ~width:32 ~f:(fun c -> mux2 (at_end &: known &: ~:length_ok) (c +:. 1) c)
  in
  { O.decoded; bad_length }
;;

let hierarchical scope =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical ~scope ~name:"itch_decoder" create
;;
