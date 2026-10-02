(* ITCH file -> MoldUDP64/UDP/IPv4/Ethernet frames in a .pcap, and back.

     pcapgen gen ITCH_FILE -o OUT.pcap [-max N] [-only SYM,..] [-window-ns NS]
     pcapgen check OUT.pcap [-itch ITCH_FILE]   parse every frame (checksums,
                                                lengths, sequence numbers) and
                                                optionally compare the messages
                                                with the source file *)

open! Core
open Itch_model
open Net

(* 2019-07-30 00:00:00 UTC, to give the pcap real calendar timestamps *)
let day_epoch_ns = 1_564_444_800 * 1_000_000_000

(* Messages kept by [-only]: directory messages for every stock plus all
   messages whose locate belongs to one of the listed symbols. *)
let filter_of_symbols ?(strict = false) = function
  | None -> fun (_ : string) -> true
  | Some symbols ->
    let wanted = List.map symbols ~f:Itch.pad_stock in
    let locates = Hash_set.create (module Int) in
    fun raw ->
      let locate = Itch.be raw ~pos:1 ~len:2 in
      if Char.equal raw.[0] 'R'
      then (
        if List.mem wanted (String.sub raw ~pos:11 ~len:8) ~equal:String.equal
        then (
          Hash_set.add locates locate;
          true)
        else not strict)
      else Hash_set.mem locates locate
;;

let gen =
  Command.basic
    ~summary:"wrap ITCH messages into MoldUDP64 packets in a pcap"
    (let%map_open.Command itch = anon ("ITCH_FILE" %: Filename_unix.arg_type)
     and out = flag "-o" (required string) ~doc:"FILE output pcap"
     and max_messages = flag "-max" (optional int) ~doc:"N use the first N messages of the file"
     and only =
       flag
         "-only"
         (optional (Arg_type.comma_separated string))
         ~doc:"SYM,.. keep only these symbols' messages (plus all directory messages)"
     and strict =
       flag "-strict" no_arg ~doc:" with -only: drop directory messages of other symbols too"
     and window_ns =
       flag "-window-ns" (optional_with_default 1000 int) ~doc:"NS batching window (default 1000)"
     in
     fun () ->
       let w = Pcap.Writer.create out in
       let ep = Packet.default_endpoints in
       let packets = ref 0 and bytes = ref 0 in
       let emit ~ts_ns mold =
         let f = Packet.frame ~ip_id:!packets ep (Packet.Mold.to_string mold) in
         incr packets;
         bytes := !bytes + String.length f;
         Pcap.Writer.write w ~ts_ns:(day_epoch_ns + ts_ns) f
       in
       let p = Packet.Packetizer.create ~window_ns ~emit () in
       let keep = filter_of_symbols ~strict only in
       let last_ts = ref 0 in
       let kept = ref 0 in
       let n =
         Itch.File.iter_raw ?max_messages itch ~f:(fun raw ->
           if keep raw
           then (
             incr kept;
             let ts_ns = Itch.be raw ~pos:5 ~len:6 in
             last_ts := ts_ns;
             Packet.Packetizer.add p ~ts_ns raw))
       in
       Packet.Packetizer.finish p ~ts_ns:!last_ts;
       Pcap.Writer.close w;
       printf
         "%d messages read, %d written in %d packets (%d bytes, %.1f msgs/packet) -> %s\n"
         n
         !kept
         !packets
         !bytes
         (Float.of_int !kept /. Float.of_int (Int.max 1 (!packets - 1)))
         out)
;;

