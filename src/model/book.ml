(* Reference order book: the golden model the hardware is checked against.

   - A fixed list of up to [max_symbols] symbols is tracked. Stock Directory
     ('R') messages bind each tracked symbol to its day-specific stock locate
     code; the symbol's position in the list is its "slot".
   - Orders are kept by reference number. Every order message carries the
     locate code, so messages for untracked stocks are dropped immediately.
   - Each (slot, side) keeps price levels: price -> aggregate shares.
   - After each message, if the best bid or best ask (price or aggregate size)
     of the affected symbol changed, a [Tob.t] event is produced.

   Deliberately simple and obviously correct (Hashtbl + Map); speed and
   hardware realism are not goals here. *)

open! Core

let max_symbols = 8

module Tob = struct
  (* An empty side is reported as price 0, shares 0. *)
  type t =
    { slot : int
    ; bid_price : int
    ; bid_shares : int
    ; ask_price : int
    ; ask_shares : int
    }
  [@@deriving sexp, compare, equal]

  let to_string t =
    sprintf
      "slot=%d bid=%d@%s ask=%d@%s"
      t.slot
      t.bid_shares
      (Itch.price_to_string t.bid_price)
      t.ask_shares
      (Itch.price_to_string t.ask_price)
  ;;
end

type order =
  { slot : int
  ; side : Itch.side
  ; price : int
  ; mutable shares : int
  }

type t =
  { symbols : string array (* padded to 8 chars *)
  ; slot_of_locate : (int, int) Hashtbl.t
  ; orders : (int, order) Hashtbl.t
  ; bids : int Int.Map.t array (* per slot: price -> shares *)
  ; asks : int Int.Map.t array
  ; last_tob : Tob.t array
  ; mutable anomalies : int (* e.g. a reduce larger than the order: should stay 0 *)
  }

let create symbols =
  let n = List.length symbols in
  if n = 0 || n > max_symbols
  then invalid_arg (sprintf "need 1..%d symbols, got %d" max_symbols n);
  { symbols = Array.of_list_map symbols ~f:Itch.pad_stock
  ; slot_of_locate = Hashtbl.create (module Int)
  ; orders = Hashtbl.create (module Int) ~size:100_000
  ; bids = Array.create ~len:n Int.Map.empty
  ; asks = Array.create ~len:n Int.Map.empty
  ; last_tob =
      Array.init n ~f:(fun slot ->
        { Tob.slot; bid_price = 0; bid_shares = 0; ask_price = 0; ask_shares = 0 })
  ; anomalies = 0
  }
;;

let symbols t = Array.to_list t.symbols |> List.map ~f:String.rstrip
let num_live_orders t = Hashtbl.length t.orders
let anomalies t = t.anomalies
let slot_of_locate t locate = Hashtbl.find t.slot_of_locate locate

let levels t slot (side : Itch.side) =
  match side with
  | Buy -> t.bids.(slot)
  | Sell -> t.asks.(slot)
;;

let set_levels t slot (side : Itch.side) m =
  match side with
  | Buy -> t.bids.(slot) <- m
  | Sell -> t.asks.(slot) <- m
;;

let num_levels t slot side = Map.length (levels t slot side)

let add_to_level t slot side price delta =
  let m =
    Map.change (levels t slot side) price ~f:(fun old ->
      let v = Option.value old ~default:0 + delta in
      if v < 0 then t.anomalies <- t.anomalies + 1;
      if v <= 0 then None else Some v)
  in
  set_levels t slot side m
;;

(* Remove [shares] from an order (executions, cancels), or all of it
   ([`All], for deletes and replaces). *)
let reduce t order_ref amount =
  match Hashtbl.find t.orders order_ref with
  | None -> ()
  | Some o ->
    let shares =
      match amount with
      | `All -> o.shares
      | `Shares shares when shares > o.shares ->
        t.anomalies <- t.anomalies + 1;
        o.shares
      | `Shares shares -> shares
    in
    add_to_level t o.slot o.side o.price (-shares);
    o.shares <- o.shares - shares;
    if o.shares = 0 then Hashtbl.remove t.orders order_ref
;;

let add t ~slot ~order_ref ~side ~price ~shares =
  if Hashtbl.mem t.orders order_ref then t.anomalies <- t.anomalies + 1;
  if shares > 0
  then (
    Hashtbl.set t.orders ~key:order_ref ~data:{ slot; side; price; shares };
    add_to_level t slot side price shares)
;;

let best m ~side : int * int =
  match
    (match (side : Itch.side) with
     | Buy -> Map.max_elt m
     | Sell -> Map.min_elt m)
  with
  | None -> 0, 0
  | Some (p, s) -> p, s
;;

let tob t slot =
  let bid_price, bid_shares = best t.bids.(slot) ~side:Buy in
  let ask_price, ask_shares = best t.asks.(slot) ~side:Sell in
  { Tob.slot; bid_price; bid_shares; ask_price; ask_shares }
;;

(* Apply one message; [Some tob] if the symbol's top of book changed. *)
let apply t (msg : Itch.t) =
  let tracked = Hashtbl.find t.slot_of_locate msg.header.locate in
  (match msg.body, tracked with
   | Stock_directory { stock; _ }, _ ->
     (match Array.findi t.symbols ~f:(fun _ s -> String.equal s stock) with
      | Some (slot, _) -> Hashtbl.set t.slot_of_locate ~key:msg.header.locate ~data:slot
      | None -> ())
   | _, None -> ()
   | Add_order { order_ref; side; shares; price; _ }, Some slot ->
     add t ~slot ~order_ref ~side ~price ~shares
   | Order_executed { order_ref; shares; _ }, Some _
   | Order_executed_with_price { order_ref; shares; _ }, Some _
   | Order_cancel { order_ref; shares }, Some _ -> reduce t order_ref (`Shares shares)
   | Order_delete { order_ref }, Some _ -> reduce t order_ref `All
   | Order_replace { orig_ref; new_ref; shares; price }, Some slot ->
     (match Hashtbl.find t.orders orig_ref with
      | None -> ()
      | Some o ->
        reduce t orig_ref `All;
        add t ~slot ~order_ref:new_ref ~side:o.side ~price ~shares)
   | Other _, Some _ -> ());
  match msg.body, tracked with
  | Stock_directory _, _ | Other _, _ | _, None -> None
  | _, Some slot ->
    let now = tob t slot in
    if Tob.equal now t.last_tob.(slot)
    then None
    else (
      t.last_tob.(slot) <- now;
      Some now)
;;
