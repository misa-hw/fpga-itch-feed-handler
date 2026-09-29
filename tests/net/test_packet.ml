open! Core
open Net

let hex s =
  String.iteri s ~f:(fun i c ->
    printf "%02x%s" (Char.to_int c) (if i % 16 = 15 || i = String.length s - 1 then "\n" else " "))
;;

let%expect_test "IPv4 header checksum: the textbook example" =
  (* 45 00 00 73 00 00 40 00 40 11 [b8 61] c0 a8 00 01 c0 a8 00 c7 *)
  let h = "\x45\x00\x00\x73\x00\x00\x40\x00\x40\x11\x00\x00\xc0\xa8\x00\x01\xc0\xa8\x00\xc7" in
  printf "%04x\n" (Packet.checksum h ~pos:0 ~len:20);
  [%expect {| b861 |}]
;;

let%expect_test "a heartbeat frame, byte by byte" =
  let mold = { Packet.Mold.session = "ITCH50SMPL"; sequence = 7; messages = []; end_of_session = false } in
  hex (Packet.frame ~ip_id:1 Packet.default_endpoints (Packet.Mold.to_string mold));
  [%expect {|
    01 00 5e 36 0c 6f 02 00 00 00 00 01 08 00 45 00
    00 30 00 01 40 00 40 11 7a 6d c0 a8 0a 01 e9 36
    0c 6f 67 6d 67 6d 00 1c 0b 1f 49 54 43 48 35 30
    53 4d 50 4c 00 00 00 00 00 00 00 07 00 00
    |}]
;;

let%expect_test "frame with one Delete message; parse inverts frame" =
  let del =
    Itch_model.Itch.to_string
      { header = { locate = 1; tracking = 0; timestamp = 5 }; body = Order_delete { order_ref = 9 } }
  in
  let mold = { Packet.Mold.session = "ITCH50SMPL"; sequence = 1; messages = [ del ]; end_of_session = false } in
  let f = Packet.frame Packet.default_endpoints (Packet.Mold.to_string mold) in
  printf "frame %d bytes\n" (String.length f);
  (match Packet.parse f with
   | Error e -> print_endline e
   | Ok p ->
     printf
       "%s %s:%d -> %s %s:%d\n"
       (Packet.Mac.to_string p.endpoints.src_mac)
       (Packet.Ip.to_string p.endpoints.src_ip)
       p.endpoints.src_port
       (Packet.Mac.to_string p.endpoints.dst_mac)
       (Packet.Ip.to_string p.endpoints.dst_ip)
       p.endpoints.dst_port;
     print_s [%sexp (Packet.Mold.of_string p.udp_payload |> Result.ok_or_failwith : Packet.Mold.t)]);
  (* corruptions are caught *)
  let corrupt pos =
    let b = Bytes.of_string f in
    Bytes.set b pos (Char.of_int_exn (Char.to_int (Bytes.get b pos) lxor 1));
    match Packet.parse (Bytes.to_string b) with
    | Ok _ -> print_endline "accepted!"
    | Error e -> print_endline e
  in
  corrupt 12;
  corrupt 20;
  corrupt 70;
  [%expect {|
    frame 83 bytes
    02:00:00:00:00:01 192.168.10.1:26477 -> 01:00:5e:36:0c:6f 233.54.12.111:26477
    ((session ITCH50SMPL) (sequence 1)
     (messages
      ("D\000\001\000\000\000\000\000\000\000\005\000\000\000\000\000\000\000\t"))
     (end_of_session false))
    not IPv4
    bad IPv4 checksum
    bad UDP checksum
    |}]
;;

(* Random message streams survive packetizer -> frame -> parse -> unpack. *)
let%expect_test "property: packetize/frame/parse round trip, MTU respected" =
  let gen =
    Quickcheck.Generator.(
      list_with_length 300 (both (Int.gen_incl 0 5000) (Int.gen_incl 1 400))
      |> map ~f:(fun l ->
        let ts = ref 0 in
        List.mapi l ~f:(fun i (dt, len) ->
          ts := !ts + dt;
          !ts, String.init len ~f:(fun j -> Char.of_int_exn ((i + j) land 255)))))
  in
  Quickcheck.test gen ~trials:200 ~f:(fun msgs ->
    let frames = Queue.create () in
    let p =
      Packet.Packetizer.create
        ~window_ns:2000
        ~emit:(fun ~ts_ns:_ mold ->
          Queue.enqueue frames (Packet.frame Packet.default_endpoints (Packet.Mold.to_string mold)))
        ()
    in
    List.iter msgs ~f:(fun (ts_ns, m) -> Packet.Packetizer.add p ~ts_ns m);
    Packet.Packetizer.finish p ~ts_ns:0;
    let got = ref [] and next = ref 1 in
    Queue.iter frames ~f:(fun f ->
      assert (String.length f <= 1514);
      let parsed = Packet.parse f |> Result.ok_or_failwith in
      let mold = Packet.Mold.of_string parsed.udp_payload |> Result.ok_or_failwith in
      [%test_result: int] mold.sequence ~expect:!next;
      next := !next + List.length mold.messages;
      got := List.rev_append mold.messages !got);
    [%test_result: string list] (List.rev !got) ~expect:(List.map msgs ~f:snd);
    assert (Packet.Mold.of_string (Packet.parse (Queue.last_exn frames) |> Result.ok_or_failwith).udp_payload
            |> Result.ok_or_failwith).end_of_session);
  [%expect {| |}]
;;

let%expect_test "pcap write/read round trip" =
  let file = Filename_unix.temp_file "test" ".pcap" in
  let w = Pcap.Writer.create file in
  Pcap.Writer.write w ~ts_ns:1_564_444_800_123_456_789 "abc";
  Pcap.Writer.write w ~ts_ns:5 (String.make 70 'x');
  Pcap.Writer.close w;
  let n = Pcap.iter file ~f:(fun ~ts_ns frame -> printf "%d %d\n" ts_ns (String.length frame)) in
  printf "%d packets\n" n;
  [%expect {|
    1564444800123456789 3
    5 70
    2 packets
    |}]
;;
