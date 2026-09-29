open! Core
open! Hardcaml
open! Hardcaml_waveterm
open Itch_model
open Itch_model.Gen

let ( $ ) dollars cents = (dollars * 10_000) + (cents * 100)

(* Every command produces an event; check it against the architecture model
   (same parameters) and return a description. *)
let check_against_model (sim : Book_sim.t) hw msgs =
  List.filter_map msgs ~f:(fun m ->
    let want = Hw_book.apply hw m in
    Option.map (Book_sim.send sim m) ~f:(fun seq -> seq, m, want))
;;

let%expect_test "directed: aggregation, partial fills, best level empties, replace" =
  let _, sim = Book_sim.create [ "QQQ"; "SPY" ] in
  let msgs =
    [ dir 1 "QQQ"
    ; add 1 Buy 100 (190 $ 10)
    ; add 2 Buy 50 (190 $ 12)
    ; add 3 Buy 70 (190 $ 12)
    ; add 4 Sell 30 (190 $ 20)
    ; exec 2 20
    ; exec_px 2 30 (190 $ 11)
    ; cancel 3 60
    ; delete 3
    ; replace 4 5 10 (190 $ 15)
    ; delete 1
    ; delete 99
    ]
  in
  List.iter msgs ~f:(fun m -> ignore (Book_sim.send sim m : int option));
  Book_sim.wait_events sim 11;
  Queue.iter sim.events ~f:(fun e ->
    printf "seq %2d %s %s\n" e.seq (if e.changed then "CHANGED" else "       ") (Book.Tob.to_string e.tob));
  [%expect {|
    seq  2 CHANGED slot=0 bid=100@190.1000 ask=0@0.0000
    seq  3 CHANGED slot=0 bid=50@190.1200 ask=0@0.0000
    seq  4 CHANGED slot=0 bid=120@190.1200 ask=0@0.0000
    seq  5 CHANGED slot=0 bid=120@190.1200 ask=30@190.2000
    seq  6 CHANGED slot=0 bid=100@190.1200 ask=30@190.2000
    seq  7 CHANGED slot=0 bid=70@190.1200 ask=30@190.2000
    seq  8 CHANGED slot=0 bid=10@190.1200 ask=30@190.2000
    seq  9 CHANGED slot=0 bid=100@190.1000 ask=30@190.2000
    seq 10 CHANGED slot=0 bid=100@190.1000 ask=10@190.1500
    seq 11 CHANGED slot=0 bid=0@0.0000 ask=10@190.1500
    seq 12         slot=0 bid=0@0.0000 ask=10@190.1500
    |}]
;;

let%expect_test "waveform: add a bid, then a better one, then delete it" =
  let waves, sim = Book_sim.create ~waves:true [ "QQQ" ] in
  List.iter
    [ dir 1 "QQQ"; add 1 Buy 100 (190 $ 10); add 2 Buy 50 (190 $ 12); delete 2 ]
    ~f:(fun m -> ignore (Book_sim.send sim m : int option));
  Book_sim.wait_events sim 3;
  for _ = 1 to 3 do
    Book_sim.cycle sim
  done;
  Waveform.print
    (Option.value_exn waves)
    ~display_rules:
      Display_rule.
        [ port_name_is "cmd_valid"
        ; port_name_is "cmd_kind" ~wave_format:Unsigned_int
        ; port_name_is "event_valid"
        ; port_name_is "event_changed"
        ; port_name_is "event_seq" ~wave_format:Unsigned_int
        ; port_name_is "event_bid_price" ~wave_format:Unsigned_int
        ; port_name_is "event_bid_shares" ~wave_format:Unsigned_int
        ]
    ~display_width:110
    ~display_height:24
    ~wave_width:0;
  [%expect {|
    ┌Signals───────────┐┌Waves───────────────────────────────────────────────────────────────────────────────────┐
    │cmd_valid         ││──────┐                                                                                 │
    │                  ││      └─────────────────────────────────────────────────────────────────────────        │
    │                  ││────┬───────────────────────────────────────────────────────────────────────────        │
    │cmd_kind          ││ 1  │5                                                                                  │
    │                  ││────┴───────────────────────────────────────────────────────────────────────────        │
    │event_valid       ││                        ┌─┐                   ┌─┐                         ┌─┐           │
    │                  ││────────────────────────┘ └───────────────────┘ └─────────────────────────┘ └───        │
    │event_changed     ││                        ┌───────────────────────────────────────────────────────        │
    │                  ││────────────────────────┘                                                               │
    │                  ││────────────────────────┬─────────────────────┬───────────────────────────┬─────        │
    │event_seq         ││ 0                      │2                    │3                          │4            │
    │                  ││────────────────────────┴─────────────────────┴───────────────────────────┴─────        │
    │                  ││────────────────────────┬─────────────────────┬───────────────────────────┬─────        │
    │event_bid_price   ││ 0                      │1901000              │1901200                    │1901.        │
    │                  ││────────────────────────┴─────────────────────┴───────────────────────────┴─────        │
    │                  ││────────────────────────┬─────────────────────┬───────────────────────────┬─────        │
    │event_bid_shares  ││ 0                      │100                  │50                         │100          │
    │                  ││────────────────────────┴─────────────────────┴───────────────────────────┴─────        │
    │                  ││                                                                                        │
    │                  ││                                                                                        │
    │                  ││                                                                                        │
    │                  ││                                                                                        │
    └──────────────────┘└────────────────────────────────────────────────────────────────────────────────────────┘
    |}]
