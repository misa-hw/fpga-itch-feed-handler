(* Message builders and a random message-sequence generator, shared by the
   model tests and the hardware tests. *)
open! Core

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

(* Several [random_messages] batches in one feed: each batch uses order
   references 1..40, unique only within itself, so batch [index] gets its
   own range (a live reference added again is outside ITCH's rules, and the
   hardware and reference books may treat it differently), and ends by
   deleting all of its orders, so every batch starts from empty books. Each
   delete carries its order's locate, as on a real feed: the books disagree
   on a delete that names another stock. *)
let batch ~index messages =
  let by = 1000 * index in
  let shift (m : Itch.t) =
    let body : Itch.body =
      match m.body with
      | Add_order a -> Add_order { a with order_ref = a.order_ref + by }
      | Order_executed e -> Order_executed { e with order_ref = e.order_ref + by }
      | Order_executed_with_price e -> Order_executed_with_price { e with order_ref = e.order_ref + by }
      | Order_cancel c -> Order_cancel { c with order_ref = c.order_ref + by }
      | Order_delete d -> Order_delete { order_ref = d.order_ref + by }
      | Order_replace r -> Order_replace { r with orig_ref = r.orig_ref + by; new_ref = r.new_ref + by }
      | (Stock_directory _ | Other _) as b -> b
    in
    { m with body }
  in
  let shifted = List.map messages ~f:shift in
  (* each reference's locate when last added, in order of first addition *)
  let locate = Hashtbl.create (module Int) and refs = Queue.create () in
  List.iter shifted ~f:(fun (m : Itch.t) ->
    let added r =
      if not (Hashtbl.mem locate r) then Queue.enqueue refs r;
      Hashtbl.set locate ~key:r ~data:m.header.locate
    in
    match m.body with
    | Add_order a -> added a.order_ref
    | Order_replace r -> added r.new_ref
    | _ -> ());
  shifted
  @ List.map (Queue.to_list refs) ~f:(fun r -> delete ~loc:(Hashtbl.find_exn locate r) r)
;;
