open! Core
open Itch_model

(* Tiny DSL for building message sequences. Locate 1 = QQQ (tracked, slot 0),
   2 = SPY (tracked, slot 1), 3 = XYZ (not tracked). *)
let ts = ref 0

let msg locate body =
  incr ts;
  { Itch.header = { locate; tracking = 0; timestamp = !ts }; body }
;;

let dir locate sym =
  msg locate (Stock_directory { stock = Itch.pad_stock sym; rest = String.make 20 ' ' })
;;

let add ?(loc = 1) ?mpid r side shares price =
  msg
    loc
    (Add_order
       { order_ref = r; side; shares; stock = Itch.pad_stock "QQQ"; price; mpid })
;;

let exec ?(loc = 1) r shares = msg loc (Order_executed { order_ref = r; shares; match_number = r })

let exec_px ?(loc = 1) r shares price =
  msg
    loc
    (Order_executed_with_price
       { order_ref = r; shares; match_number = r; printable = true; price })
;;

let cancel ?(loc = 1) r shares = msg loc (Order_cancel { order_ref = r; shares })
let delete ?(loc = 1) r = msg loc (Order_delete { order_ref = r })

let replace ?(loc = 1) orig_ref new_ref shares price =
  msg loc (Order_replace { orig_ref; new_ref; shares; price })
;;

let run msgs =
  let book = Book.create [ "QQQ"; "SPY" ] in
  List.iter msgs ~f:(fun m ->
    let out =
      match Book.apply book m with
      | None -> "-"
      | Some tob -> Book.Tob.to_string tob
    in
    printf "%c %s\n" (Itch.typ m) out);
  book
;;

let ( $ ) dollars cents = (dollars * 10_000) + (cents * 100)

let%expect_test "basic adds, aggregation and best selection" =
  let _ =
    run
      [ dir 1 "QQQ"
      ; dir 2 "SPY"
      ; add 1 Buy 100 (190 $ 10)
      ; add 2 Buy 50 (190 $ 12) (* better bid *)
      ; add 3 Buy 70 (190 $ 12) (* same level: aggregated *)
      ; add 4 Buy 10 (189 $ 00) (* worse: TOB unchanged *)
      ; add ~mpid:"GSCO" 5 Sell 30 (190 $ 20)
      ; add ~loc:2 6 Sell 5 (300 $ 00) (* other symbol *)
      ]
  in
  [%expect
    {|
    R -
    R -
    A slot=0 bid=100@190.1000 ask=0@0.0000
    A slot=0 bid=50@190.1200 ask=0@0.0000
    A slot=0 bid=120@190.1200 ask=0@0.0000
    A -
    F slot=0 bid=120@190.1200 ask=30@190.2000
    A slot=1 bid=0@0.0000 ask=5@300.0000
    |}]
;;

let%expect_test "executions, cancels and deletes; best level empties" =
  let book =
    run
      [ dir 1 "QQQ"
      ; add 1 Buy 100 (190 $ 10)
      ; add 2 Buy 50 (190 $ 12)
      ; add 3 Buy 70 (190 $ 12)
      ; exec 2 20 (* partial *)
      ; exec_px 2 30 (190 $ 11) (* completes order 2; price is the print, not the level *)
      ; cancel 3 60
      ; delete 3 (* best level empties -> falls back to 190.10 *)
      ; delete 1 (* side empties *)
      ; delete 1 (* already gone: ignored *)
      ]
  in
  printf "live orders %d, anomalies %d\n" (Book.num_live_orders book) (Book.anomalies book);
  [%expect
    {|
    R -
    A slot=0 bid=100@190.1000 ask=0@0.0000
    A slot=0 bid=50@190.1200 ask=0@0.0000
    A slot=0 bid=120@190.1200 ask=0@0.0000
    E slot=0 bid=100@190.1200 ask=0@0.0000
    C slot=0 bid=70@190.1200 ask=0@0.0000
    X slot=0 bid=10@190.1200 ask=0@0.0000
    D slot=0 bid=100@190.1000 ask=0@0.0000
    D slot=0 bid=0@0.0000 ask=0@0.0000
    D -
    live orders 0, anomalies 0
    |}]
;;

