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
    }
  [@@deriving hardcaml]
end

let create ?p ?fifo_capacity scope (i : _ I.t) : _ O.t =
  let front = Rx_front.hierarchical scope { clock = i.clock; clear = i.clear; cfg = i.cfg.net; rx = i.rx } in
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
  { O.event = book.event
  ; counters =
      { Counters.frame = front.frame_counters
      ; mold = front.mold_counters
      ; bad_length = dec.bad_length
      ; book = book.stats
      ; mapped = filter.mapped
      }
  ; msg_last = front.msg.valid &: front.msg.last
  ; msg_seq = front.msg.seq
  }
;;
