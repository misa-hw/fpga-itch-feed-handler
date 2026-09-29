open! Core
open! Hardcaml
open! Hardcaml_waveterm
open Net

let ep = Packet.default_endpoints
let cfg = Front_ref.cfg_of_endpoints ep

let itch_delete r =
  Itch_model.Itch.to_string
    { header = { locate = 1; tracking = 0; timestamp = r }; body = Order_delete { order_ref = r } }
;;

let mold ?(eos = false) ~seq msgs =
  Packet.Mold.to_string
    { session = "ITCH50SMPL"; sequence = seq; messages = msgs; end_of_session = eos }
;;

let frame ?(ep = ep) payload = Packet.frame ep payload

let print_messages sim =
  sim.Front_sim.on_message
  <- (fun ~seq m -> printf "msg seq=%d type=%c len=%d\n" seq m.[0] (String.length m))
;;

let%expect_test "waveform: one frame, two messages (bytes 42.. of the frame)" =
  let waves, sim = Front_sim.create ~waves:true ~cfg () in
  let waves = Option.value_exn waves in
  print_messages sim;
  Front_sim.send sim (frame (mold ~seq:5 [ "ABC"; "XY" ]));
  Front_sim.idle sim 4;
  Waveform.print
    ~display_rules:
      Display_rule.
        [ port_name_is_one_of [ "rx_first"; "rx_last"; "rx_valid" ]
        ; port_name_is "rx_data" ~wave_format:Hex
        ; port_name_is_one_of [ "msg_first"; "msg_last"; "msg_valid" ]
        ; port_name_is "msg_data" ~wave_format:Hex
        ; port_name_is "msg_seq" ~wave_format:Unsigned_int
        ]
    ~start_cycle:61
    ~display_width:96
    ~display_height:23
    ~wave_width:1
    waves;
  [%expect {|
    msg seq=5 type=A len=3
    msg seq=6 type=X len=2
    ┌Signals───────────┐┌Waves─────────────────────────────────────────────────────────────────────┐
    │rx_first          ││                                                                          │
    │                  ││────────────────────────────────────────────────────────────              │
    │rx_last           ││                                        ┌───┐                             │
    │                  ││────────────────────────────────────────┘   └───────────────              │
    │rx_valid          ││────────────────────────────────────────────┐                             │
    │                  ││                                            └───────────────              │
    │                  ││────┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───────────────────              │
    │rx_data           ││ 00 │02 │00 │03 │41 │42 │43 │00 │02 │58 │59                               │
    │                  ││────┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───────────────────              │
    │msg_first         ││                            ┌───┐               ┌───┐                     │
    │                  ││────────────────────────────┘   └───────────────┘   └───────              │
    │msg_last          ││                                    ┌───┐           ┌───┐                 │
    │                  ││────────────────────────────────────┘   └───────────┘   └───              │
    │msg_valid         ││                            ┌───────────┐       ┌───────┐                 │
    │                  ││────────────────────────────┘           └───────┘       └───              │
    │                  ││────────┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───────              │
    │msg_data          ││ 00     │05 │00 │02 │00 │03 │41 │42 │43 │00 │02 │58 │59                   │
    │                  ││────────┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───────              │
    │                  ││────────────────────┬───────────────────┬───────────────┬───              │
    │msg_seq           ││ 0                  │5                  │6              │7                │
    │                  ││────────────────────┴───────────────────┴───────────────┴───              │
    └──────────────────┘└──────────────────────────────────────────────────────────────────────────┘
    |}]
;;

let%expect_test "filtering, errors, heartbeats, duplicates and gaps" =
  let _, sim = Front_sim.create ~cfg () in
  print_messages sim;
  let r = Front_ref.create cfg in
  let send ?err f =
    Front_sim.send ?err sim f;
    Front_sim.idle sim 12;
    Front_ref.frame r ?err f ~emit:(fun ~seq:_ _ -> ())
  in
  let del = itch_delete in
  send (frame (mold ~seq:1 [ del 1; del 2 ]));
  send (frame ~ep:{ ep with dst_mac = Packet.Mac.of_string "01:00:5e:00:00:01" } (mold ~seq:3 [ del 3 ]));
  send (frame ~ep:{ ep with dst_ip = Packet.Ip.of_string "233.54.12.112" } (mold ~seq:3 [ del 3 ]));
  send (frame ~ep:{ ep with dst_port = 1234 } (mold ~seq:3 [ del 3 ]));
  let f = frame (mold ~seq:3 [ del 3 ]) in
  let patch pos c = String.mapi f ~f:(fun k x -> if k = pos then c else x) in
  send (patch 12 '\x86') (* IPv6 ethertype *);
  send (patch 14 '\x46') (* IHL 6: options *);
  send (patch 20 '\x20') (* more fragments *);
  send (patch 23 '\x06') (* TCP *);
  send (frame (mold ~seq:3 [])) (* heartbeat *);
  send (frame (mold ~seq:3 [ del 3 ]));
  send (frame (mold ~seq:2 [ del 2; del 3; del 4 ])) (* 2,3 are duplicates *);
  send (frame (mold ~seq:10 [ del 10 ])) (* 5..9 lost *);
  send ~err:true (frame (mold ~seq:11 [ del 11 ])) (* bad FCS: counted, still forwarded *);
  send (String.prefix (frame (mold ~seq:12 [ del 12; del 13 ])) 70) (* truncated *);
  send (frame (mold ~seq:14 ~eos:true [])) (* end of session *);
  print_endline (Front_sim.counters sim);
  print_endline (Front_sim.ref_counters r);
  [%expect {|
    msg seq=1 type=D len=19
    msg seq=2 type=D len=19
    msg seq=3 type=D len=19
    msg seq=4 type=D len=19
    msg seq=10 type=D len=19
    msg seq=11 type=D len=19
    frames=15 accepted=6 filtered=7 errors=2 | packets=8 messages=6 dups=2 gaps=1 malformed=1
    frames=15 accepted=6 filtered=7 errors=2 | packets=8 messages=6 dups=2 gaps=1 malformed=1
    |}]
