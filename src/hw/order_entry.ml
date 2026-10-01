(* Order entry: the trading rule of Itch_model.Ouch.Strategy in hardware,
   an OUCH 5.0 Enter Order in a UDP frame per trigger, sent by Gmii_tx,
   and the tick-to-trade latency of every order.

   - Trigger: on a book event for the rule's slot, "the best ask is present
     and at or below the limit". An order fires when that becomes true, so
     once per crossing ([seen_low] is the previous value; registers reset to
     0, so the rule starts armed, as in the model).
   - A trigger queues (ask price, triggering ITCH sequence number, the time
     its message's last byte was on the receive MAC stream) while a frame
     is going out; a full queue drops the order and counts it.
   - The frame: the Ethernet/IPv4/UDP header of Net.Packet.frame with a
     zero UDP checksum (so it is a constant, IP checksum included), then the
     47-byte Enter Order: UserRefNum counts orders from 1, ClOrdID carries
     the triggering sequence number (Itch_model.Ouch.cl_ord_id_of_seq).
   - Tick-to-trade: from the triggering message's last byte on the receive
     MAC stream to the cycle TX_EN rises at the transmit MAC, plus
     [t2t_offset] (the board adds its fixed pin-to-MAC delays), into the
     same histogram as the book latency. *)

open! Core
open! Hardcaml
open Signal

module Stats = struct
  type 'a t =
    { orders : 'a [@bits 32] (* frames sent *)
    ; fast : 'a [@bits 32] (* of which decided on the fast path *)
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
  (* fast path: a sell Add on the rule's symbol at or below the limit makes
     the ask cross by itself (the new best ask is its price), so when the
     book is up to date the order can go from the parsed command, without
     waiting for the book. Same order, same rule; anything else takes the
     book's event. *)
  let fast_fire, fast_entry =
    match fast with
    | None -> gnd, zero 1
    | Some ((c : Signal.t Symbol_filter.Command.t), book_quiet) ->
      ( c.valid
        &: book_quiet
        &: ~:(event.valid) (* [seen_low] has absorbed every event *)
        &: (c.kind ==: Itch_decoder.Kind.const Add)
        &: (c.slot ==:. rule.slot)
        &: c.sell
        &: (c.shares <>:. 0)
        &: (c.price <=:. rule.limit)
        &: ~:seen_low
      , concat_msb
          [ c.price
          ; sel_bottom c.seq ~width:seq_bits
          ; now -:. Feed_handler.command_offset (* its message's last byte *)
          ] )
  in
  assign seen_low (reg_fb spec ~width:1 ~f:(fun l -> mux2 fast_fire vdd (mux2 ours low l)));
  (* ---- queue ---- *)
  let start = wire 1
  and full = wire 1 in
  let queue =
    Fifo.create
      ~showahead:true
      ~scope
      ()
      ~capacity:queue_capacity
      ~clock
      ~clear
      ~wr:((fire |: fast_fire) &: ~:full)
      ~d:
        (mux2
           fast_fire
           (uresize fast_entry ~width:(32 + seq_bits + 32))
           (concat_msb [ event.ask_price; sel_bottom event.seq ~width:seq_bits; message_time ]))
      ~rd:start
  in
  assign full queue.full;
  let dropped = reg_fb spec ~width:32 ~f:(fun d -> mux2 ((fire |: fast_fire) &: full) (d +:. 1) d) in
  let fast_orders = reg_fb spec ~width:32 ~f:(fun n -> mux2 (fast_fire &: ~:full) (n +:. 1) n) in
  let q_price = select queue.q ~high:(Signal.width queue.q - 1) ~low:(seq_bits + 32) in
  let q_seq = select queue.q ~high:(seq_bits + 31) ~low:32 in
  let q_time = sel_bottom queue.q ~width:32 in
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
  let frame = concat_lsb (const_bytes header @ enter_order) in
  let tx = Gmii_tx.create ~spec ~start ~frame in
  assign start (~:(queue.empty) &: ~:(tx.busy));
  (* ---- tick-to-trade ---- *)
  let t_start = reg spec ~enable:start q_time in
  let t2t = now -: t_start +:. t2t_offset in
  { txen = tx.txen
  ; txd = tx.txd
  ; stats =
      { Stats.orders
      ; fast = fast_orders
      ; dropped
      ; t2t = Latency_monitor.histogram ~spec ~clock ~valid:tx.sof ~sample:t2t
      }
  ; t2t_valid = tx.sof
  ; t2t
  }
;;
