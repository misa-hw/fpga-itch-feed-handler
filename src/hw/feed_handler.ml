(* The complete receive pipeline, MAC byte stream in, top-of-book out:

     rx (1 byte/cycle) -> Frame_parser -> Mold_parser -> Itch_decoder
       -> Symbol_filter -> [FIFO] Order_book -> event

   Everything before the order book's FIFO runs at line rate with no
   back-pressure. [msg_last]/[msg_seq] expose the MoldUDP64 splitter's
   output, for debugging and on-board counters. Latency is measured by the
   testbench from the cycle the last byte of a message is on [rx] to the
   cycle its [event] is valid. *)

open! Core
open! Hardcaml
open Signal

module Config = struct
  type 'a t =
    { net : 'a Frame_parser.Config.t [@rtlmangle "_"]
    ; symbols : 'a array [@length Symbol_filter.num_slots] [@bits 64]
    ; symbol_enable : 'a [@bits Symbol_filter.num_slots]
    }
  [@@deriving hardcaml]
end

module Counters = struct
  type 'a t =
    { frame : 'a Frame_parser.Counters.t [@rtlmangle "_"]
    ; mold : 'a Mold_parser.Counters.t [@rtlmangle "_"]
    ; bad_length : 'a [@bits 32]
    ; decoded_orders : 'a [@bits 32]
    ; filtered_commands : 'a [@bits 32]
    ; book : 'a Order_book.Stats.t [@rtlmangle "_"]
    ; mapped : 'a [@bits Symbol_filter.num_slots]
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
    { event : 'a Order_book.Event.t [@rtlmangle "_"]
    ; counters : 'a Counters.t [@rtlmangle "_"]
    ; msg_last : 'a (* a message's last byte is in the decoder this cycle *)
    ; msg_seq : 'a [@bits 64]
    ; cmd : 'a (* a book command enters the book's FIFO (Latency_monitor) *)
    ; command : 'a Symbol_filter.Command.t [@rtlmangle "_"] (* that command *)
    ; book_quiet : 'a (* the book is idle with nothing queued *)
    ; msg : 'a Stream.Message.t [@rtlprefix "stream_"] (* the MoldUDP64 message stream *)
    ; slot_locates : 'a array [@length Symbol_filter.num_slots] [@bits 16]
    ; slot_mapped : 'a [@bits Symbol_filter.num_slots]
    ; request : 'a Mold_parser.Request.t [@rtlmangle "rq_"] (* gap recovery *)
    }
  [@@deriving hardcaml]
end

(* Cycles from a message's last byte on [rx] to its command on [cmd]: the
   fixed pipeline in front of the book. Latency_monitor adds it so its
   samples are the latency defined above (tests/hw/test_latency.ml). *)
let command_offset = 5

(* Cycles from a message's last byte on [rx] to the same byte on [msg]: the
   frame and MoldUDP64 parsers' registers (tests/hw/test_order_entry.ml). *)
let message_offset = 2

let create ?p ?fifo_capacity ?extra ?recovery scope (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let front =
    Rx_front.hierarchical ?extra ?recovery scope { clock = i.clock; clear = i.clear; cfg = i.cfg.net; rx = i.rx }
  in
  let dec = Itch_decoder.hierarchical scope { clock = i.clock; clear = i.clear; msg = front.msg } in
  let filter =
    Symbol_filter.hierarchical
      scope
      { clock = i.clock
      ; clear = i.clear
      ; symbols = i.cfg.symbols
      ; symbol_enable = i.cfg.symbol_enable
      ; decoded = dec.decoded
      }
  in
  let book = Order_book.hierarchical ?p ?fifo_capacity scope { clock = i.clock; clear = i.clear; cmd = filter.cmd } in
  let order_decoded =
    dec.decoded.valid
    &: (dec.decoded.kind <>: Itch_decoder.Kind.const Other)
    &: (dec.decoded.kind <>: Itch_decoder.Kind.const Directory)
  in
  let decoded_orders =
    reg_fb spec ~width:32 ~f:(fun n -> mux2 order_decoded (n +:. 1) n)
  in
  let filtered_commands =
    reg_fb spec ~width:32 ~f:(fun n -> mux2 filter.cmd.valid (n +:. 1) n)
  in
  { O.event = book.event
  ; counters =
      { Counters.frame = front.frame_counters
      ; mold = front.mold_counters
      ; bad_length = dec.bad_length
      ; decoded_orders
      ; filtered_commands
      ; book = book.stats
      ; mapped = filter.mapped
      }
  ; msg_last = front.msg.valid &: front.msg.last
  ; msg_seq = front.msg.seq
  ; cmd = filter.cmd.valid
  ; command = filter.cmd
  ; book_quiet = book.quiet
  ; msg = front.msg
  ; slot_locates = filter.locates
  ; slot_mapped = filter.mapped
  ; request = front.request
  }
;;
