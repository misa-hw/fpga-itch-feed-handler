(* Command line tool around the reference model.

     itch_tool stats FILE                 message-type counts
     itch_tool activity FILE              busiest symbols (order messages)
     itch_tool profile FILE [-symbols ..] sizes the hardware: peak live orders,
                                          price levels, prices per tick, ...
     itch_tool book FILE [-symbols ..]    replay; print every top-of-book change *)

open! Core
open Itch_model

let file_arg = Command.Param.(anon ("FILE" %: Filename_unix.arg_type))

let max_arg =
  Command.Param.(
    flag "-max" (optional int) ~doc:"N stop after N messages (default: whole file)")
;;

let default_symbols = [ "QQQ"; "SPY"; "IWM"; "DIA"; "TQQQ"; "SQQQ"; "AMD"; "UVXY" ]

let symbols_arg =
  Command.Param.(
    flag
      "-symbols"
      (optional_with_default default_symbols (Arg_type.comma_separated string))
      ~doc:(sprintf "SYM,.. symbols to track (default %s)" (String.concat ~sep:"," default_symbols)))
;;

let stats =
  Command.basic
    ~summary:"count messages by type"
    (let%map_open.Command file = file_arg
     and max_messages = max_arg in
     fun () ->
       let counts = Hashtbl.create (module Char) in
       let n =
         Itch.File.iter_raw ?max_messages file ~f:(fun raw ->
           Hashtbl.incr counts raw.[0])
       in
       printf "%d messages\n" n;
       Hashtbl.to_alist counts
       |> List.sort ~compare:(fun (_, a) (_, b) -> Int.compare b a)
       |> List.iter ~f:(fun (c, k) -> printf "  %c %10d\n" c k))
;;

let activity =
  Command.basic
    ~summary:"busiest symbols by number of order messages"
    (let%map_open.Command file = file_arg
     and max_messages = max_arg in
     fun () ->
       let name = Hashtbl.create (module Int) in
       let count = Hashtbl.create (module Int) in
       ignore
         (Itch.File.iter ?max_messages file ~f:(fun m ->
            match m.body with
            | Stock_directory { stock; _ } ->
              Hashtbl.set name ~key:m.header.locate ~data:(String.rstrip stock)
            | Add_order _ | Order_executed _ | Order_executed_with_price _ | Order_cancel _
            | Order_delete _ | Order_replace _ -> Hashtbl.incr count m.header.locate
            | Other _ -> ())
          : int);
       Hashtbl.to_alist count
       |> List.sort ~compare:(fun (_, a) (_, b) -> Int.compare b a)
       |> (fun l -> List.take l 30)
       |> List.iter ~f:(fun (loc, k) ->
         printf
           "  %-8s locate=%5d %9d\n"
           (Hashtbl.find name loc |> Option.value ~default:"?")
           loc
           k))
;;

let profile =
  Command.basic
    ~summary:"measure what the hardware must hold for the chosen symbols"
    (let%map_open.Command file = file_arg
     and max_messages = max_arg
     and symbols = symbols_arg in
     fun () ->
       let book = Book.create symbols in
       let peak_orders = ref 0 in
       let nsym = List.length symbols in
       let peak_levels = Array.init nsym ~f:(fun _ -> [| 0; 0 |]) in
       let min_price = Array.create ~len:nsym Int.max_value in
       let max_price = Array.create ~len:nsym 0 in
       let sub_penny = ref 0 in
       let adds = ref 0 in
       let msgs_tracked = ref 0 in
       let events = ref 0 in
       let max_shares = ref 0 in
       let n =
         Itch.File.iter ?max_messages file ~f:(fun m ->
           let slot = Book.slot_of_locate book m.header.locate in
           (match m.body, slot with
            | (Add_order { price; shares; _ } | Order_replace { price; shares; _ }), Some s ->
              incr adds;
              if price mod 100 <> 0 then incr sub_penny;
              max_shares := Int.max !max_shares shares;
              min_price.(s) <- Int.min min_price.(s) price;
              max_price.(s) <- Int.max max_price.(s) price
            | _ -> ());
           if Option.is_some slot then incr msgs_tracked;
           if Option.is_some (Book.apply book m) then incr events;
           peak_orders := Int.max !peak_orders (Book.num_live_orders book);
           Option.iter slot ~f:(fun s ->
             peak_levels.(s).(0) <- Int.max peak_levels.(s).(0) (Book.num_levels book s Buy);
             peak_levels.(s).(1) <- Int.max peak_levels.(s).(1) (Book.num_levels book s Sell)))
       in
       printf "messages: %d, for tracked symbols: %d, top-of-book events: %d\n" n !msgs_tracked !events;
       printf "peak live orders (all tracked symbols): %d\n" !peak_orders;
       printf "live orders at end: %d\n" (Book.num_live_orders book);
       printf "adds+replaces: %d, sub-penny prices: %d, max shares: %d\n" !adds !sub_penny !max_shares;
       printf "anomalies: %d\n" (Book.anomalies book);
       List.iteri symbols ~f:(fun s sym ->
         printf
           "  %-5s peak levels bid=%4d ask=%4d  price range %s .. %s\n"
           sym
           peak_levels.(s).(0)
           peak_levels.(s).(1)
           (Itch.price_to_string min_price.(s))
           (Itch.price_to_string max_price.(s))))
;;

let book =
  Command.basic
    ~summary:"replay and print every top-of-book change"
    (let%map_open.Command file = file_arg
     and max_messages = max_arg
     and symbols = symbols_arg in
     fun () ->
       let book = Book.create symbols in
       let i = ref 0 in
       ignore
         (Itch.File.iter ?max_messages file ~f:(fun m ->
            incr i;
            Option.iter (Book.apply book m) ~f:(fun tob ->
              printf "%d %s\n" (!i - 1) (Book.Tob.to_string tob)))
          : int))
;;

let () =
  Command_unix.run
    (Command.group
       ~summary:"Nasdaq ITCH 5.0 reference model"
       [ "stats", stats; "activity", activity; "profile", profile; "book", book ])
;;
