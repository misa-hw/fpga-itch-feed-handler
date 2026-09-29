open! Core
open Itch_model

let hdr = { Itch.locate = 7; tracking = 2; timestamp = 34_200_000_000_123 }
let stock = Itch.pad_stock "QQQ"

let samples : Itch.t list =
  [ { header = hdr
    ; body =
        Stock_directory { stock; rest = "QNZ 100N  0000000000" |> String.sub ~pos:0 ~len:20 }
    }
  ; { header = hdr
    ; body =
        Add_order
          { order_ref = 123456789; side = Buy; shares = 100; stock; price = 1_912_300; mpid = None }
    }
  ; { header = hdr
    ; body =
        Add_order
          { order_ref = 42; side = Sell; shares = 5; stock; price = 1_912_400; mpid = Some "GSCO" }
    }
  ; { header = hdr; body = Order_executed { order_ref = 42; shares = 3; match_number = 99 } }
  ; { header = hdr
    ; body =
        Order_executed_with_price
          { order_ref = 42; shares = 1; match_number = 100; printable = true; price = 1_912_350 }
    }
  ; { header = hdr; body = Order_cancel { order_ref = 42; shares = 1 } }
  ; { header = hdr; body = Order_delete { order_ref = 42 } }
  ; { header = hdr
    ; body = Order_replace { orig_ref = 42; new_ref = 43; shares = 200; price = 1_912_200 }
    }
  ; { header = hdr; body = Other { typ = 'S'; payload = "O" } }
  ]
;;

let%expect_test "encode/decode round trip, every decoded type" =
  List.iter samples ~f:(fun m ->
    let s = Itch.to_string m in
    let m' = Itch.of_string s in
    printf "%c len=%2d roundtrip=%b\n" (Itch.typ m) (String.length s) (Itch.equal m m'));
  [%expect
    {|
    R len=39 roundtrip=true
    A len=36 roundtrip=true
    F len=40 roundtrip=true
    E len=31 roundtrip=true
    C len=36 roundtrip=true
    X len=23 roundtrip=true
    D len=19 roundtrip=true
    U len=35 roundtrip=true
    S len=12 roundtrip=true
    |}]
;;

let%expect_test "wire layout of an Add Order (big endian, offsets per the spec)" =
  let s = Itch.to_string (List.nth_exn samples 1) in
  String.iteri s ~f:(fun i c ->
    printf "%02x%s" (Char.to_int c) (if i % 12 = 11 then "\n" else " "));
  [%expect {|
    41 00 07 00 02 1f 1a ce d9 f0 7b 00
    00 00 00 07 5b cd 15 42 00 00 00 64
    51 51 51 20 20 20 20 20 00 1d 2d ec
    |}]
;;

let%expect_test "length and field validation" =
  let try_ s =
    match Itch.of_string s with
    | _ -> print_endline "ok"
    | exception Itch.Decode_error e -> print_endline e
  in
  try_ "D";
  try_ (String.make 19 'Z');
  let add = Itch.to_string (List.nth_exn samples 1) in
  try_ (String.sub add ~pos:0 ~len:35);
  let bad_side = Bytes.of_string add in
  Bytes.set bad_side 19 'Q';
  try_ (Bytes.to_string bad_side);
  let big_ref = Bytes.of_string add in
  Bytes.set big_ref 11 '\x80';
  try_ (Bytes.to_string big_ref);
  [%expect
    {|
    type 'D': length 1, expected 19
    unknown message type 'Z'
    type 'A': length 35, expected 36
    bad side 'Q'
    u64 at 11 has its top bit set
    |}]
;;

let%expect_test "price formatting" =
  List.iter [ 0; 1; 1_912_300; 1_999_999_900 ] ~f:(fun p ->
    print_endline (Itch.price_to_string p));
  [%expect
    {|
    0.0000
    0.0001
    191.2300
    199999.9900
    |}]
;;

(* On real data: every message decodes and re-encodes to the same bytes. *)
let%expect_test "real sample: decode/encode is the identity on 1M messages" =
  (match Lazy.force Sample_data.file with
   | None -> ()
   | Some file ->
     let bad = ref 0 in
     let n =
       Itch.File.iter_raw ~max_messages:1_000_000 file ~f:(fun raw ->
         if not (String.equal raw (Itch.to_string (Itch.of_string raw))) then incr bad)
     in
     if n <> 1_000_000 || !bad <> 0 then printf "FAILED: %d messages, %d mismatches\n" n !bad);
  [%expect {| |}]
;;
