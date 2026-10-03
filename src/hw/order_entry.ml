(* Order entry: the trading rule of Itch_model.Ouch.Strategy in hardware,
   an OUCH 5.0 Enter Order in a UDP frame per trigger, sent by Gmii_tx,
   and the tick-to-trade latency of every order.

   - Trigger: on a book event for the rule's slot, "the best ask is present
     and at or below the limit". An order fires when that becomes true, so
     once per crossing ([seen_low] is the previous value; registers reset to
     0, so the rule starts armed, as in the model). With [fast], the common
     case is decided from the message stream itself, before the book (see
     below).
   - A trigger queues (ask price, triggering ITCH sequence number, the time
     its message's last byte was on the receive MAC stream) while a frame
     is going out; a full queue drops the order and counts it.
   - The frame: the Ethernet/IPv4/UDP header of Net.Packet.frame with a
     zero UDP checksum (so it is a constant, IP checksum included), then the
     47-byte Enter Order: UserRefNum counts orders from 1, ClOrdID carries
     the triggering sequence number (Itch_model.Ouch.cl_ord_id_of_seq).
   - Tick-to-trade: from the triggering message's last byte on the receive
     MAC stream to the order frame's first byte at the transmit MAC, plus
     [t2t_offset] (the board adds its fixed pin-to-MAC delays), into the
     same histogram as the book latency. *)

open! Core
open! Hardcaml
open Signal

module Stats = struct
  type 'a t =
    { orders : 'a [@bits 32] (* frames sent *)
    ; fast : 'a [@bits 32] (* of which decided on the fast path *)
    ; requests : 'a [@bits 32] (* MoldUDP64 re-requests sent *)
    ; dropped : 'a [@bits 32] (* triggers lost to a full queue *)
    ; t2t : 'a Latency_monitor.Stats.t [@rtlmangle "_"]
    }
  [@@deriving hardcaml]
end

type t =
  { txen : Signal.t
  ; txd : Signal.t
  ; stats : Signal.t Stats.t
  ; t2t_valid : Signal.t
  ; t2t : Signal.t
  }

let seq_bits = 52
let queue_capacity = 16

let const_bytes s = String.to_list s |> List.map ~f:(fun c -> of_unsigned_int ~width:8 (Char.to_int c))

(* big endian bytes of [x], [n] bytes *)
let be_bytes x n = List.init n ~f:(fun k -> select x ~high:((8 * (n - k)) - 1) ~low:(8 * (n - k - 1)))

let hex_digit n = mux2 (n <:. 10) (uresize n ~width:8 +:. Char.to_int '0') (uresize n ~width:8 +:. (Char.to_int 'A' - 10))

let create
  ~(rule : Itch_model.Ouch.Rule.t)
  ?(t2t_offset = 0)
  ?fast
  ?(request : Signal.t Mold_parser.Request.t option)
  scope
  ~clock
  ~clear
  ~(event : Signal.t Order_book.Event.t)
  ~message_time
  ~now
  =
  let spec = Reg_spec.create ~clock ~clear () in
  (* ---- trigger ---- *)
  let ours = event.valid &: (event.slot ==:. rule.slot) in
  let low = (event.ask_shares <>:. 0) &: (event.ask_price <=:. rule.limit) in
  let seen_low = wire 1 in
  let fire = ours &: low &: ~:seen_low in
  (* Fast path. For this rule a sell Add on the rule's symbol at or below the
     limit makes the ask cross by itself (the new best ask is its price), so
     when the book is up to date (idle, nothing queued, no event in flight,
     the rule armed) the order can go without waiting for the book. A small
     detector reads the MoldUDP64 message stream directly and decides on the
     message's last byte, its price compared as that byte arrives:
     - type 'A' or 'F', the rule's symbol (its locate, from the symbol
       filter), side 'S', shares not zero, price at or below the limit;
     - from byte 23 (shares complete), such a message makes the transmit
       MAC pre-form the preamble, so the order's SFD can follow the
       decision directly; if the price turns out above the limit, the
       preamble is cancelled before any SFD, which is not a frame.
     Same order, same rule; anything else takes the book's event, and the
     event of a fast-path order does not fire again. *)
  let tx_busy = wire 1
  and tx_holding = wire 1
  and queue_empty = wire 1 in
  let can_bypass = wire 1 in
  let fast_fire, fast_entry, prestart, cancel, late_patch, fast_data =
    match fast with
    | None -> gnd, zero 1, gnd, gnd, gnd, zero 8
    | Some ((m : Signal.t Stream.Message.t), locate, mapped, book_quiet) ->
      let count = wire 6 in
      let pos = mux2 m.first (zero 6) count in
      assign
        count
        (reg_fb spec ~width:6 ~f:(fun c ->
           let p = mux2 m.first (zero 6) c in
           mux2 m.valid (mux2 m.last (zero 6) (mux2 (p ==:. 63) p (p +:. 1))) c));
      let at k = m.valid &: (pos ==:. k) in
      let d = m.data in
      let keep k x = reg spec ~enable:(at k) x in
      let is_a = keep 0 (d ==:. Char.to_int 'A')
      and is_f = keep 0 (d ==:. Char.to_int 'F') in
      let loc_hi = keep 1 d in
      let ours = keep 2 (mapped &: (concat_msb [ loc_hi; d ] ==: locate)) in
      let sell = keep 19 (d ==:. Char.to_int 'S') in
      let shares_seen = wire 1 in
      let shares_nz_now = mux2 (at 20) (d <>:. 0) (shares_seen |: (d <>:. 0)) in
      assign shares_seen (reg spec ~enable:(at 20 |: at 21 |: at 22 |: at 23) shares_nz_now);
      let p32 = keep 32 d
      and p33 = keep 33 d
      and p34 = keep 34 d in
      let price_live = concat_msb [ p32; p33; p34; d ] in
      let price_kept = keep 35 price_live in
      let price = mux2 (at 35) price_live price_kept in
      (* "price at or below the limit", one byte at a time (big endian): a
         byte comparison with a constant per cycle, and the answer is often
         known before the last byte (below, [early]) *)
      let lb k = (rule.limit lsr (8 * (3 - k))) land 0xff in
      let lt1 = keep 32 (d <:. lb 0)
      and eq1 = keep 32 (d ==:. lb 0) in
      let lt2 = keep 33 (lt1 |: (eq1 &: (d <:. lb 1)))
      and eq2 = keep 33 (eq1 &: (d ==:. lb 1)) in
      let lt3_now = lt2 |: (eq2 &: (d <:. lb 2))
      and eq3_now = eq2 &: (d ==:. lb 2) in
      let lt3 = keep 34 lt3_now
      and eq3 = keep 34 eq3_now in
      let le_now = lt3 |: (eq3 &: (d <=:. lb 3)) in
      let le = keep 35 le_now in
      let ready = book_quiet &: ~:(event.valid) &: ~:seen_low in
      let candidate = (is_a |: is_f) &: ours &: sell in
      (* Early: an Add whose first three price bytes are already below the
         limit's fires on its third price byte, a cycle before its last;
         the price's last byte goes into the frame as it arrives (Gmii_tx's
         late byte). Only straight to the transmit MAC: a queued order
         would need its price whole. *)
      let early = at 34 &: is_a &: candidate &: shares_seen &: lt3_now &: ready &: can_bypass in
      let fired_early = reg_fb spec ~width:1 ~f:(fun e -> mux2 early vdd (mux2 (m.valid &: m.last) gnd e)) in
      let fire =
        early
        |: (m.valid
            &: m.last
            &: ((is_a &: (pos ==:. 35) &: le_now &: ~:fired_early) |: (is_f &: (pos ==:. 39) &: le))
            &: candidate
            &: shares_seen
            &: ready)
      in
      let prestart = at 23 &: candidate &: shares_nz_now &: ready &: ~:tx_busy &: queue_empty in
      (* cancel a pre-formed preamble when its message ends without an order
         (or, failing that, after 64 cycles) *)
      let pending = reg_fb spec ~width:1 ~f:(fun p -> mux2 prestart vdd (mux2 (m.valid &: m.last) gnd p)) in
      let held = reg_fb spec ~width:7 ~f:(fun h -> mux2 tx_holding (mux2 (msb h) h (h +:. 1)) (zero 7)) in
      let cancel = tx_holding &: ~:fire &: ((pending &: m.valid &: m.last) |: msb held) in
      ( fire
      , concat_msb
          [ mux2 early (concat_msb [ p32; p33; d; zero 8 ]) price
          ; sel_bottom m.seq ~width:seq_bits
          ; (* its message's last byte on the MAC stream (for [early], the
               next cycle) *)
            mux2 early (now -:. (Feed_handler.message_offset - 1)) (now -:. Feed_handler.message_offset)
          ]
      , prestart
      , cancel
      , fired_early &: at 35 (* the early order's last price byte arrives *)
      , d )
  in
  assign seen_low (reg_fb spec ~width:1 ~f:(fun l -> mux2 fast_fire vdd (mux2 ours low l)));
  (* ---- queue ---- *)
  let start = wire 1
  and full = wire 1 in
  (* A fast-path order with nothing queued goes straight to the transmit
     MAC in the cycle it is decided (a cycle sooner than through the
     queue); anything else is queued. *)
  let bypass = fast_fire &: can_bypass in
  let entry_width = 32 + seq_bits + 32 in
  let queue =
    Fifo.create
      ~showahead:true
      ~scope
      ()
      ~capacity:queue_capacity
      ~clock
      ~clear
      ~wr:((fire |: fast_fire) &: ~:bypass &: ~:full)
      ~d:
        (mux2
           fast_fire
           (uresize fast_entry ~width:entry_width)
           (concat_msb [ event.ask_price; sel_bottom event.seq ~width:seq_bits; message_time ]))
      ~rd:start
  in
  assign full queue.full;
  assign queue_empty queue.empty;
  let dropped = reg_fb spec ~width:32 ~f:(fun d -> mux2 ((fire |: fast_fire) &: ~:bypass &: full) (d +:. 1) d) in
  let fast_orders = reg_fb spec ~width:32 ~f:(fun n -> mux2 (fast_fire &: ~:full) (n +:. 1) n) in
  let src = mux2 bypass (uresize fast_entry ~width:entry_width) queue.q in
  let q_price = select src ~high:(entry_width - 1) ~low:(seq_bits + 32) in
  let q_seq = select src ~high:(seq_bits + 31) ~low:32 in
  let q_time = sel_bottom src ~width:32 in
  (* ---- frame ---- *)
  let orders = reg_fb spec ~width:32 ~f:(fun n -> mux2 start (n +:. 1) n) in
  let header =
    String.prefix
      (Net.Packet.frame
         ~udp_checksum:false
         Net.Packet.order_endpoints
         (String.make Itch_model.Ouch.enter_order_len '\000'))
      Net.Packet.payload_offset
  in
  let enter_order =
    List.concat
      [ const_bytes "O"
      ; be_bytes (orders +:. 1) 4 (* UserRefNum *)
      ; const_bytes "B"
      ; be_bytes (of_unsigned_int ~width:32 rule.quantity) 4
      ; const_bytes (Itch_model.Itch.pad_stock rule.symbol)
      ; be_bytes (uresize q_price ~width:64) 8
      ; const_bytes "3YPNN" (* IOC, visible, principal, no ISO, continuous *)
      ; const_bytes "S"
      ; List.init 13 ~f:(fun k ->
          hex_digit (select q_seq ~high:(seq_bits - 1 - (4 * k)) ~low:(seq_bits - 4 - (4 * k))))
      ; be_bytes (zero 16) 2 (* no appendage *)
      ]
  in
  assert (List.length enter_order = Itch_model.Ouch.enter_order_len);
  let price_offset = 1 + 4 + 1 + 4 + 8 (* the 8-byte price, within the Enter Order *) in
  let order_frame = concat_lsb (const_bytes header @ enter_order) in
  (* MoldUDP64 re-requests (gap recovery) share the transmit MAC: one
     pending request, replaced by a newer one; it goes out only when no
     order is waiting or being decided. The 62-byte request is padded to
     the order frame's length: receivers go by the IP and UDP lengths and
     ignore Ethernet padding. *)
  let rq_start, rq_frame, requests_sent =
    match request with
    | None -> gnd, zero (Signal.width order_frame), zero 32
    | Some rq ->
      let pending = Always.Variable.reg spec ~width:1 in
      let r_session = Always.Variable.reg spec ~width:80 in
      let r_seq = Always.Variable.reg spec ~width:64 in
      let r_count = Always.Variable.reg spec ~width:16 in
      let go = wire 1 in
      let header =
        String.prefix
          (Net.Packet.frame
             ~udp_checksum:false
             Net.Packet.request_endpoints
             (Net.Packet.mold_request ~session:(String.make 10 ' ') ~seq:0 ~count:0))
          Net.Packet.payload_offset
      in
      let bytes =
        const_bytes header
        @ be_bytes r_session.value 10
        @ be_bytes r_seq.value 8
        @ be_bytes r_count.value 2
      in
      let frame = concat_lsb (bytes @ List.init (Signal.width order_frame / 8 - List.length bytes) ~f:(fun _ -> zero 8)) in
      Always.(
        compile
          [ when_ go [ pending <-- gnd ]
          ; when_
              rq.valid
              [ pending <-- vdd; r_session <-- rq.session; r_seq <-- rq.seq; r_count <-- rq.count ]
          ]);
      assign go (pending.value &: queue.empty &: ~:(tx_busy) &: ~:prestart &: ~:fast_fire);
      go, frame, reg_fb spec ~width:32 ~f:(fun n -> mux2 go (n +:. 1) n)
  in
  let frame = mux2 rq_start rq_frame order_frame in
  (* the price's last byte, sent late: set with the frame (zero in a
     request's padding), and for an [early] order replaced as it arrives *)
  let late_index = Net.Packet.payload_offset + price_offset + 7 in
  let late_value =
    reg_fb spec ~width:8 ~f:(fun v ->
      mux2
        late_patch
        fast_data
        (mux2 start (sel_bottom q_price ~width:8) (mux2 rq_start (zero 8) v)))
  in
  let tx =
    Gmii_tx.create ~prestart ~cancel ~late:(late_index, late_value) ~spec ~start:(start |: rq_start) ~frame ()
  in
  assign tx_busy tx.busy;
  assign tx_holding tx.holding;
  assign can_bypass (queue.empty &: (~:(tx.busy) |: tx.holding));
  assign start (bypass |: (~:(queue.empty) &: (~:(tx.busy) |: tx.holding)));
  (* ---- tick-to-trade ---- *)
  let t_start = reg spec ~enable:start q_time in
  (* the frame going out is an order (not a request): it alone is timed *)
  let sending_order = reg_fb spec ~width:1 ~f:(fun o -> mux2 start vdd (mux2 rq_start gnd o)) in
  let t2t = now -: t_start +:. t2t_offset in
  { txen = tx.txen
  ; txd = tx.txd
  ; stats =
      { Stats.orders
      ; fast = fast_orders
      ; requests = requests_sent
      ; dropped
      ; t2t = Latency_monitor.histogram ~spec ~clock ~valid:(tx.first &: sending_order) ~sample:t2t
      }
  ; t2t_valid = tx.first &: sending_order
  ; t2t
  }
;;