let%expect_test "replace keeps side, moves price, takes a new reference" =
  let book =
    run
      [ dir 1 "QQQ"
      ; add 1 Sell 100 (190 $ 20)
      ; add 2 Sell 40 (190 $ 25)
      ; replace 1 10 80 (190 $ 30) (* best ask moves away: next best is 190.25 *)
      ; replace 2 11 40 (190 $ 18) (* and back in front *)
      ; exec 10 80
      ; cancel 1 5 (* old reference is dead *)
      ]
  in
  printf "live orders %d\n" (Book.num_live_orders book);
  [%expect
    {|
    R -
    A slot=0 bid=0@0.0000 ask=100@190.2000
    A -
    U slot=0 bid=0@0.0000 ask=40@190.2500
    U slot=0 bid=0@0.0000 ask=40@190.1800
    E -
    X -
    live orders 1
    |}]
;;

let%expect_test "untracked symbols and messages before the directory are ignored" =
  let book =
    run
      [ add 1 Buy 100 (10 $ 0) (* locate 1 not yet mapped *)
      ; dir 1 "QQQ"
      ; dir 3 "XYZ"
      ; add ~loc:3 2 Buy 100 (10 $ 0)
      ; exec ~loc:3 2 100
      ; exec 1 100 (* order 1 was never stored *)
      ]
  in
  printf "live orders %d\n" (Book.num_live_orders book);
  [%expect
    {|
    A -
    R -
    R -
    A -
    E -
    E -
    live orders 0
    |}]
;;

(* ---- property test against a deliberately naive model ----

   The naive model keeps a plain list of live orders and recomputes the best
   bid/ask by scanning it after every message. Random message sequences use a
   small price range and a small set of references so that levels are shared,
   emptied, refilled, and references are reused after deletion. *)
module Naive = struct
  type o =
    { r : int
    ; slot : int
    ; side : Itch.side
    ; price : int
    ; shares : int
    }

  let apply (orders : o list) slot_of_loc (m : Itch.t) =
    let find r = List.find orders ~f:(fun o -> o.r = r) in
    let without r = List.filter orders ~f:(fun o -> o.r <> r) in
    let reduce r n =
      match find r with
      | None -> orders
      | Some o ->
        let left = o.shares - Int.min n o.shares in
        if left = 0 then without r else { o with shares = left } :: without r
    in
    match slot_of_loc m.header.locate with
    | None -> orders
    | Some slot ->
      (match m.body with
       | Add_order { order_ref; side; shares; price; _ } ->
         { r = order_ref; slot; side; price; shares } :: orders
       | Order_executed { order_ref; shares; _ }
       | Order_executed_with_price { order_ref; shares; _ }
       | Order_cancel { order_ref; shares } -> reduce order_ref shares
       | Order_delete { order_ref } -> without order_ref
       | Order_replace { orig_ref; new_ref; shares; price } ->
         (match find orig_ref with
          | None -> orders
          | Some o -> { o with r = new_ref; shares; price } :: without orig_ref)
       | Stock_directory _ | Other _ -> orders)
  ;;

  let tob orders slot : Book.Tob.t =
    let side s =
      List.filter orders ~f:(fun o -> o.slot = slot && Itch.equal_side o.side s)
    in
    let best s pick =
      match side s with
      | [] -> 0, 0
      | l ->
        let p = List.map l ~f:(fun o -> o.price) |> List.reduce_exn ~f:pick in
        ( p
        , List.sum (module Int) l ~f:(fun o -> if o.price = p then o.shares else 0) )
    in
    let bid_price, bid_shares = best Buy Int.max in
    let ask_price, ask_shares = best Sell Int.min in
    { slot; bid_price; bid_shares; ask_price; ask_shares }
  ;;
end