;;

(* Random traffic: well-formed and damaged frames, random message sizes, random
   sequence numbers (in order, repeated, skipped), random stalls inside frames. *)
let%expect_test "property: hardware == reference on random traffic" =
  let rng = Random.State.make [| 42 |] in
  let _, sim = Front_sim.create ~cfg () in
  let r = Front_ref.create cfg in
  let got = Queue.create () and want = Queue.create () in
  sim.on_message <- (fun ~seq m -> Queue.enqueue got (seq, m));
  let seq = ref 1 in
  let n_frames = 3000 in
  for _ = 1 to n_frames do
    let nmsg = Random.State.int rng 6 in
    let msgs =
      List.init nmsg ~f:(fun _ ->
        String.init (Random.State.int_incl rng 1 60) ~f:(fun _ -> Random.State.char rng))
    in
    (* mostly in order; sometimes replay the past or skip ahead *)
    (match Random.State.int rng 10 with
     | 0 -> seq := Int.max 1 (!seq - Random.State.int rng 5)
     | 1 -> seq := !seq + Random.State.int rng 5
     | _ -> ());
    let payload = mold ~seq:!seq msgs in
    seq := !seq + nmsg;
    let ep =
      match Random.State.int rng 12 with
      | 0 -> { ep with dst_port = ep.dst_port + 1 }
      | 1 -> { ep with dst_ip = ep.dst_ip lxor 1 }
      | 2 -> { ep with dst_mac = Packet.Mac.of_string "02:00:00:00:00:02" }
      | _ -> ep
    in
    let f = frame ~ep payload in
    let f =
      if Random.State.int rng 15 = 0
      then String.prefix f (Random.State.int_incl rng 1 (String.length f - 1))
      else f
    in
    let err = Random.State.int rng 20 = 0 in
    let stall () = if Random.State.int rng 8 = 0 then Random.State.int rng 3 else 0 in
    Front_sim.send ~err ~stall sim f;
    Front_sim.idle sim (Random.State.int_incl rng 1 12);
    Front_ref.frame r ~err f ~emit:(fun ~seq m -> Queue.enqueue want (seq, m))
  done;
  Front_sim.idle sim 10;
  let got = Queue.to_list got and want = Queue.to_list want in
  printf "%d messages, equal=%b\n" (List.length want) ([%equal: (int * string) list] got want);
  let c = Front_sim.counters sim and rc = Front_sim.ref_counters r in
  if not (String.equal c rc) then printf "hw:  %s\nref: %s\n" c rc;
  [%expect {| 4942 messages, equal=true |}]
;;

(* Real traffic: the first 20k packets of the tracked-symbol pcap. *)
let%expect_test "real pcap: every message comes out, in order, with its sequence number" =
  (match Lazy.force Sample_data.tracked_pcap with
   | None -> ()
   | Some pcap ->
     let _, sim = Front_sim.create ~cfg () in
     let got = Queue.create () and want = Queue.create () in
     sim.on_message <- (fun ~seq m -> Queue.enqueue got (seq, m));
     let _ =
       Pcap.iter ~max_packets:20_000 pcap ~f:(fun ~ts_ns:_ f ->
         (match Packet.parse f with
          | Ok p ->
            let m = Packet.Mold.of_string p.udp_payload |> Result.ok_or_failwith in
            List.iteri m.messages ~f:(fun k msg -> Queue.enqueue want (m.sequence + k, msg))
          | Error e -> failwith e);
         Front_sim.send sim f;
         (* minimum Ethernet inter-frame gap + preamble: 20 byte times *)
         Front_sim.idle sim 20)
     in
     Front_sim.idle sim 10;
     if not ([%equal: (int * string) list] (Queue.to_list got) (Queue.to_list want))
     then printf "MISMATCH: %d vs %d messages\n" (Queue.length got) (Queue.length want));
  [%expect {| |}]
;;

(* Regression: the message count is 16 bits; 0xFFFF marks end of session. *)
let%expect_test "a packet with 300 messages" =
  let _, sim = Front_sim.create ~cfg () in
  let n = ref 0 in
  sim.on_message <- (fun ~seq:_ _ -> incr n);
  Front_sim.send sim (frame (mold ~seq:1 (List.init 300 ~f:(fun k -> String.make 1 (Char.of_int_exn (k land 255))))));
  Front_sim.send sim (frame (mold ~seq:301 ~eos:true []));
  Front_sim.idle sim 5;
  printf "%d messages\n%s\n" !n (Front_sim.counters sim);
  [%expect {|
    300 messages
    frames=2 accepted=2 filtered=0 errors=0 | packets=2 messages=300 dups=0 gaps=0 malformed=0
    |}]
;;
