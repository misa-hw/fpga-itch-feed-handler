(* MoldUDP64 downstream packet -> stream of ITCH messages, one byte per cycle.

     0-9    session           (ignored)
     10-17  sequence number   of the first message in the packet
     18-19  message count     0 = heartbeat, 0xFFFF = end of session
     20..   blocks            [u16 length][message] ...

   Each output message carries its own sequence number (packet sequence +
   index in the packet). Sequence tracking:
   - a message older than the next expected one is a duplicate (e.g. a
     retransmission, or the second copy of an A/B feed) and is dropped;
   - a message newer than expected means messages were lost: it is passed on
     and the gap is counted. Recovery (re-request) is not implemented.
   The first message after reset is accepted whatever its number. *)

open! Core
open! Hardcaml
open Signal

module Counters = struct
  type 'a t =
    { packets : 'a [@bits 32]
    ; messages : 'a [@bits 32] (* forwarded *)
    ; duplicates : 'a [@bits 32] (* dropped *)
    ; gaps : 'a [@bits 32] (* times a message arrived after missing ones *)
    ; malformed : 'a [@bits 32] (* payload ended mid-header or mid-message *)
    }
  [@@deriving hardcaml]
end

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; payload : 'a Stream.Payload.t [@rtlmangle "_"]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { msg : 'a Stream.Message.t [@rtlmangle "_"]
    ; counters : 'a Counters.t [@rtlmangle "_"]
    }
  [@@deriving hardcaml]
end

(* phases *)
let header = 0
let len_hi = 1
let len_lo = 2
let body = 3
let idle = 4

let create _scope (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let p = i.payload in
  let open Always in
  let phase = Variable.reg spec ~width:3 in
  let hidx = Variable.reg spec ~width:5 in
  let pkt_seq = Variable.reg spec ~width:64 in
  let count = Variable.reg spec ~width:16 in
  let left_in_pkt = Variable.reg spec ~width:16 in
  let len_high = Variable.reg spec ~width:8 in
  let remaining = Variable.reg spec ~width:16 in
  let msg_seq = Variable.reg spec ~width:64 in
  let expected = Variable.reg spec ~width:64 in
  let synced = Variable.reg spec ~width:1 in
  let emitting = Variable.reg spec ~width:1 in
  let body_first = Variable.reg spec ~width:1 in
  let cnt_packets = Variable.reg spec ~width:32 in
  let cnt_messages = Variable.reg spec ~width:32 in
  let cnt_dups = Variable.reg spec ~width:32 in
  let cnt_gaps = Variable.reg spec ~width:32 in
  let cnt_malformed = Variable.reg spec ~width:32 in
  let incr (v : Variable.t) = v <-- v.value +:. 1 in
  (* the phase and header index this byte belongs to *)
  let cur_phase = mux2 p.first (of_unsigned_int ~width:3 header) phase.value in
  let cur_hidx = mux2 p.first (zero 5) hidx.value in
  let in_body = p.valid &: (cur_phase ==:. body) in
  (* whether the message whose first byte is now arriving is forwarded *)
  let accept_new = ~:(synced.value) |: (msg_seq.value >=: expected.value) in
  let forward = mux2 body_first.value accept_new emitting.value in
  let msg_last = in_body &: (remaining.value ==:. 1) in
  let count_now = select count.value ~high:7 ~low:0 @: p.data in
  compile
    [ when_
        p.valid
        [ switch
            cur_phase
            [ ( of_unsigned_int ~width:3 header
              , [ hidx <-- cur_hidx +:. 1
                ; when_
                    ((cur_hidx >=:. 10) &: (cur_hidx <=:. 17))
                    [ pkt_seq <-- (drop_top pkt_seq.value ~width:8 @: p.data) ]
                ; when_ (cur_hidx ==:. 18) [ count <-- uresize p.data ~width:16 ]
                ; when_
                    (cur_hidx ==:. 19)
                    [ count <-- count_now
                    ; incr cnt_packets
                    ; msg_seq <-- pkt_seq.value
                    ; left_in_pkt <-- count_now
                    ; if_
                        ((count_now ==:. 0) |: (count_now ==:. 0xffff))
                        [ phase <--. idle ]
                        [ phase <--. len_hi ]
                    ]
                ; when_ (cur_hidx <>:. 19) [ phase <--. header ]
                ] )
            ; of_unsigned_int ~width:3 len_hi, [ len_high <-- p.data; phase <--. len_lo ]
            ; ( of_unsigned_int ~width:3 len_lo
              , [ remaining <-- len_high.value @: p.data
                ; body_first <-- vdd
                ; if_
                    (len_high.value @: p.data ==:. 0)
                    (* an empty block still uses a sequence number *)
                    [ msg_seq <-- msg_seq.value +:. 1
                    ; left_in_pkt <-- left_in_pkt.value -:. 1
                    ; if_ (left_in_pkt.value ==:. 1) [ phase <--. idle ] [ phase <--. len_hi ]
                    ]
                    [ phase <--. body ]
                ] )
            ; ( of_unsigned_int ~width:3 body
              , [ remaining <-- remaining.value -:. 1
                ; body_first <-- gnd
                ; when_
                    body_first.value
                    [ emitting <-- accept_new
                    ; if_
                        accept_new
                        [ when_ (synced.value &: (msg_seq.value >: expected.value)) [ incr cnt_gaps ]
                        ]
                        [ incr cnt_dups ]
                    ]
                ; when_
                    (remaining.value ==:. 1)
                    [ msg_seq <-- msg_seq.value +:. 1
                    ; left_in_pkt <-- left_in_pkt.value -:. 1
                    ; when_
                        forward
                        [ expected <-- msg_seq.value +:. 1; synced <-- vdd; incr cnt_messages ]
                    ; if_ (left_in_pkt.value ==:. 1) [ phase <--. idle ] [ phase <--. len_hi ]
                    ]
                ] )
            ; of_unsigned_int ~width:3 idle, []
            ]
        ; (* payload ended before the packet was complete *)
          when_
            (p.last &: ~:(msg_last &: (left_in_pkt.value ==:. 1)) &: (cur_phase <>:. idle)
             &: ~:((cur_phase ==:. header) &: (cur_hidx ==:. 19)
                   &: ((count_now ==:. 0) |: (count_now ==:. 0xffff))))
            [ incr cnt_malformed; phase <--. idle ]
        ]
    ; when_ p.abort [ incr cnt_malformed; phase <--. idle ]
    ];
  let msg =
    { Stream.Message.valid = in_body &: forward
    ; data = p.data
    ; first = body_first.value
    ; last = msg_last
    ; seq = msg_seq.value
    }
    |> Stream.Message.map ~f:(reg spec)
  in
  { O.msg
  ; counters =
      { Counters.packets = cnt_packets.value
      ; messages = cnt_messages.value
      ; duplicates = cnt_dups.value
      ; gaps = cnt_gaps.value
      ; malformed = cnt_malformed.value
      }
  }
;;

let hierarchical scope =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical ~scope ~name:"mold_parser" create
;;
