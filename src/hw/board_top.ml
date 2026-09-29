(* QMTech Wukong (XC7A100T, V2/V3) top level.

   Two clock domains:
   - rxc (125 MHz GMII at 1 Gb/s, or 25 MHz MII at 100 Mb/s, from the
     RTL8211EG PHY; only running while the link is up): receive MAC -> Feed_handler. Every
     top-of-book change is hashed (CRC-32 over its fields) and counted, and
     pushed into an asynchronous FIFO for printing.
   - clk50 (50 MHz board oscillator): UART at 115200 baud. Prints one line
     per top-of-book change taken from the FIFO (while the UART keeps up;
     otherwise lines are dropped and counted) and, once a second, a status
     line with every counter, the event count and the event hash. The hash
     covers every change even when lines are dropped, so a full-speed replay
     is checked against the model by comparing two numbers.

   Counters cross from rxc to clk50 by a request/acknowledge handshake: the
   snapshot registers only change on request, so they are stable when the
   acknowledge arrives.

   Both domains have a power-on reset (every flip-flop starts at 0, which is
   not a valid one-hot state) and KEY0 resets both. The PHY is held in reset
   for ~20 ms after configuration or KEY0. *)

open! Core
open! Hardcaml
open Signal

module I = struct
  type 'a t =
    { clk50 : 'a
    ; reset_n : 'a
    ; e_rxc : 'a
    ; e_rxd : 'a [@bits 8]
    ; e_rxdv : 'a
    ; e_rxer : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { uart_tx : 'a
    ; e_reset : 'a (* PHY reset, active low *)
    ; e_mdc : 'a
    ; e_txen : 'a
    ; e_txer : 'a
    ; led : 'a (* unused on the board; keeps a pin for probing *)
    }
  [@@deriving hardcaml]
end

(* reset: power-on counter (no reset of its own) OR a synchronised key *)
let domain_clear ~clock ~reset_n =
  let r = Reg_spec.create ~clock () in
  let key = reg r (reg r ~:reset_n) in
  let por = reg_fb r ~width:5 ~f:(fun c -> mux2 (msb c) c (c +:. 1)) in
  reg r (key |: ~:(msb por))
;;

let sync ~clock s =
  let r = Reg_spec.create ~clock () in
  reg r (reg r s)
;;

let event_bits = 32 + 8 + (4 * 32)

(* The fields of a change as hashed and printed; the model computes the same
   CRC over [seq(4) slot(1) bid_price(4) bid_shares(4) ask_price(4)
   ask_shares(4)], each little endian. *)
let event_word (e : Signal.t Order_book.Event.t) =
  concat_msb
    [ e.ask_shares; e.ask_price; e.bid_shares; e.bid_price; uresize e.slot ~width:8; sel_bottom e.seq ~width:32 ]
;;

module Event_fifo = Async_fifo.Make (struct
    let width = event_bits
    let log2_depth = 5
    let optimize_for_same_clock_rate_and_always_reading = false
  end)

let create ?(mii_mode = false) ?(bit_cycles = 434) ?(second = 50_000_000) ?(phy_reset_cycles = 1 lsl 20) scope (i : _ I.t) : _ O.t =
  (* ---------------- rxc domain ---------------- *)
  let rxc = i.e_rxc in
  let clear_rx = domain_clear ~clock:rxc ~reset_n:i.reset_n in
  let rs = Reg_spec.create ~clock:rxc ~clear:clear_rx () in
  let rin = Reg_spec.create ~clock:rxc () in
  (* input registers (packed into the IOBs) *)
  let rxd = reg rin i.e_rxd and rxdv = reg rin i.e_rxdv and rxer = reg rin i.e_rxer in
  let mac = Gmii_rx.hierarchical ~mii_mode scope { clock = rxc; clear = clear_rx; rx_dv = rxdv; rx_er = rxer; rxd } in
  let fh =
    Feed_handler.create scope { clock = rxc; clear = clear_rx; cfg = Timing_top.config (); rx = mac.rx }
  in
  let ev = fh.event in
  let change = ev.valid &: ev.changed in
  let word = event_word ev in
  let ev_hash = reg_fb rs ~width:32 ~f:(fun h -> mux2 change (Crc32.next ~crc:h ~data:word) h) in
  let ev_count = reg_fb rs ~width:32 ~f:(fun c -> mux2 change (c +:. 1) c) in
  let rx_cycles = reg_fb rs ~width:32 ~f:(fun c -> c +:. 1) in
  (* ---------------- clk50 domain ---------------- *)
  let clk = i.clk50 in
  let clear50 = domain_clear ~clock:clk ~reset_n:i.reset_n in
  let s50 = Reg_spec.create ~clock:clk ~clear:clear50 () in
  let fifo_rd = wire 1 in
  let fifo =
    Event_fifo.hierarchical
      scope
      { clock_write = rxc
      ; clock_read = clk
      ; reset_write = clear_rx
      ; reset_read = clear50
      ; data_in = word
      ; write_enable = change
      ; read_enable = fifo_rd
      }
  in
  let lost = reg_fb rs ~width:32 ~f:(fun c -> mux2 (change &: fifo.full) (c +:. 1) c) in
  (* counter snapshot handshake *)
  let req = wire 1 in
  let req_rx = sync ~clock:rxc req in
  let req_rx_d = reg rs req_rx in
  let take = req_rx ^: req_rx_d in
  let c = fh.counters in
  let counters =
    [ "frm", c.frame.frames
    ; "acc", c.frame.accepted
    ; "flt", c.frame.filtered
    ; "err", c.frame.errors
    ; "fcs", mac.crc_errors
    ; "msg", c.mold.messages
    ; "gap", c.mold.gaps
    ; "dup", c.mold.duplicates
    ; "cmd", c.book.processed
    ; "chg", ev_count
    ; "hash", ev_hash
    ; "lost", lost
    ; "kick", c.book.kicks
    ; "rfl", c.book.refills
    ; "ovf", c.book.order_overflows +: c.book.level_overflows +: c.book.fifo_overflows
    ; "ord", uresize c.book.orders ~width:32
    ; "lvl", uresize c.book.levels ~width:32
    ; "map", uresize c.mapped ~width:8
    ; "clk", rx_cycles
    ]
  in
  let snap = List.map counters ~f:(fun (name, s) -> name, reg rs ~enable:take s) in
  let ack_rx = reg_fb rs ~width:1 ~f:(fun a -> mux2 take ~:a a) in
  let ack = sync ~clock:clk ack_rx in
  (* once a second: request a snapshot, wait for the acknowledge (or give up
     after 1 ms if rxc is not running), then print the status line *)
  let open Always in
  let tick = Variable.reg s50 ~width:(num_bits_to_represent second) in
  let req_v = Variable.reg s50 ~width:1 in
  let waiting = Variable.reg s50 ~width:1 in
  let wait_timer = Variable.reg s50 ~width:17 in
  let ack_seen = Variable.reg s50 ~width:1 in
  let status_due = Variable.reg s50 ~width:1 in
  let link = Variable.reg s50 ~width:1 in
  let ack_prev = Variable.reg s50 ~width:1 in
  let latched = List.map snap ~f:(fun (name, s) -> name, Variable.reg s50 ~width:(Signal.width s), s) in
  let ev_latch = Variable.reg s50 ~width:event_bits in
  (* printer *)
  let start = Variable.wire ~default:gnd () in
  let which = Variable.wire ~default:gnd () in
  let uart_ready = wire 1 in
  let field_of (v : Variable.t) ~high ~low = select v.value ~high ~low in
  let e = ev_latch in
  let event_line =
    Line_printer.
      [ Lit "E "
      ; Hex (field_of e ~high:31 ~low:0)
      ; Lit " "
      ; Hex (field_of e ~high:34 ~low:32)
      ; Lit " "
      ; Hex (field_of e ~high:71 ~low:40)
      ; Lit " "
      ; Hex (field_of e ~high:103 ~low:72)
      ; Lit " "
      ; Hex (field_of e ~high:135 ~low:104)
      ; Lit " "
      ; Hex (field_of e ~high:167 ~low:136)
      ; Lit "\r\n"
      ]
  in
  let status_line =
    Line_printer.Lit "S"
    :: Line_printer.Hex link.value
    :: List.concat_map latched ~f:(fun (name, v, _) -> Line_printer.[ Lit (" " ^ name ^ "="); Hex v.value ])
    @ [ Line_printer.Lit "\r\n" ]
  in
  let busy, send, char =
    Line_printer.create
      ~clock:clk
      ~clear:clear50
      ~lines:[| event_line; status_line |]
      ~which:which.value
      ~start:start.value
      ~uart_ready
  in
  let ready, tx = Uart_tx.create ~clock:clk ~clear:clear50 ~bit_cycles ~valid:send ~data:char in
  Signal.assign uart_ready ready;
  Signal.assign fifo_rd (~:busy &: ~:(status_due.value) &: fifo.valid);
  compile
    [ tick <-- tick.value +:. 1
    ; ack_prev <-- ack
    ; when_ (tick.value ==:. second - 1) [ tick <--. 0; req_v <-- ~:(req_v.value); waiting <-- vdd; wait_timer <--. 0; ack_seen <-- gnd ]
    ; when_
        waiting.value
        [ wait_timer <-- wait_timer.value +:. 1
        ; when_
            (ack ^: ack_prev.value)
            [ waiting <-- gnd
            ; link <-- vdd
            ; status_due <-- vdd
            ; proc (List.map latched ~f:(fun (_, v, s) -> v <-- s))
            ]
        ; when_ (wait_timer.value ==:. 50_000) [ waiting <-- gnd; link <-- gnd; status_due <-- vdd ]
        ]
    ; if_
        (~:busy &: status_due.value)
        [ start <-- vdd; which <-- vdd; status_due <-- gnd ]
        [ when_ (~:busy &: fifo.valid) [ ev_latch <-- fifo.data_out; start <-- vdd; which <-- gnd ] ]
    ];
  Signal.assign req req_v.value;
  (* PHY reset: low for [phy_reset_cycles] after configuration or KEY0 *)
  let phy_timer =
    reg_fb s50 ~width:(num_bits_to_represent phy_reset_cycles) ~f:(fun t ->
      mux2 (t ==:. phy_reset_cycles) t (t +:. 1))
  in
  ignore ack_seen;
  { O.uart_tx = tx
  ; e_reset = phy_timer ==:. phy_reset_cycles
  ; e_mdc = gnd
  ; e_txen = gnd
  ; e_txer = gnd
  ; led = link.value
  }
;;
