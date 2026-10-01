(* OUCH 5.0 Enter Order (Nasdaq, "OUCH 5.0 Order Entry Specification",
   section 2.1), and the toy trading rule the board implements.

   Enter Order, 47 bytes with no optional appendage; numbers are big
   endian, alpha fields left justified and padded with spaces:
     0 'O' | 1 UserRefNum (4) | 5 Side | 6 Quantity (4) | 10 Symbol (8)
     | 18 Price (8, 4 implied decimals) | 26 Time In Force | 27 Display
     | 28 Capacity | 29 InterMarket Sweep | 30 CrossType | 31 ClOrdID (14)
     | 45 Appendage Length (2)
   On a real venue OUCH runs over SoupBinTCP; the board sends each message
   in a UDP datagram. *)

open! Core

let enter_order_len = 47

type enter_order =
  { user_ref_num : int
  ; side : char
  ; quantity : int
  ; symbol : string
  ; price : int
  ; cl_ord_id : string
  }
[@@deriving sexp, equal]

let enter_order_to_string o =
  let b = Bytes.make enter_order_len ' ' in
  let put ~pos ~len v = Itch.put_be b ~pos ~len v in
  let put_alpha ~pos ~len s =
    String.iteri (String.prefix s len) ~f:(fun k c -> Bytes.set b (pos + k) c)
  in
  Bytes.set b 0 'O';
  put ~pos:1 ~len:4 o.user_ref_num;
  Bytes.set b 5 o.side;
  put ~pos:6 ~len:4 o.quantity;
  put_alpha ~pos:10 ~len:8 o.symbol;
  put ~pos:18 ~len:8 o.price;
  Bytes.set b 26 '3' (* IOC *);
  Bytes.set b 27 'Y' (* visible *);
  Bytes.set b 28 'P' (* principal *);
  Bytes.set b 29 'N' (* not an intermarket sweep *);
  Bytes.set b 30 'N' (* continuous market *);
  put_alpha ~pos:31 ~len:14 o.cl_ord_id;
  put ~pos:45 ~len:2 0 (* no appendage *);
  Bytes.to_string b
;;

(* ClOrdID: 'S' and the ITCH sequence number of the message that triggered
   the order, as 13 upper-case hex digits (its low 52 bits) *)
let cl_ord_id_of_seq seq = sprintf "S%013X" (seq land ((1 lsl 52) - 1))

(* The rule: for the book in [slot], when its best ask falls to [limit] or
   below (from above it, or from no ask), buy [quantity] at that ask,
   immediate-or-cancel. Edge triggered: one order per crossing. *)
module Rule = struct
  type t =
    { slot : int
    ; symbol : string
    ; limit : int
    ; quantity : int
    }
  [@@deriving sexp]
end

(* The rule built into the board's 1 Gb/s image: buy 100 SPY when the offer
   comes down to $300.00. On the tracked pcap it sends 53 orders. *)
let board_rule = { Rule.slot = 1; symbol = "SPY"; limit = 3_000_000 (* $300.00 *); quantity = 100 }

module Strategy = struct
  type t =
    { rule : Rule.t
    ; mutable armed : bool
    ; mutable sent : int
    }

  let create rule = { rule; armed = true; sent = 0 }

  (* Top of book after the book command with ITCH sequence [seq]. *)
  let on_tob t ~seq (tob : Book.Tob.t) =
    if tob.slot <> t.rule.slot
    then None
    else (
      let low = tob.ask_shares > 0 && tob.ask_price <= t.rule.limit in
      let fire = low && t.armed in
      t.armed <- not low;
      if not fire
      then None
      else (
        t.sent <- t.sent + 1;
        Some
          { user_ref_num = t.sent
          ; side = 'B'
          ; quantity = t.rule.quantity
          ; symbol = Itch.pad_stock t.rule.symbol
          ; price = tob.ask_price
          ; cl_ord_id = cl_ord_id_of_seq seq
          }))
  ;;
end