;;

(* Tiny tables, a 2-entry cache and back-to-back commands: kicks, refills
   and FIFO queueing on almost every sequence. The RTL must equal the model
   event for event, and its internal counters must equal the model's. *)
let tiny = { Hw_book.default_params with order_bucket_bits = 2; level_bucket_bits = 3; cache_k = 2 }

let%expect_test "property: RTL == architecture model (tiny tables), incl. internal counters" =
  let totals = ref (0, 0) in
  Quickcheck.test
    ~trials:150
    ~sexp_of:(List.sexp_of_t Itch.sexp_of_t)
    Gen.random_messages
    ~f:(fun msgs ->
      let _, sim = Book_sim.create ~p:tiny [ "QQQ"; "SPY" ] in
      let hw = Hw_book.create ~p:tiny [ "QQQ"; "SPY" ] in
      let expected = check_against_model sim hw msgs in
      Book_sim.wait_events sim (List.length expected);
      [%test_result: int] (Queue.length sim.events) ~expect:(List.length expected);
      List.iter2_exn (Queue.to_list sim.events) expected ~f:(fun e (seq, m, want) ->
        [%test_result: int] e.seq ~expect:seq;
        [%test_result: bool] e.changed ~expect:(Option.is_some want);
        let slot = e.tob.slot in
        ignore m;
        (* after the command, the RTL's TOB must be the model's TOB *)
        if e.changed then [%test_result: Book.Tob.t] e.tob ~expect:(Option.value_exn want)
        else ignore slot);
      let processed, kicks, max_kicks, refills, refill_levels, oovf, lovf, orders, levels, _, _ =
        Book_sim.stats sim
      in
      let s = Hw_book.stats hw in
      [%test_result: int] processed ~expect:(List.length expected);
      [%test_result: int list]
        [ kicks; max_kicks; refills; refill_levels; oovf; lovf; orders; levels ]
        ~expect:
          [ s.kicks
          ; s.max_kicks_seen
          ; s.refills
          ; s.refill_levels_found
          ; s.order_overflows
          ; s.level_overflows
          ; s.orders
          ; s.levels
          ];
      let k, r = !totals in
      totals := k + kicks, r + refills);
  let k, r = !totals in
  printf "kicks exercised: %b, refills exercised: %b\n" (k > 0) (r > 0);
  [%expect {| kicks exercised: true, refills exercised: true |}]
;;

(* Real data, full-size tables, against the reference book. *)
let%expect_test "real sample: RTL == reference book on the first 1M messages" =
  (match Lazy.force Sample_data.itch with
   | None -> ()
   | Some file ->
     let symbols = [ "QQQ"; "SPY"; "IWM"; "DIA"; "TQQQ"; "SQQQ"; "AMD"; "UVXY" ] in
     let _, sim = Book_sim.create symbols in
     let book = Book.create symbols and hw = Hw_book.create symbols in
     let expected = Queue.create () in
     let _ =
       Itch.File.iter ~max_messages:1_000_000 file ~f:(fun m ->
         let want = Book.apply book m in
         ignore (Hw_book.apply hw m : Book.Tob.t option);
         match Book_sim.send sim m ~gap:8 with
         | None -> ()
         | Some seq -> Queue.enqueue expected (seq, want))
     in
     Book_sim.wait_events sim (Queue.length expected);
     let bad = ref 0 and changes = ref 0 in
     List.iter2_exn (Queue.to_list sim.events) (Queue.to_list expected) ~f:(fun e (seq, want) ->
       if e.changed then incr changes;
       let ok =
         e.seq = seq
         && Bool.equal e.changed (Option.is_some want)
         && ((not e.changed) || Book.Tob.equal e.tob (Option.value_exn want))
       in
       if not ok then incr bad);
     let processed, kicks, _, refills, _, oovf, lovf, orders, levels, fifo_ovf, _ = Book_sim.stats sim in
     let s = Hw_book.stats hw in
     if !bad > 0
        || oovf + lovf + fifo_ovf > 0
        || processed < 20_000
        || kicks <> s.kicks
        || refills <> s.refills
        || orders <> s.orders
        || levels <> s.levels
     then
       printf
         "FAILED: %d mismatches, %d commands, %d changes, kicks %d/%d refills %d/%d\n"
         !bad
         processed
         !changes
         kicks
         s.kicks
         refills
         s.refills);
  [%expect {| |}]
;;
