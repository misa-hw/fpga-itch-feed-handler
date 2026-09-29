(* Byte streams between pipeline stages: one byte per cycle when [valid].
   [first]/[last] mark the first and last byte of a frame, payload or message.
   There is no back-pressure anywhere before the order book: a MAC cannot be
   stalled, so every stage up to the book's input FIFO must accept one byte
   every cycle. *)

open! Core
open! Hardcaml

module Bytes_in = struct
  type 'a t =
    { valid : 'a
    ; data : 'a [@bits 8]
    ; first : 'a
    ; last : 'a
    }
  [@@deriving hardcaml]
end

(* What an RX MAC delivers: preamble/SFD and FCS already stripped. [err] is
   valid with [last] and flags a bad FCS or a PHY receive error. *)
module Mac_rx = struct
  type 'a t =
    { valid : 'a
    ; data : 'a [@bits 8]
    ; first : 'a
    ; last : 'a
    ; err : 'a
    }
  [@@deriving hardcaml]
end

(* A UDP payload. [abort] pulses if the frame ends before the payload does. *)
module Payload = struct
  type 'a t =
    { valid : 'a
    ; data : 'a [@bits 8]
    ; first : 'a
    ; last : 'a
    ; abort : 'a
    }
  [@@deriving hardcaml]
end

(* One ITCH message, with its MoldUDP64 sequence number (constant while the
   message is being transferred). *)
module Message = struct
  type 'a t =
    { valid : 'a
    ; data : 'a [@bits 8]
    ; first : 'a
    ; last : 'a
    ; seq : 'a [@bits 64]
    }
  [@@deriving hardcaml]
end
