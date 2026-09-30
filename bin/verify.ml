(* Full-pipeline verification: stream a pcap through the complete hardware
   (Feed_handler: frame filter, MoldUDP64, ITCH decoder, symbol filter, order
   book), compare every book event against the reference model, and measure
   latency.

     verify PCAP [-verilator] [-max-packets N] [-symbols ..] [-ifg N]

   - Frames are sent back to back, [-ifg] idle cycles apart (default 20 =
     8 bytes preamble/SFD + 12 bytes inter-frame gap, i.e. exactly 1 Gb/s
     line rate at one byte per 125 MHz cycle).
   - Every command the book processes emits an event tagged with the
     message's MoldUDP64 sequence number. For each one: the event's
     "changed" flag must equal "the reference book reported a top-of-book
     change for this message", and on a change the four prices/sizes must be
     equal. Every reference change must have a hardware event.
   - Latency: from the cycle the last byte of the message is on the rx
     input to the cycle its event is valid. *)

open! Core
open! Hardcaml
open Itch_model
open Net
open Feed_hw
module Sim = Cyclesim.With_interface (Feed_handler.I) (Feed_handler.O)
module Vsim = Hardcaml_verilator.With_interface (Feed_handler.I) (Feed_handler.O)

let default_symbols = [ "QQQ"; "SPY"; "IWM"; "DIA"; "TQQQ"; "SQQQ"; "AMD"; "UVXY" ]

let symbol_bits s =
  String.to_list (Itch.pad_stock s)
  |> List.map ~f:(fun c -> Bits.of_int_trunc ~width:8 (Char.to_int c))
  |> Bits.concat_msb
;;

let percentile sorted p =
  let n = Array.length sorted in
  if n = 0 then 0 else sorted.(Int.min (n - 1) (p * n / 100))
;;

