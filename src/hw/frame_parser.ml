(* Ethernet II / IPv4 / UDP receive filter, one byte per cycle.

   Every header check is a comparison of the byte at a fixed offset with an
   expected value, so the parser is just a byte counter plus a table of
   (offset, mask, expected) checks built in OCaml:

     0-5    destination MAC      = cfg.mac
     12-13  ethertype            = 0x0800
     14     version/IHL          = 0x45 (frames with IP options are dropped)
     20-21  flags/fragment       : MF = 0, offset = 0 (DF allowed)
     23     protocol             = 17
     30-33  destination IP       = cfg.ip
     36-37  destination port     = cfg.port
     38-39  UDP length           : captured, must be >= 8

   All checks are complete by offset 39, before the payload starts at 42, so
   the payload is forwarded cut-through with no buffering: output byte n is
   input byte n + 42, one cycle later. The UDP length (not the frame length)
   delimits the payload, which strips Ethernet padding.

   Not checked, by design: IPv4 header and UDP checksums, and the Ethernet
   FCS, which only arrives after the payload has been forwarded. Frames with a
   MAC error are counted; see DESIGN.md for why a cut-through feed handler
   does not wait for the FCS. *)

open! Core
open! Hardcaml
open Signal

module Config = struct
  type 'a t =
    { mac : 'a [@bits 48]
    ; ip : 'a [@bits 32]
    ; port : 'a [@bits 16]
    }
  [@@deriving hardcaml]
end

module Counters = struct
  type 'a t =
    { frames : 'a [@bits 32] (* every frame seen *)
    ; accepted : 'a [@bits 32] (* passed the filter and complete *)
    ; filtered : 'a [@bits 32] (* not for us: address, protocol, ... *)
    ; errors : 'a [@bits 32] (* MAC error, or truncated *)
    }
  [@@deriving hardcaml]
end

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; cfg : 'a Config.t [@rtlmangle "_"]
    ; rx : 'a Stream.Mac_rx.t [@rtlmangle "_"]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { payload : 'a Stream.Payload.t [@rtlmangle "_"]
    ; counters : 'a Counters.t [@rtlmangle "_"]
    }
  [@@deriving hardcaml]
end

let payload_offset = 42
let byte_of s k = select s ~high:(Signal.width s - 1 - (8 * k)) ~low:(Signal.width s - 8 - (8 * k))

let counter spec ~incr = reg_fb spec ~width:32 ~f:(fun c -> mux2 incr (c +:. 1) c)

let create _scope (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let rx = i.rx in
  (* offset of the current byte in its frame (saturating) *)
  let idx_w = 11 in
  let next_idx = wire idx_w in
  let idx_reg = reg spec ~enable:rx.valid next_idx in
  let idx = mux2 rx.first (zero idx_w) idx_reg in
  next_idx <-- mux2 (idx ==:. (1 lsl idx_w) - 1) idx (idx +:. 1);
  let at k = idx ==:. k in
  (* (offset, mask, expected) *)
  let checks =
    List.init 6 ~f:(fun k -> k, 0xff, byte_of i.cfg.mac k)
    @ [ 12, 0xff, of_unsigned_int ~width:8 0x08
      ; 13, 0xff, of_unsigned_int ~width:8 0x00
      ; 14, 0xff, of_unsigned_int ~width:8 0x45
      ; 20, 0xbf, of_unsigned_int ~width:8 0x00 (* reserved, MF, offset[12:8] *)
      ; 21, 0xff, of_unsigned_int ~width:8 0x00
      ; 23, 0xff, of_unsigned_int ~width:8 17
      ]
    @ List.init 4 ~f:(fun k -> 30 + k, 0xff, byte_of i.cfg.ip k)
    @ List.init 2 ~f:(fun k -> 36 + k, 0xff, byte_of i.cfg.port k)
  in
  let len_hi = reg spec ~enable:(rx.valid &: at 38) rx.data in
  let udp_len = len_hi @: rx.data in
  let mismatch =
    List.map checks ~f:(fun (k, mask, expected) ->
      at k &: (rx.data &: of_unsigned_int ~width:8 mask <>: expected))
    |> List.reduce_exn ~f:( |: )
    |: (at 39 &: (udp_len <:. 8))
  in
  (* [ok]: every check so far passed (including this byte's) *)
  let ok_reg = wire 1 in
  let ok = mux2 rx.first vdd ok_reg &: ~:mismatch in
  ok_reg <-- reg spec ~enable:rx.valid ok;
  (* payload bytes still expected *)
  let remaining_reg = wire 16 in
  let in_payload = ok &: (idx >=:. payload_offset) &: (remaining_reg <>:. 0) in
  let remaining_next =
    mux2 (at 39) (udp_len -:. 8) (mux2 in_payload (remaining_reg -:. 1) remaining_reg)
  in
  remaining_reg <-- reg spec ~enable:rx.valid (mux2 rx.first (zero 16) remaining_next);
  let payload_last = in_payload &: (remaining_reg ==:. 1) in
  (* the frame ended while payload bytes were still owed *)
  let end_of_frame = rx.valid &: rx.last in
  let payload_started = idx >=:. payload_offset in
  let owed_after = mux2 in_payload (remaining_reg -:. 1) remaining_reg in
  let truncated = end_of_frame &: ok &: ~:(payload_started &: (owed_after ==:. 0)) in
  let aborted = end_of_frame &: ok &: payload_started &: (owed_after <>:. 0) in
  let payload =
    { Stream.Payload.valid = rx.valid &: in_payload
    ; data = rx.data
    ; first = at payload_offset
    ; last = payload_last
    ; abort = aborted
    }
    |> Stream.Payload.map ~f:(reg spec)
  in
  let counters =
    { Counters.frames = counter spec ~incr:end_of_frame
    ; accepted = counter spec ~incr:(end_of_frame &: ok &: ~:truncated &: ~:(rx.err))
    ; filtered = counter spec ~incr:(end_of_frame &: ~:ok)
    ; errors = counter spec ~incr:(end_of_frame &: ok &: (truncated |: rx.err))
    }
  in
  { O.payload; counters }
;;

let hierarchical scope =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical ~scope ~name:"frame_parser" create
;;
