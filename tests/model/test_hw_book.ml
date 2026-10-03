open! Core
open Itch_model

(* Tiny tables and a 2-entry cache, so that the rare paths of the hardware
   architecture (cuckoo displacement, cache refills from the level table,
   cache insertions below a full cache) happen all the time. *)
let tiny =
  { Hw_book.default_params with
    order_bucket_bits = 2
  ; level_bucket_bits = 3
  ; cache_k = 2
  ; level_window_shift = 0
  }
;;

let%expect_test "property: the hardware architecture model equals the reference book" =
  let totals = Hw_book.create ~p:tiny [ "QQQ" ] |> Hw_book.stats in
  Quickcheck.test
    ~trials:1000
    ~sexp_of:(List.sexp_of_t Itch.sexp_of_t)
    Gen.random_messages
    ~f:(fun msgs ->
      let book = Book.create [ "QQQ"; "SPY" ] in
      let hw = Hw_book.create ~p:tiny [ "QQQ"; "SPY" ] in
      List.iter msgs ~f:(fun m ->
        let want = Book.apply book m in
        let got = Hw_book.apply hw m in
        let s = Hw_book.stats hw in
        (* equality is only promised while nothing has overflowed *)
        if s.order_overflows = 0 && s.level_overflows = 0
        then [%test_result: Book.Tob.t option] got ~expect:want);
      let s = Hw_book.stats hw in
      totals.kicks <- totals.kicks + s.kicks;
      totals.refills <- totals.refills + s.refills;
      totals.order_overflows <- totals.order_overflows + s.order_overflows;
      totals.level_overflows <- totals.level_overflows + s.level_overflows;
      totals.max_kicks_seen <- Int.max totals.max_kicks_seen s.max_kicks_seen);
  (* the interesting paths were exercised *)
  printf
    "kicks>0: %b, refills>0: %b, max kicks per insert: %d, overflows: %d/%d\n"
    (totals.kicks > 0)
    (totals.refills > 0)
    totals.max_kicks_seen
    totals.order_overflows
    totals.level_overflows;
  [%expect {| kicks>0: true, refills>0: true, max kicks per insert: 2, overflows: 0/0 |}]
;;

let%expect_test "H3 hash: index bits are balanced over sequential references" =
  let masks = Hw_book.h3_masks ~key_bits:32 ~out_bits:12 ~bank:0 in
  let counts = Array.create ~len:4096 0 in
  for r = 1_000_000 to 1_000_000 + (4096 * 16) - 1 do
    let b = Hw_book.h3 masks r in
    counts.(b) <- counts.(b) + 1
  done;
  printf
    "min %d max %d (ideal 16)\n"
    (Array.fold counts ~init:Int.max_value ~f:Int.min)
    (Array.fold counts ~init:0 ~f:Int.max);
  [%expect {| min 15 max 17 (ideal 16) |}]
;;