let random_messages =
  let open Quickcheck.Generator.Let_syntax in
  (* [live] maps reference -> (locate, remaining shares); like the real feed,
     messages for an order carry its locate, reductions never exceed what is
     left, and a live reference is never reused. References of dead orders are
     reused freely, and some messages name references that do not exist. *)
  let rec go n live acc =
    if n = 0
    then return (List.rev acc)
    else (
      let%bind loc = Int.gen_incl 1 3 in
      let%bind r = Int.gen_incl 1 40 in
      let%bind shares = Int.gen_incl 1 300 in
      let%bind price = Int.gen_incl 100 110 >>| fun p -> p * 100 in
      let%bind side = Quickcheck.Generator.of_list [ Itch.Buy; Sell ] in
      let%bind kind = Int.gen_incl 0 9 in
      let%bind target =
        if Map.is_empty live || kind < 3
        then return None
        else Quickcheck.Generator.of_list (Map.to_alist live) >>| Option.some
      in
      let%bind part = Int.gen_incl 1 300 in
      let fresh = not (Map.mem live r) in
      let m, live =
        match kind, target with
        | (0 | 1 | 2), _ when fresh -> Some (add ~loc r side shares price), Map.set live ~key:r ~data:(loc, shares)
        | (0 | 1 | 2), _ -> None, live
        | _, None -> Some (delete ~loc r), live
        | k, Some (t, (tloc, left)) ->
          let n = 1 + (part % left) in
          let reduced = if n = left then Map.remove live t else Map.set live ~key:t ~data:(tloc, left - n) in
          (match k with
           | 3 -> Some (exec ~loc:tloc t n), reduced
           | 4 -> Some (exec_px ~loc:tloc t n price), reduced
           | 5 -> Some (cancel ~loc:tloc t n), reduced
           | 6 | 7 -> Some (delete ~loc:tloc t), Map.remove live t
           | _ when fresh -> Some (replace ~loc:tloc t r shares price), Map.set (Map.remove live t) ~key:r ~data:(tloc, shares)
           | _ -> None, live)
      in
      go (n - 1) live (Option.to_list m @ acc))
  in
  go 200 Int.Map.empty [ dir 1 "QQQ"; dir 2 "SPY" ]
;;

let%expect_test "property: after every message the book matches the naive model" =
  Quickcheck.test
    ~trials:500
    ~sexp_of:(List.sexp_of_t Itch.sexp_of_t)
    random_messages
    ~f:(fun msgs ->
      let book = Book.create [ "QQQ"; "SPY" ] in
      let slot_of_loc = function
        | 1 -> Some 0
        | 2 -> Some 1
        | _ -> None
      in
      let naive = ref [] in
      let last = Array.init 2 ~f:(fun slot -> Naive.tob [] slot) in
      List.iter msgs ~f:(fun m ->
        let event = Book.apply book m in
        naive := Naive.apply !naive slot_of_loc m;
        for slot = 0 to 1 do
          let expect = Naive.tob !naive slot in
          [%test_result: Book.Tob.t] (Book.tob book slot) ~expect;
          (* an event is produced exactly when the TOB changed *)
          let changed = not (Book.Tob.equal expect last.(slot)) in
          let got =
            Option.value_map event ~default:false ~f:(fun (e : Book.Tob.t) -> e.slot = slot)
          in
          [%test_result: bool] got ~expect:changed;
          last.(slot) <- expect
        done);
      [%test_result: int] (Book.anomalies book) ~expect:0);
  [%expect {| |}]
;;

(* On real data: aggregate level shares equal the sum of live order shares,
   and no anomalies (over-executions, duplicate references) are seen. *)
let%expect_test "real sample: invariants over 2M messages" =
  (match Lazy.force Sample_data.file with
   | None -> ()
   | Some file ->
     let book = Book.create [ "QQQ"; "SPY"; "IWM"; "AMD" ] in
     let events = ref 0 in
     let _ =
       Itch.File.iter ~max_messages:2_000_000 file ~f:(fun m ->
         if Option.is_some (Book.apply book m) then incr events)
     in
     let order_sum = Hashtbl.create (module String) in
     Hashtbl.iter book.orders ~f:(fun (o : Book.order) ->
       Hashtbl.update
         order_sum
         (sprintf "%d%c" o.slot (Itch.side_to_char o.side))
         ~f:(fun v -> Option.value v ~default:0 + o.shares));
     for slot = 0 to 3 do
       List.iter [ Itch.Buy; Sell ] ~f:(fun side ->
         let lv = Map.data (Book.levels book slot side) |> List.sum (module Int) ~f:Fn.id in
         let os =
           Hashtbl.find order_sum (sprintf "%d%c" slot (Itch.side_to_char side))
           |> Option.value ~default:0
         in
         if lv <> os then printf "slot %d: levels %d <> orders %d\n" slot lv os)
     done;
     if Book.anomalies book <> 0 then printf "anomalies: %d\n" (Book.anomalies book);
     if !events < 1000 then printf "suspiciously few events: %d\n" !events);
  [%expect {| |}]
;;
