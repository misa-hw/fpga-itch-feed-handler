(* The OUCH 5.0 Enter Order encoder against the specification's layout
   (section 2.1): every field at its offset and length. *)

open! Core
open Itch_model

let%expect_test "Enter Order layout" =
  let s =
    Ouch.enter_order_to_string
      { user_ref_num = 0x01020304
      ; side = 'B'
      ; quantity = 100
      ; symbol = Itch.pad_stock "QQQ"
      ; price = 1_901_200 (* $190.12 *)
      ; cl_ord_id = Ouch.cl_ord_id_of_seq 0x123456789
      }
  in
  let field name ~pos ~len =
    let v = String.sub s ~pos ~len in
    let hex = String.concat_map v ~f:(fun c -> sprintf "%02x" (Char.to_int c)) in
    printf "%-17s %2d %2d  %-28s %S\n" name pos len hex v
  in
  printf "%d bytes\n" (String.length s);
  field "Type" ~pos:0 ~len:1;
  field "UserRefNum" ~pos:1 ~len:4;
  field "Side" ~pos:5 ~len:1;
  field "Quantity" ~pos:6 ~len:4;
  field "Symbol" ~pos:10 ~len:8;
  field "Price" ~pos:18 ~len:8;
  field "Time In Force" ~pos:26 ~len:1;
  field "Display" ~pos:27 ~len:1;
  field "Capacity" ~pos:28 ~len:1;
  field "InterMarket Sweep" ~pos:29 ~len:1;
  field "CrossType" ~pos:30 ~len:1;
  field "ClOrdID" ~pos:31 ~len:14;
  field "Appendage Length" ~pos:45 ~len:2;
  [%expect {|
    47 bytes
    Type               0  1  4f                           "O"
    UserRefNum         1  4  01020304                     "\001\002\003\004"
    Side               5  1  42                           "B"
    Quantity           6  4  00000064                     "\000\000\000d"
    Symbol            10  8  5151512020202020             "QQQ     "
    Price             18  8  00000000001d0290             "\000\000\000\000\000\029\002\144"
    Time In Force     26  1  33                           "3"
    Display           27  1  59                           "Y"
    Capacity          28  1  50                           "P"
    InterMarket Sweep 29  1  4e                           "N"
    CrossType         30  1  4e                           "N"
    ClOrdID           31 14  5330303030313233343536373839 "S0000123456789"
    Appendage Length  45  2  0000                         "\000\000"
    |}]
;;

let%expect_test "the rule fires once per crossing of the limit" =
  let s = Ouch.Strategy.create { slot = 0; symbol = "QQQ"; limit = 10_000; quantity = 100 } in
  let tob ~ask_price ~ask_shares = { Book.Tob.slot = 0; bid_price = 0; bid_shares = 0; ask_price; ask_shares } in
  List.iteri
    [ 0, 0 (* no ask *)
    ; 10_100, 5 (* above *)
    ; 10_000, 5 (* crosses: order *)
    ; 9_900, 5 (* still below: none *)
    ; 10_100, 5 (* back above *)
    ; 9_950, 7 (* crosses again: order *)
    ; 0, 0 (* ask gone *)
    ; 9_950, 7 (* from no ask to below: order *)
    ]
    ~f:(fun seq (ask_price, ask_shares) ->
      match Ouch.Strategy.on_tob s ~seq (tob ~ask_price ~ask_shares) with
      | None -> printf "seq %d ask %d x %d: -\n" seq ask_price ask_shares
      | Some o ->
        printf "seq %d ask %d x %d: order %d, %d @ %d, %s\n" seq ask_price ask_shares o.user_ref_num o.quantity o.price o.cl_ord_id);
  [%expect {|
    seq 0 ask 0 x 0: -
    seq 1 ask 10100 x 5: -
    seq 2 ask 10000 x 5: order 1, 100 @ 10000, S0000000000002
    seq 3 ask 9900 x 5: -
    seq 4 ask 10100 x 5: -
    seq 5 ask 9950 x 7: order 2, 100 @ 9950, S0000000000005
    seq 6 ask 0 x 0: -
    seq 7 ask 9950 x 7: order 3, 100 @ 9950, S0000000000007
    |}]
;;