let run ~pcap ~verilator ~max_packets ~symbols ~ifg ~report =
  let scope = Scope.create ~flatten_design:true () in
  let create_fn = Feed_handler.create scope in
  let sim =
    if verilator
    then (
      let cache_dir = Filename.concat (Sys_unix.getcwd ()) "build/verilator_cache" in
      let build_dir = Filename.concat (Sys_unix.getcwd ()) "build/verilator_build" in
      Core_unix.mkdir_p cache_dir;
      Core_unix.mkdir_p build_dir;
      (* verbose: hardcaml_verilator otherwise runs each build step as
         "cmd &>log" through /bin/sh, which dash parses as "cmd &" and the
         link step races the compile *)
      Vsim.create
        ~verilator_config:{ Hardcaml_verilator.Config.default with verbose = true }
        ~build_dir
        ~cache:(Hardcaml_verilator.Cache.Hashed { cache_dir; raise_if_not_found = false })
        create_fn)
    else Sim.create create_fn
  in
  let i : Bits.t ref Feed_handler.I.t = Cyclesim.inputs sim in
  let o : Bits.t ref Feed_handler.O.t = Cyclesim.outputs sim in
  let ep = Packet.default_endpoints in
  i.cfg.net.mac := Bits.of_int_trunc ~width:48 (Packet.Mac.to_int ep.dst_mac);
  i.cfg.net.ip := Bits.of_int_trunc ~width:32 ep.dst_ip;
  i.cfg.net.port := Bits.of_int_trunc ~width:16 ep.dst_port;
  List.iteri symbols ~f:(fun k s -> i.cfg.symbols.(k) := symbol_bits s);
  i.cfg.symbol_enable := Bits.of_int_trunc ~width:8 ((1 lsl List.length symbols) - 1);
  i.clear := Bits.vdd;
  Cyclesim.cycle sim;
  i.clear := Bits.gnd;
  (* reference *)
  let book = Book.create symbols in
  let reference : (int, Book.Tob.t option) Hashtbl.t = Hashtbl.create (module Int) in
  let last_byte_cycle : (int, int) Hashtbl.t = Hashtbl.create (module Int) in
  let kind_of_seq : (int, char) Hashtbl.t = Hashtbl.create (module Int) in
  let ref_changes = ref 0 in
  let expected_events = ref 0 in
  (* results *)
  let cycle = ref 0 in
  let events = ref 0 and changes = ref 0 and mismatches = ref 0 in
  let latencies = Queue.create () in
  let lat_by_kind = Hashtbl.create (module Char) in
  let first_mismatch = ref None in
  let step () =
    Cyclesim.cycle sim;
    incr cycle;
    let e = o.event in
    if Bits.to_bool !(e.valid)
    then (
      incr events;
      let g r = Bits.to_int_trunc !r in
      let seq = g e.seq in
      let changed = Bits.to_bool !(e.changed) in
      if changed then incr changes;
      let tob =
        { Book.Tob.slot = g e.slot
        ; bid_price = g e.bid_price
        ; bid_shares = g e.bid_shares
        ; ask_price = g e.ask_price
        ; ask_shares = g e.ask_shares
        }
      in
      let expected = Hashtbl.find reference seq in
      let want = Option.join expected in
      let ok =
        match expected with
        | None -> false
        | Some want ->
          Bool.equal changed (Option.is_some want)
          && ((not changed) || Book.Tob.equal tob (Option.value_exn want))
      in
      if not ok
      then (
        incr mismatches;
        if Option.is_none !first_mismatch
        then
          first_mismatch
          := Some
               (sprintf
                  "seq %d: hardware %s%s, reference %s"
                  seq
                  (if changed then "changed " else "unchanged ")
                  (Book.Tob.to_string tob)
                  (match expected with
                   | None -> "no command expected"
                   | Some _ -> Option.value_map want ~default:"no change" ~f:Book.Tob.to_string)));
      Hashtbl.remove reference seq;
      match Hashtbl.find_and_remove last_byte_cycle seq with
      | None -> ()
      | Some c ->
        let l = !cycle - c in
        Queue.enqueue latencies l;
        let k = Hashtbl.find_exn kind_of_seq seq in
        Hashtbl.add_multi lat_by_kind ~key:k ~data:l)
  in
  let rx = i.rx in
  let idle n =
    rx.valid := Bits.gnd;
    for _ = 1 to n do
      step ()
    done
  in
  let messages = ref 0 in
  let t0 = Time_ns.now () in
  let packets =
    Pcap.iter ?max_packets pcap ~f:(fun ~ts_ns:_ frame ->
      (* where each message ends inside the frame, and the reference result *)
      let ends = Hashtbl.create (module Int) in
      (match Packet.parse frame with
       | Error _ -> ()
       | Ok p ->
         (match Packet.Mold.of_string p.udp_payload with
          | Error _ -> ()
          | Ok mold ->
            let pos = ref (Packet.first_block_offset) in
            List.iteri mold.messages ~f:(fun k m ->
              let seq = mold.sequence + k in
              pos := !pos + 2 + String.length m;
              Hashtbl.set ends ~key:(!pos - 1) ~data:seq;
              incr messages;
              let parsed = Itch.of_string m in
              let r = Book.apply book parsed in
              if Option.is_some r then incr ref_changes;
              (match parsed.body with
               | Stock_directory _ | Other _ -> ()
               | _ when Option.is_none (Book.slot_of_locate book parsed.header.locate) -> ()
               | _ ->
                 incr expected_events;
                 Hashtbl.set reference ~key:seq ~data:r;
                 Hashtbl.set kind_of_seq ~key:seq ~data:m.[0]))));
      let n = String.length frame in
      String.iteri frame ~f:(fun k c ->
        rx.valid := Bits.vdd;
        rx.data := Bits.of_int_trunc ~width:8 (Char.to_int c);
        rx.first := Bits.of_bool (k = 0);
        rx.last := Bits.of_bool (k = n - 1);
        (match Hashtbl.find ends k with
         | Some seq when Hashtbl.mem reference seq -> Hashtbl.set last_byte_cycle ~key:seq ~data:(!cycle + 1)
         | _ -> ());
        step ());
      rx.first := Bits.gnd;
      rx.last := Bits.gnd;
      idle ifg)
  in
  (* drain: let the book finish *)
  idle 10_000;
  let elapsed = Time_ns.diff (Time_ns.now ()) t0 |> Time_ns.Span.to_sec in
  (* Every tracked book command, including one that did not change the top,
     must produce exactly one event. *)
  let missing_events = Hashtbl.length reference in
  let missing_changes = Hashtbl.count reference ~f:Option.is_some in
  let c = o.counters in
  let g r = Bits.to_int_trunc !r in
  let lat = Queue.to_array latencies in
  Array.sort lat ~compare:Int.compare;
  let buf = Buffer.create 4096 in
  let pr fmt = ksprintf (fun s -> Buffer.add_string buf s; Buffer.add_char buf '\n') fmt in
  pr "pcap: %s (%d packets, %d messages)" pcap packets !messages;
  pr "simulator: %s, %d cycles in %.0f s (%.2f Mcycles/s)" (if verilator then "Verilator" else "Cyclesim") !cycle elapsed (Float.of_int !cycle /. elapsed /. 1e6);
  pr "symbols: %s" (String.concat ~sep:"," symbols);
  pr "";
  pr "book commands: hardware %d, reference %d" !events !expected_events;
  pr "top-of-book changes: hardware %d, reference %d" !changes !ref_changes;
  pr "mismatches: %d, missing hardware events: %d (%d top changes)" !mismatches missing_events missing_changes;
  Option.iter !first_mismatch ~f:(pr "first mismatch: %s");
  pr "";
  pr "frames: %d seen, %d accepted, %d filtered, %d errors" (g c.frame.frames) (g c.frame.accepted) (g c.frame.filtered) (g c.frame.errors);
  pr "mold: %d packets, %d messages, %d dups, %d gaps, %d malformed" (g c.mold.packets) (g c.mold.messages) (g c.mold.duplicates) (g c.mold.gaps) (g c.mold.malformed);
  pr "book: %d unsupported, %d order overflows, %d level overflows, %d kicks (max %d per insert), %d refills" (g c.book.unsupported) (g c.book.order_overflows) (g c.book.level_overflows) (g c.book.kicks) (g c.book.max_kicks) (g c.book.refills);
  pr "book: %d live orders, %d live levels, FIFO max %d used, %d FIFO overflows" (g c.book.orders) (g c.book.levels) (g c.book.fifo_max_used) (g c.book.fifo_overflows);
  pr "book: %d cycles spent waiting for a refill (a cache emptied before its background refill finished)" (g c.book.refill_stall_cycles);
  pr "";
  pr "latency, last byte on rx -> book event valid, in 125 MHz cycles (8 ns):";
  pr "  all (%d): min %d  p50 %d  p99 %d  p99.9 %d  max %d" (Array.length lat) (percentile lat 0) (percentile lat 50) (percentile lat 99) (if Array.length lat > 0 then lat.(Int.min (Array.length lat - 1) (999 * Array.length lat / 1000)) else 0) (if Array.length lat > 0 then lat.(Array.length lat - 1) else 0);
  pr "  over 64 cycles: %d commands (%.4f%%), over 1000: %d"
    (Array.count lat ~f:(fun l -> l > 64))
    (100. *. Float.of_int (Array.count lat ~f:(fun l -> l > 64)) /. Float.of_int (Int.max 1 (Array.length lat)))
    (Array.count lat ~f:(fun l -> l > 1000));
  Hashtbl.to_alist lat_by_kind
  |> List.sort ~compare:(fun (a, _) (b, _) -> Char.compare a b)
  |> List.iter ~f:(fun (k, l) ->
    let a = Array.of_list l in
    Array.sort a ~compare:Int.compare;
    pr "  %c (%7d): min %d  p50 %d  p99 %d  max %d" k (Array.length a) (percentile a 0) (percentile a 50) (percentile a 99) a.(Array.length a - 1));
  print_string (Buffer.contents buf);
  Option.iter report ~f:(fun f -> Out_channel.write_all f ~data:(Buffer.contents buf));
  if !mismatches > 0
     || missing_events > 0
     || !events <> !expected_events
     || g c.book.fifo_overflows > 0
     || g c.book.order_overflows > 0
     || g c.book.level_overflows > 0
  then exit 1
;;

let () =
  Command_unix.run
    (Command.basic
       ~summary:"stream a pcap through the full hardware pipeline and compare with the model"
       (let%map_open.Command pcap = anon ("PCAP" %: Filename_unix.arg_type)
        and verilator = flag "-verilator" no_arg ~doc:" use Verilator instead of Cyclesim"
        and max_packets = flag "-max-packets" (optional int) ~doc:"N stop after N packets"
        and symbols =
          flag "-symbols" (optional_with_default default_symbols (Arg_type.comma_separated string)) ~doc:"SYM,.. tracked symbols"
        and ifg = flag "-ifg" (optional_with_default 20 int) ~doc:"N idle cycles between frames (default 20)"
        and report = flag "-report" (optional string) ~doc:"FILE also write the summary here" in
        fun () -> run ~pcap ~verilator ~max_packets ~symbols ~ifg ~report))
;;
