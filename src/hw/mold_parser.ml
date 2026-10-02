(* MoldUDP64 downstream packet -> stream of ITCH messages, one byte per cycle.

     0-9    session           (kept for re-requests)
     10-17  sequence number   of the first message in the packet
     18-19  message count     0 = heartbeat, 0xFFFF = end of session
     20..   blocks            [u16 length][message] ...

   Each output message carries its own sequence number (packet sequence +
   index in the packet). Without recovery the first message after reset is
   accepted whatever its number; with it, the session starts at message 1.

   Without [recovery]: a message older than the next expected one is a
   duplicate (a retransmission, or the second copy of an A/B feed) and is
   dropped; a newer one means messages were lost: it is passed on and the
   gap is counted.

   With [recovery], messages reach the output strictly in sequence, with
   nothing lost that can be recovered:
   - [expected] (E) is the next message to pass on, [live] (L) the next one
     the feed has not shown yet; messages between them are either parked
     here or missing.
   - A message numbered E goes straight out (no added cycle), unless it is
     parked already. One at or after L is parked: kept in a message buffer
     (bodies in a byte FIFO, numbers and lengths in a second FIFO). Anything
     else is a duplicate, or a missing message arriving out of order, and is
     dropped (it will be asked for again).
   - The replay engine passes the buffer's oldest message on as soon as it
     is numbered E, so a hole closes the moment its messages arrive, from
     the B line or a retransmission; several holes are filled one by one.
   - A heartbeat or end-of-session packet announces the next number, so
     losses at the end of a burst are seen too.
   - While E is missing, a timer runs: after [window] cycles (time for the B
     line to catch up) it asks for the missing messages ([request]: the
     session, E, and a count up to the buffer's oldest, or L), and again
     every [retry] cycles without progress. After [max_retries] requests the
     missing messages are given up: they are counted as lost, [stale] is
     set, and the buffer is passed on.
   - A full buffer drops the incoming message: one more hole, which the
     server fills like any other. But once a hole has been given up
     unanswered, the server is taken to be silent, and from then on a full
     buffer gives the open hole up at once, until a request is answered:
     waiting would only fill the buffer with holes (seen on the board with
     no server: 8 ms of retries per hole, the buffer full after 1,024
     messages, and almost every message after the first loss lost). *)

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
    ; replayed : 'a [@bits 32] (* recovery: forwarded from the buffer *)
    ; requests : 'a [@bits 32] (* recovery: re-requests sent *)
    ; lost : 'a [@bits 32] (* recovery: messages given up *)
    ; overflows : 'a [@bits 32] (* recovery: messages the full buffer dropped *)
    ; buffer_peak : 'a [@bits 16] (* recovery: most messages parked at once *)
    ; stale : 'a (* recovery: messages have been lost since reset *)
    }
  [@@deriving hardcaml]
end

module Request = struct
  (* one cycle: ask the retransmission server for [count] messages from [seq] *)
  type 'a t =
    { valid : 'a
    ; session : 'a [@bits 80]
    ; seq : 'a [@bits 64]
    ; count : 'a [@bits 16]
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
    ; request : 'a Request.t [@rtlmangle "rq_"]
    }
  [@@deriving hardcaml]
end

module Recovery = struct
  type t =
    { window : int (* cycles a hole may stay open before the first request *)
    ; retry : int (* cycles without progress before asking again *)
    ; max_retries : int (* requests before the missing messages are given up *)
    ; max_request : int (* messages asked for at once *)
    ; buffer_bytes : int (* message bodies parked, a power of 2 *)
    ; buffer_messages : int (* messages parked *)
    }

  (* 16 us to wait for the B line, 1 ms per retry: at 125 MHz. 32 KB of
     bodies: with 16 KB, the buffer ran out of bytes (peak 586 messages) on
     the board at the host's top speed, 126,000 frames/s on two lines.
     32 requests (32 ms) before giving up: with 8, the host's server
     stalling for up to 13.5 ms under that load made holes time out while
     it was still answering. *)
  let default =
    { window = 2_000
    ; retry = 125_000
    ; max_retries = 32
    ; max_request = 1024
    ; buffer_bytes = 32_768
    ; buffer_messages = 2048
    }
  ;;
