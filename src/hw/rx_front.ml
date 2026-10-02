(* MAC byte stream -> ITCH messages: [Frame_parser] then [Mold_parser]. *)

open! Core
open! Hardcaml

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; cfg : 'a Frame_parser.Config.t [@rtlmangle "_"]
    ; rx : 'a Stream.Mac_rx.t [@rtlmangle "_"]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { msg : 'a Stream.Message.t [@rtlmangle "_"]
    ; frame_counters : 'a Frame_parser.Counters.t [@rtlmangle "_"]
    ; mold_counters : 'a Mold_parser.Counters.t [@rtlmangle "_"]
    ; request : 'a Mold_parser.Request.t [@rtlmangle "rq_"]
    }
  [@@deriving hardcaml]
end

let create ?extra ?recovery scope (i : _ I.t) : _ O.t =
  let frame =
    Frame_parser.hierarchical ?extra scope { clock = i.clock; clear = i.clear; cfg = i.cfg; rx = i.rx }
  in
  let mold =
    Mold_parser.hierarchical ?recovery scope { clock = i.clock; clear = i.clear; payload = frame.payload }
  in
  { O.msg = mold.msg
  ; frame_counters = frame.counters
  ; mold_counters = mold.counters
  ; request = mold.request
  }
;;

let hierarchical ?extra ?recovery scope =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical ~scope ~name:"rx_front" (create ?extra ?recovery)
;;