let check =
  Command.basic
    ~summary:"parse a pcap back and verify it"
    (let%map_open.Command pcap = anon ("PCAP" %: Filename_unix.arg_type)
     and itch = flag "-itch" (optional Filename_unix.arg_type) ~doc:"FILE compare with this ITCH file"
     and only = flag "-only" (optional (Arg_type.comma_separated string)) ~doc:"SYM,.. as for gen"
     and strict = flag "-strict" no_arg ~doc:" with -only: as for gen"
     and max_messages = flag "-max" (optional int) ~doc:"N compare only the first N ITCH messages" in
     fun () ->
       (* the expected message stream, pulled lazily from the ITCH file *)
       let expected =
         Option.map itch ~f:(fun file ->
           let keep = filter_of_symbols ~strict only in
           let q = Queue.create () in
           ignore
             (Itch.File.iter_raw ?max_messages file ~f:(fun raw -> if keep raw then Queue.enqueue q raw)
               : int);
           q)
       in
       let next_seq = ref 1 and msgs = ref 0 and errors = ref 0 and eos = ref false in
       let err fmt = ksprintf (fun s -> incr errors; if !errors <= 10 then print_endline s) fmt in
       let n =
         Pcap.iter pcap ~f:(fun ~ts_ns:_ frame ->
           match Packet.parse frame with
           | Error e -> err "bad frame: %s" e
           | Ok { udp_payload; _ } ->
             (match Packet.Mold.of_string udp_payload with
              | Error e -> err "bad MoldUDP64: %s" e
              | Ok mold ->
                if mold.end_of_session then eos := true;
                if mold.sequence <> !next_seq then err "sequence %d, expected %d" mold.sequence !next_seq;
                next_seq := mold.sequence + List.length mold.messages;
                List.iter mold.messages ~f:(fun m ->
                  incr msgs;
                  (match Itch.of_string m with
                   | exception Itch.Decode_error e -> err "message %d: %s" !msgs e
                   | _ -> ());
                  Option.iter expected ~f:(fun q ->
                    match Queue.dequeue q with
                    | Some e when String.equal e m -> ()
                    | _ -> err "message %d differs from the ITCH file" !msgs))))
       in
       Option.iter expected ~f:(fun q ->
         if not (Queue.is_empty q) then err "%d messages missing from the pcap" (Queue.length q));
       if not !eos then err "no end-of-session packet";
       printf "%d packets, %d messages, %d errors\n" n !msgs !errors;
       if !errors > 0 then exit 1)
;;

(* What the FPGA prints over the UART for this pcap: one "E" line per
   top-of-book change (hex: seq, slot, bid price, bid size, ask price, ask
   size) and the change count and hash that appear in its status lines. *)
let expect =
  Command.basic
    ~summary:"model's expected board UART output for a pcap"
    (let%map_open.Command pcap = anon ("PCAP" %: Filename_unix.arg_type)
     and max_packets = flag "-max-packets" (optional int) ~doc:"N only the first N packets"
     and symbols =
       flag
         "-symbols"
         (optional_with_default [ "QQQ"; "SPY"; "IWM"; "DIA"; "TQQQ"; "SQQQ"; "AMD"; "UVXY" ] (Arg_type.comma_separated string))
         ~doc:"SYM,.. tracked symbols"
     and summary_only = flag "-summary" no_arg ~doc:" print only the change count and hash"
     and mold_receiver =
       flag
         "-mold-receiver"
         no_arg
         ~doc:
           " drop messages the board's MoldUDP64 receiver drops (sequence below the \
            next expected one), for pcaps of frames in the order they were really sent"
     in
     fun () ->
       let book = Book.create symbols in
       let hash = ref 0 and n = ref 0 in
       let expected = ref None in
       let accept seq =
         (not mold_receiver)
         ||
         match !expected with
         | Some e when seq < e -> false
         | _ ->
           expected := Some (seq + 1);
           true
       in
       ignore
         (Pcap.iter ?max_packets pcap ~f:(fun ~ts_ns:_ frame ->
            match Packet.parse frame with
            | Error _ -> ()
            | Ok p ->
              (match Packet.Mold.of_string p.udp_payload with
               | Error _ -> ()
               | Ok mold ->
                 List.iteri mold.messages ~f:(fun k m ->
                   let seq = mold.sequence + k in
                   if accept seq
                   then
                   Option.iter (Book.apply book (Itch.of_string m)) ~f:(fun (t : Book.Tob.t) ->
                     incr n;
                     hash := Crc32_sw.hash_tob_event !hash ~seq t;
                     if not summary_only
                     then
                       printf
                         "E %08x %x %08x %08x %08x %08x\n"
                         (seq land 0xffffffff)
                         t.slot
                         t.bid_price
                         t.bid_shares
                         t.ask_price
                         t.ask_shares))))
          : int);
       printf "chg=%08x hash=%08x\n" !n !hash)
;;

(* The orders the board's trading rule sends for a pcap: one line per
   order, the frame in hex (without its FCS), as Order_entry builds it. *)