end

(* phases *)
let header = 0
let len_hi = 1
let len_lo = 2
let body = 3
let idle = 4

(* the longest message the buffer takes (ITCH's longest is 50 bytes) *)
let max_parked_len = 255

let create ?recovery scope (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let p = i.payload in
  let open Always in
  let phase = Variable.reg spec ~width:3 in
  let hidx = Variable.reg spec ~width:5 in
  let session = Variable.reg spec ~width:80 (* shifts in during each header *) in
  let last_session = Variable.reg spec ~width:80 (* of the last complete header *) in
  let pkt_seq = Variable.reg spec ~width:64 in
  let count = Variable.reg spec ~width:16 in
  let left_in_pkt = Variable.reg spec ~width:16 in
  let len_high = Variable.reg spec ~width:8 in
  let remaining = Variable.reg spec ~width:16 in
  let msg_seq = Variable.reg spec ~width:64 in
  (* with recovery, a session starts at message 1: anything before the first
     message that arrives is missing and recovered like any other gap *)
  let from_one ~width v = Option.map recovery ~f:(fun _ -> of_unsigned_int ~width v) in
  let expected = Variable.reg ?clear_to:(from_one ~width:64 1) spec ~width:64 in
  let synced = Variable.reg ?clear_to:(from_one ~width:1 1) spec ~width:1 in
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
  let msg_last = in_body &: (remaining.value ==:. 1) in
  let count_now = select count.value ~high:7 ~low:0 @: p.data in
  let header_end = p.valid &: (cur_phase ==:. header) &: (cur_hidx ==:. 19) in
  let empty_packet = (count_now ==:. 0) |: (count_now ==:. 0xffff) in
  let s = msg_seq.value in
  (* ---- the decision for the message whose first byte is arriving, and
     what its last byte does ---- *)
  let decide, on_direct_end, on_packet, extra_logic, replay_out, extra_counters, request =
    match recovery with
    | None ->
      let accept_new = ~:(synced.value) |: (s >=: expected.value) in
      ( (* forward, park, parked *) (accept_new, gnd, gnd)
      , [ expected <-- s +:. 1; synced <-- vdd ]
      , []
      , []
      , None
      , None
      , None )
    | Some (r : Recovery.t) ->
      let live = Variable.reg ~clear_to:(of_unsigned_int ~width:64 1) spec ~width:64 in
      (* buffer: bodies in a byte RAM, (number, length) in a FIFO *)
      let bb = Int.ceil_log2 r.buffer_bytes in
      let wp = Variable.reg spec ~width:(bb + 1) (* next body byte to write *) in
      let cp = Variable.reg spec ~width:(bb + 1) (* end of the last complete body *) in
      let rp = Variable.reg spec ~width:(bb + 1) (* next body byte to replay *) in
      let plen = Variable.reg spec ~width:16 (* bytes of the message being parked, so far *) in
      let parking = Variable.reg spec ~width:1 in
      let info_wr = Variable.wire ~default:gnd () in
      let info_rd = Variable.wire ~default:gnd () in
      let info =
        Fifo.create
          ~showahead:true
          ~scope
          ()
          ~capacity:r.buffer_messages
          ~clock:i.clock
          ~clear:i.clear
          ~wr:info_wr.value
          ~d:(s @: mux2 body_first.value (of_unsigned_int ~width:16 1) (plen.value +:. 1))
          ~rd:info_rd.value
      in
      let head_valid = ~:(info.empty) in
      let head_seq = select info.q ~high:79 ~low:16 in
      let head_len = sel_bottom info.q ~width:16 in
      let body_we = Variable.wire ~default:gnd () in
      let body_wa = Variable.wire ~default:(zero bb) () in
      let rd_en = Variable.wire ~default:gnd () in
      let body_q =
        ram_rbw
          ~write_port:
            { write_clock = i.clock
            ; write_address = body_wa.value
            ; write_enable = body_we.value
            ; write_data = p.data
            }
          ~read_port:
            { read_clock = i.clock; read_address = sel_bottom rp.value ~width:bb; read_enable = rd_en.value }
          r.buffer_bytes
      in
      (* replay engine: [to_issue] reads still to start, [to_emit] bytes
         still to pass on; the RAM answers a cycle after a read *)
      let replaying = Variable.reg spec ~width:1 in
      let to_issue = Variable.reg spec ~width:16 in
      let to_emit = Variable.reg spec ~width:16 in
      let r_seq = Variable.reg spec ~width:64 in
      let r_first = Variable.reg spec ~width:1 in
      let issued = Variable.reg spec ~width:1 (* a read is in flight *) in
      let head_is_e = head_valid &: (head_seq ==: expected.value) in
      let free_bytes = of_unsigned_int ~width:(bb + 1) r.buffer_bytes -: (wp.value -: rp.value) in
      (* The decision on a message's first byte uses comparisons registered
         a cycle earlier: as one 64-bit magnitude compare, the room check and
         the write enables in a single cycle, it missed 125 MHz. Same result:
         the message's number and [live] change only when the previous
         message ends or at a packet header, at least two bytes (the block
         length) before the first byte. [room] can only grow in that cycle
         (the replay frees bytes; nothing else parks), so the registered
         value errs on the safe side. *)
      let room =
        reg spec ((free_bytes >=:. max_parked_len + 1) &: ~:(info.full))
      in
      let s_ge_live = reg spec (s >=: live.value) in
      let s_gt_live = reg spec (s >: live.value) in
      (* the live message being passed straight on, if any *)
      let live_direct = in_body &: emitting.value &: ~:(body_first.value) in
      let start_replay =
        head_is_e &: ~:(replaying.value) &: ~:live_direct &: ~:(in_body &: body_first.value)
      in
      let direct =
        ~:(synced.value)
        |: ((s ==: expected.value) &: ~:head_is_e &: ~:(replaying.value &: (r_seq.value ==: s)))
      in
      let park = synced.value &: s_ge_live &: ~:direct in
      let direct_now_w = direct in
      (* gap timer *)
      let live_out = in_body &: mux2 body_first.value direct_now_w emitting.value in
      let waiting =
        synced.value
        &: (expected.value <: live.value)
        &: ~:head_is_e
        &: ~:(replaying.value)
        &: ~:live_out
      in
      let missing_end = mux2 head_valid head_seq live.value in
      let timer = Variable.reg spec ~width:(num_bits_to_represent (Int.max r.window r.retry)) in
      let retries = Variable.reg spec ~width:(num_bits_to_represent r.max_retries) in
      let e_seen = Variable.reg spec ~width:64 in
      let progress = expected.value <>: e_seen.value in
      let due =
        mux2 (retries.value ==:. 0) (timer.value ==:. r.window - 1) (timer.value ==:. r.retry - 1)
      in
      let full = Variable.reg spec ~width:1 (* the buffer turned a message away *) in
      let silent = Variable.reg spec ~width:1 (* a hole was given up unanswered *) in
      let timed_out = waiting &: ~:progress &: due &: (retries.value ==:. r.max_retries) in
      let give_up = timed_out |: (waiting &: full.value &: silent.value) in
      let ask = waiting &: ~:progress &: due &: ~:give_up in
      let wanted = missing_end -: expected.value in
      let rq_count =
        mux2 (wanted >:. r.max_request) (of_unsigned_int ~width:16 r.max_request) (sel_bottom wanted ~width:16)
      in
      let cnt_replayed = Variable.reg spec ~width:32 in
      let cnt_requests = Variable.reg spec ~width:32 in
      let cnt_lost = Variable.reg spec ~width:32 in
      let cnt_overflows = Variable.reg spec ~width:32 in
      let peak = Variable.reg spec ~width:16 in
      let stale = Variable.reg spec ~width:1 in
      let held = Variable.reg spec ~width:16 (* messages parked now *) in
      let replay_ending = replaying.value &: issued.value &: (to_emit.value ==:. 1) in

      let decide_now = in_body &: body_first.value in
      let parked_ok = park &: room in
      ( (direct, park, parked_ok)
      , [ expected <-- s +:. 1
        ; when_ s_ge_live [ live <-- s +:. 1 ]
        ; synced <-- vdd
        ]
      , [ (* a heartbeat or end of session announces the next number *)
          when_
            (header_end &: empty_packet &: synced.value &: (pkt_seq.value >: live.value))
            [ live <-- pkt_seq.value; incr cnt_gaps ]
        ]
      , [ (* a full buffer while a hole is open and the server is silent:
             give the hole up (once) *)
          full <-- (full.value &: waiting &: ~:give_up)
        ; when_ timed_out [ silent <-- vdd ]
        ; (* answered: E moved after a request, and not by giving up *)
          when_
            (progress &: (retries.value <>:. 0) &: ~:(reg spec give_up))
            [ silent <-- gnd ]
        ; (* parking: write the body; on its last byte, commit it *)
          when_
            decide_now
            [ parking <-- parked_ok
            ; when_ (park &: ~:room) [ incr cnt_overflows; full <-- vdd ]
            ; when_ parked_ok [ when_ s_gt_live [ incr cnt_gaps ] ]
            ]
        ; when_
            (in_body &: mux2 body_first.value parked_ok parking.value)
            [ body_we <-- vdd
            ; body_wa <-- sel_bottom (mux2 body_first.value cp.value wp.value) ~width:bb
            ; wp <-- mux2 body_first.value cp.value wp.value +:. 1
            ; plen <-- mux2 body_first.value (of_unsigned_int ~width:16 1) (plen.value +:. 1)
            ; when_
                msg_last
                [ info_wr <-- vdd
                ; cp <-- mux2 body_first.value cp.value wp.value +:. 1
                ; live <-- s +:. 1
                ]
            ]
        ; (* replay *)
          when_
            start_replay
            [ replaying <-- vdd
            ; r_seq <-- head_seq
            ; r_first <-- vdd
            ; to_issue <-- head_len
            ; to_emit <-- head_len
            ; issued <-- gnd
            ]
        ; when_
            (replaying.value &: (to_issue.value <>:. 0))
            [ rd_en <-- vdd; rp <-- rp.value +:. 1; to_issue <-- to_issue.value -:. 1 ]
        ; when_
            replaying.value
            [ issued <-- (to_issue.value <>:. 0)
            ; when_
                issued.value
                [ to_emit <-- to_emit.value -:. 1
                ; r_first <-- gnd
                ; when_
                    (to_emit.value ==:. 1)
                    [ replaying <-- gnd
                    ; info_rd <-- vdd
                    ; expected <-- r_seq.value +:. 1
                    ; incr cnt_replayed
                    ; incr cnt_messages
                    ]
                ]
            ]
        ; (* messages parked: one in, one out, or both in the same cycle *)
          (let held_in = info_wr.value and held_out = info_rd.value in
           let next = held.value +: uresize held_in ~width:16 -: uresize held_out ~width:16 in
           (* the peak follows [held] a cycle later: comparing [next] put
              the parking decision, an adder and a compare in one cycle *)
           proc [ held <-- next; when_ (held.value >: peak.value) [ peak <-- held.value ] ])
        ; (* the gap timer *)
          e_seen <-- expected.value
        ; if_
            (~:waiting |: progress)
            [ timer <--. 0; retries <--. 0 ]
            [ if_ due [ timer <--. 0 ] [ timer <-- timer.value +:. 1 ] ]
        ; when_ ask [ retries <-- retries.value +:. 1; incr cnt_requests ]
        ; when_
            give_up
            [ (* skip the hole: what is parked goes on from here *)
              expected <-- missing_end
            ; cnt_lost <-- cnt_lost.value +: sel_bottom wanted ~width:32
            ; stale <-- vdd
            ]
        ]
      , Some
          { Stream.Message.valid = replaying.value &: issued.value
          ; data = body_q
          ; first = r_first.value
          ; last = replay_ending
          ; seq = r_seq.value
          }
      , Some
          ( cnt_replayed.value
          , cnt_requests.value
          , cnt_lost.value
          , cnt_overflows.value
          , peak.value
          , stale.value )
      , Some
          { Request.valid = reg spec ask
          ; session = reg spec last_session.value
          ; seq = reg spec expected.value
          ; count = reg spec rq_count
          } )
  in
  let direct_now, _, _ = decide in
  (* whether the message whose first byte is now arriving is passed straight on *)
  let forward = mux2 body_first.value direct_now emitting.value in
  compile
    ([ when_
         p.valid
         [ switch
             cur_phase
             [ ( of_unsigned_int ~width:3 header
               , [ hidx <-- cur_hidx +:. 1
                 ; when_ (cur_hidx <:. 10) [ session <-- (drop_top session.value ~width:8 @: p.data) ]
                 ; when_
                     ((cur_hidx >=:. 10) &: (cur_hidx <=:. 17))
                     [ pkt_seq <-- (drop_top pkt_seq.value ~width:8 @: p.data) ]
                 ; when_ (cur_hidx ==:. 18) [ count <-- uresize p.data ~width:16 ]
                 ; when_
                     (cur_hidx ==:. 19)
                     [ count <-- count_now
                     ; last_session <-- session.value
                     ; incr cnt_packets
                     ; msg_seq <-- pkt_seq.value
                     ; left_in_pkt <-- count_now
                     ; if_ empty_packet [ phase <--. idle ] [ phase <--. len_hi ]
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
                     [ emitting <-- direct_now
                     ; (match recovery with
                        | None ->
                          if_
                            direct_now
                            [ when_ (synced.value &: (s >: expected.value)) [ incr cnt_gaps ] ]
                            [ incr cnt_dups ]
                        | Some _ ->
                          let _, park, _ = decide in
                          when_ (~:direct_now &: ~:park) [ incr cnt_dups ])
                     ]
                 ; when_
                     (remaining.value ==:. 1)
                     [ msg_seq <-- msg_seq.value +:. 1
                     ; left_in_pkt <-- left_in_pkt.value -:. 1
                     ; when_ forward (on_direct_end @ [ incr cnt_messages ])
                     ; if_ (left_in_pkt.value ==:. 1) [ phase <--. idle ] [ phase <--. len_hi ]
                     ]
                 ] )
             ; of_unsigned_int ~width:3 idle, []
             ]
         ; (* payload ended before the packet was complete *)
           when_
             (p.last
              &: ~:(msg_last &: (left_in_pkt.value ==:. 1))
              &: (cur_phase <>:. idle)
              &: ~:(header_end &: empty_packet))
             [ incr cnt_malformed; phase <--. idle ]
         ]
     ; when_ p.abort [ incr cnt_malformed; phase <--. idle ]
     ]
     @ on_packet
     @ extra_logic);
  let live_msg =
    { Stream.Message.valid = in_body &: forward
    ; data = p.data
    ; first = body_first.value
    ; last = msg_last
    ; seq = s
    }
  in
  let msg =
    (match replay_out with
     | None -> live_msg
     | Some (r : Signal.t Stream.Message.t) ->
       (* never both at once: see [start_replay] and [direct] *)
       Stream.Message.map2 live_msg r ~f:(fun l x -> mux2 r.valid x l))
    |> Stream.Message.map ~f:(reg spec)
  in
  let replayed, requests, lost, overflows, buffer_peak, stale =
    match extra_counters with
    | None -> zero 32, zero 32, zero 32, zero 32, zero 16, gnd
    | Some c -> c
  in
  { O.msg
  ; counters =
      { Counters.packets = cnt_packets.value
      ; messages = cnt_messages.value
      ; duplicates = cnt_dups.value
      ; gaps = cnt_gaps.value
      ; malformed = cnt_malformed.value
      ; replayed
      ; requests
      ; lost
      ; overflows
      ; buffer_peak
      ; stale
      }
  ; request =
      Option.value
        request
        ~default:{ Request.valid = gnd; session = zero 80; seq = zero 64; count = zero 16 }
  }
;;

let hierarchical ?recovery scope =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical ~scope ~name:"mold_parser" (create ?recovery)
;;
