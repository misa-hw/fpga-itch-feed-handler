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
     and summary_only = flag "-summary" no_arg ~doc:" print only the change count and hash" in
     fun () ->
       let book = Book.create symbols in
       let hash = ref 0 and n = ref 0 in
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

let () =
  Command_unix.run
    (Command.group ~summary:"MoldUDP64 pcap generator" [ "gen", gen; "check", check; "expect", expect ])