let orders =
  Command.basic
    ~summary:"model's expected order frames (the board's trading rule) for a pcap"
    (let%map_open.Command pcap = anon ("PCAP" %: Filename_unix.arg_type)
     and symbol = flag "-symbol" (optional_with_default Ouch.board_rule.symbol string) ~doc:"SYM symbol"
     and limit = flag "-limit" (optional_with_default Ouch.board_rule.limit int) ~doc:"PRICE limit (4 decimals)"
     and quantity = flag "-quantity" (optional_with_default Ouch.board_rule.quantity int) ~doc:"N shares"
     and mold_receiver =
       flag "-mold-receiver" no_arg ~doc:" drop late messages, as the board does (see expect)"
     and summary_only = flag "-summary" no_arg ~doc:" print only the number of orders"
     and max_packets = flag "-max-packets" (optional int) ~doc:"N only the first N packets" in
     fun () ->
       let symbols = [ "QQQ"; "SPY"; "IWM"; "DIA"; "TQQQ"; "SQQQ"; "AMD"; "UVXY" ] in
       let slot, _ =
         List.findi symbols ~f:(fun _ s -> String.equal s symbol)
         |> Option.value_exn ~message:"the symbol must be one of the board's eight"
       in
       let book = Book.create symbols in
       let strategy = Ouch.Strategy.create { slot; symbol; limit; quantity } in
       let expected = ref None in
       let accept seq =
         (not mold_receiver)
         ||
         match !expected with
         | Some e when seq < e -> false
         | _ ->
           expected := Some (seq + 1);
           true
       in
       ignore
         (Pcap.iter ?max_packets pcap ~f:(fun ~ts_ns:_ frame ->
            match Packet.parse frame with
            | Error _ -> ()
            | Ok p ->
              (match Packet.Mold.of_string p.udp_payload with
               | Error _ -> ()
               | Ok mold ->
                 List.iteri mold.messages ~f:(fun k m ->
                   let seq = mold.sequence + k in
                   if accept seq
                   then
                     Option.iter (Book.apply book (Itch.of_string m)) ~f:(fun tob ->
                       Option.iter (Ouch.Strategy.on_tob strategy ~seq tob) ~f:(fun order ->
                         if not summary_only
                         then
                           Packet.frame ~udp_checksum:false Packet.order_endpoints (Ouch.enter_order_to_string order)
                           |> String.concat_map ~f:(fun c -> sprintf "%02x" (Char.to_int c))
                           |> print_endline)))))
          : int);
       printf "orders=%d\n" strategy.sent)
;;

(* Gap recovery on the board: the feed on two lines, A as recorded and B
   (Packet.line_b_endpoints) [skew] packets behind, each losing packets at
   random, a few lost on both, which only a retransmission recovers. *)
let ab =
  Command.basic
    ~summary:"A/B feed with random packet losses on each line"
    (let%map_open.Command pcap = anon ("PCAP" %: Filename_unix.arg_type)
     and out = anon ("OUT" %: string)
     and drop_a = flag "-drop-a" (optional_with_default 0.01 float) ~doc:"P chance a packet is lost on A"
     and drop_b = flag "-drop-b" (optional_with_default 0.01 float) ~doc:"P chance a packet is lost on B"
     and skew = flag "-skew" (optional_with_default 4 int) ~doc:"N packets B runs behind A"
     and seed = flag "-seed" (optional_with_default 1 int) ~doc:"N random seed"
     and max_packets = flag "-max-packets" (optional int) ~doc:"N only the first N packets" in
     fun () ->
       let rand = Random.State.make [| seed |] in
       let w = Pcap.Writer.create out in
       let b_late = Queue.create () in
       let n = ref 0 and lost_a = ref 0 and lost_b = ref 0 and lost_both = ref 0 in
       let last_ts = ref 0 in
       let send ~ts_ns f = Pcap.Writer.write w ~ts_ns f in
       ignore
         (Pcap.iter ?max_packets pcap ~f:(fun ~ts_ns frame ->
            incr n;
            last_ts := ts_ns;
            let keep p = Float.(Random.State.float rand 1.0 >= p) in
            let a = keep drop_a and b = keep drop_b in
            if not a then incr lost_a;
            if not b then incr lost_b;
            if (not a) && not b then incr lost_both;
            if a then send ~ts_ns frame;
            (match Packet.parse frame with
             | Ok p when b -> Queue.enqueue b_late (Packet.frame Packet.line_b_endpoints p.udp_payload)
             | _ -> Queue.enqueue b_late "");
            if Queue.length b_late > skew
            then (
              let f = Queue.dequeue_exn b_late in
              if not (String.is_empty f) then send ~ts_ns f))
          : int);
       Queue.iter b_late ~f:(fun f -> if not (String.is_empty f) then send ~ts_ns:!last_ts f);
       Pcap.Writer.close w;
       printf "packets=%d lost_a=%d lost_b=%d lost_both=%d\n" !n !lost_a !lost_b !lost_both)
;;

let () =
  Command_unix.run
    (Command.group
       ~summary:"MoldUDP64 pcap generator"
       [ "gen", gen; "check", check; "expect", expect; "orders", orders; "ab", ab ])
