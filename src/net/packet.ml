(* Ethernet II / IPv4 / UDP / MoldUDP64 framing.

   Frame layout produced by [frame] (no preamble, no FCS: what an RX MAC
   hands to the next stage, and what a pcap file stores):

     offset  size
     0       6    destination MAC
     6       6    source MAC
     12      2    ethertype 0x0800
     14      20   IPv4 header (IHL=5, no options, DF set, TTL 64, protocol 17)
     34      8    UDP header
     42      20   MoldUDP64 header: session(10) sequence(8) count(2)
     62      ..   message blocks: [u16 length][ITCH message] ...

   A frame shorter than 60 bytes is zero padded, as a MAC would do. *)

open! Core

module Mac = struct
  type t = string (* 6 bytes *) [@@deriving sexp, compare, equal]

  let of_string s =
    let parts = String.split s ~on:':' in
    if List.length parts <> 6 then invalid_arg ("bad MAC " ^ s);
    String.of_list (List.map parts ~f:(fun p -> Char.of_int_exn (Int.of_string ("0x" ^ p))))
  ;;

  let to_string t =
    String.to_list t |> List.map ~f:(fun c -> sprintf "%02x" (Char.to_int c)) |> String.concat ~sep:":"
  ;;

  let to_int t = Itch_model.Itch.be t ~pos:0 ~len:6

  (* IPv4 multicast group -> 01:00:5e + low 23 bits of the group address *)
  let of_multicast_ip ip =
    let b = Bytes.of_string "\x01\x00\x5e\x00\x00\x00" in
    Itch_model.Itch.put_be b ~pos:3 ~len:3 (ip land 0x7fffff);
    Bytes.to_string b
  ;;
end

module Ip = struct
  type t = int [@@deriving sexp, compare, equal]

  let of_string s =
    match String.split s ~on:'.' |> List.map ~f:Int.of_string with
    | [ a; b; c; d ] -> (a lsl 24) lor (b lsl 16) lor (c lsl 8) lor d
    | _ -> invalid_arg ("bad IPv4 address " ^ s)
  ;;

  let to_string t =
    sprintf "%d.%d.%d.%d" ((t lsr 24) land 255) ((t lsr 16) land 255) ((t lsr 8) land 255) (t land 255)
  ;;
end

(* Everything that identifies the feed; the hardware filters on the
   destination fields. *)
type endpoints =
  { src_mac : Mac.t
  ; dst_mac : Mac.t
  ; src_ip : Ip.t
  ; dst_ip : Ip.t
  ; src_port : int
  ; dst_port : int
  }
[@@deriving sexp]

(* Nasdaq-like defaults: a multicast group, so no ARP is needed on the board. *)
let default_endpoints =
  let dst_ip = Ip.of_string "233.54.12.111" in
  { src_mac = Mac.of_string "02:00:00:00:00:01"
  ; dst_mac = Mac.of_multicast_ip dst_ip
  ; src_ip = Ip.of_string "192.168.10.1"
  ; dst_ip
  ; src_port = 26477
  ; dst_port = 26477
  }
;;

let eth_header_len = 14
let ip_header_len = 20
let udp_header_len = 8
let mold_header_len = 20
let payload_offset = eth_header_len + ip_header_len + udp_header_len (* 42 *)
let first_block_offset = payload_offset + mold_header_len (* 62 *)
let min_frame_len = 60 (* without FCS *)

(* Largest MoldUDP64 payload in a standard 1500-byte MTU. *)
let max_udp_payload = 1500 - ip_header_len - udp_header_len

let be = Itch_model.Itch.be
let put_be = Itch_model.Itch.put_be

(* RFC 1071 one's complement sum of 16-bit big-endian words. *)
let ones_complement_sum ?(init = 0) s ~pos ~len =
  let sum = ref init in
  let i = ref 0 in
  while !i + 1 < len do
    sum := !sum + be s ~pos:(pos + !i) ~len:2;
    i := !i + 2
  done;
  if !i < len then sum := !sum + (Char.to_int s.[pos + !i] lsl 8);
  while !sum > 0xffff do
    sum := (!sum land 0xffff) + (!sum lsr 16)
  done;
  !sum
;;

let checksum ?init s ~pos ~len = lnot (ones_complement_sum ?init s ~pos ~len) land 0xffff

module Mold = struct
  type t =
    { session : string (* 10 bytes *)
    ; sequence : int (* sequence number of the first message *)
    ; messages : string list (* raw ITCH messages; [] = heartbeat *)
    ; end_of_session : bool (* message count 0xFFFF *)
    }
  [@@deriving sexp, compare, equal]

  let to_string t =
    if String.length t.session <> 10 then invalid_arg "MoldUDP64 session must be 10 bytes";
    let buf = Buffer.create 1500 in
    Buffer.add_string buf t.session;
    let b = Bytes.create 10 in
    put_be b ~pos:0 ~len:8 t.sequence;
    put_be b ~pos:8 ~len:2 (if t.end_of_session then 0xffff else List.length t.messages);
    Buffer.add_bytes buf b;
    List.iter t.messages ~f:(fun m ->
      let l = Bytes.create 2 in
      put_be l ~pos:0 ~len:2 (String.length m);
      Buffer.add_bytes buf l;
      Buffer.add_string buf m);
    Buffer.contents buf
  ;;

  let of_string s =
    if String.length s < mold_header_len then Error "MoldUDP64 packet too short"
    else (
      let count = be s ~pos:18 ~len:2 in
      let rec blocks pos n acc =
        if n = 0
        then if pos = String.length s then Ok (List.rev acc) else Error "trailing bytes"
        else if pos + 2 > String.length s
        then Error "truncated block length"
        else (
          let len = be s ~pos ~len:2 in
          if pos + 2 + len > String.length s
          then Error "truncated message"
          else blocks (pos + 2 + len) (n - 1) (String.sub s ~pos:(pos + 2) ~len :: acc))
      in
      let end_of_session = count = 0xffff in
      Result.map (blocks 20 (if end_of_session then 0 else count) []) ~f:(fun messages ->
        { session = String.sub s ~pos:0 ~len:10
        ; sequence = be s ~pos:10 ~len:8
        ; messages
        ; end_of_session
        }))
  ;;
end

(* Build a complete Ethernet frame around a UDP payload. [ip_id] is the IPv4
   identification field (incremented per packet by the sender). *)
let frame ?(ip_id = 0) (ep : endpoints) payload =
  let udp_len = udp_header_len + String.length payload in
  let ip_len = ip_header_len + udp_len in
  let frame_len = Int.max min_frame_len (eth_header_len + ip_len) in
  let b = Bytes.make frame_len '\000' in
  let put ~pos ~len v = put_be b ~pos ~len v in
  (* Ethernet *)
  Bytes.From_string.blit ~src:ep.dst_mac ~src_pos:0 ~dst:b ~dst_pos:0 ~len:6;
  Bytes.From_string.blit ~src:ep.src_mac ~src_pos:0 ~dst:b ~dst_pos:6 ~len:6;
  put ~pos:12 ~len:2 0x0800;
  (* IPv4 *)
  let ip = eth_header_len in
  put ~pos:ip ~len:1 0x45;
  put ~pos:(ip + 2) ~len:2 ip_len;
  put ~pos:(ip + 4) ~len:2 (ip_id land 0xffff);
  put ~pos:(ip + 6) ~len:2 0x4000 (* don't fragment *);
  put ~pos:(ip + 8) ~len:1 64 (* TTL *);
  put ~pos:(ip + 9) ~len:1 17 (* UDP *);
  put ~pos:(ip + 12) ~len:4 ep.src_ip;
  put ~pos:(ip + 16) ~len:4 ep.dst_ip;
  put
    ~pos:(ip + 10)
    ~len:2
    (checksum (Bytes.unsafe_to_string ~no_mutation_while_string_reachable:b) ~pos:ip ~len:ip_header_len);
  (* UDP *)
  let udp = ip + ip_header_len in
  put ~pos:udp ~len:2 ep.src_port;
  put ~pos:(udp + 2) ~len:2 ep.dst_port;
  put ~pos:(udp + 4) ~len:2 udp_len;
  Bytes.From_string.blit
    ~src:payload
    ~src_pos:0
    ~dst:b
    ~dst_pos:(udp + udp_header_len)
    ~len:(String.length payload);
  (* UDP checksum over the pseudo header, header and payload *)
  let pseudo =
    (ep.src_ip lsr 16) + (ep.src_ip land 0xffff) + (ep.dst_ip lsr 16) + (ep.dst_ip land 0xffff) + 17
    + udp_len
  in
  let c =
    checksum
      ~init:pseudo
      (Bytes.unsafe_to_string ~no_mutation_while_string_reachable:b)
      ~pos:udp
      ~len:udp_len
  in
  put ~pos:(udp + 6) ~len:2 (if c = 0 then 0xffff else c);
  Bytes.to_string b
;;

(* The inverse, with every check the hardware makes plus the checksums (which
   the hardware does not verify; see DESIGN.md). *)
type parsed =
  { endpoints : endpoints
  ; udp_payload : string
  }

let parse s =
  let ( let* ) r f = Result.bind r ~f in
  let n = String.length s in
  let* () = if n >= payload_offset then Ok () else Error "frame too short" in
  let* () = if be s ~pos:12 ~len:2 = 0x0800 then Ok () else Error "not IPv4" in
  let ip = eth_header_len in
  let* () = if Char.to_int s.[ip] = 0x45 then Ok () else Error "IPv4 options/version" in
  let* () = if Char.to_int s.[ip + 9] = 17 then Ok () else Error "not UDP" in
  let* () =
    if checksum s ~pos:ip ~len:ip_header_len = 0 then Ok () else Error "bad IPv4 checksum"
  in
  let* () =
    if be s ~pos:(ip + 6) ~len:2 land 0x3fff = 0 then Ok () else Error "fragmented"
  in
  let ip_len = be s ~pos:(ip + 2) ~len:2 in
  let* () = if eth_header_len + ip_len <= n then Ok () else Error "truncated IPv4" in
  let udp = ip + ip_header_len in
  let udp_len = be s ~pos:(udp + 4) ~len:2 in
  let* () = if udp_len = ip_len - ip_header_len then Ok () else Error "UDP length" in
  let src_ip = be s ~pos:(ip + 12) ~len:4 and dst_ip = be s ~pos:(ip + 16) ~len:4 in
  let pseudo =
    (src_ip lsr 16) + (src_ip land 0xffff) + (dst_ip lsr 16) + (dst_ip land 0xffff) + 17 + udp_len
  in
  let* () =
    if be s ~pos:(udp + 6) ~len:2 = 0 || checksum ~init:pseudo s ~pos:udp ~len:udp_len = 0
    then Ok ()
    else Error "bad UDP checksum"
  in
  Ok
    { endpoints =
        { dst_mac = String.sub s ~pos:0 ~len:6
        ; src_mac = String.sub s ~pos:6 ~len:6
        ; src_ip
        ; dst_ip
        ; src_port = be s ~pos:udp ~len:2
        ; dst_port = be s ~pos:(udp + 2) ~len:2
        }
    ; udp_payload = String.sub s ~pos:(udp + udp_header_len) ~len:(udp_len - udp_header_len)
    }
;;

(* Groups a stream of ITCH messages into MoldUDP64 packets.

   A packet is closed when the next message would not fit in the MTU, when
   [max_messages] is reached, or when the next message's ITCH timestamp is
   more than [window_ns] after the first message in the packet: roughly how
   Nasdaq's sender batches, giving realistic packet sizes (bursts at the open
   produce full packets, quiet periods produce 1-message packets). *)
module Packetizer = struct
  type t =
    { session : string
    ; max_messages : int
    ; window_ns : int
    ; emit : ts_ns:int -> Mold.t -> unit
    ; mutable next_seq : int
    ; mutable pending : string list (* reversed *)
    ; mutable pending_bytes : int
    ; mutable first_ts : int
    }

  let create ?(session = "ITCH50SMPL") ?(max_messages = 0xfffe) ?(window_ns = 1000) ~emit () =
    { session
    ; max_messages
    ; window_ns
    ; emit
    ; next_seq = 1
    ; pending = []
    ; pending_bytes = mold_header_len
    ; first_ts = 0
    }
  ;;

  let flush t =
    if not (List.is_empty t.pending)
    then (
      let messages = List.rev t.pending in
      t.emit
        ~ts_ns:t.first_ts
        { session = t.session; sequence = t.next_seq; messages; end_of_session = false };
      t.next_seq <- t.next_seq + List.length messages;
      t.pending <- [];
      t.pending_bytes <- mold_header_len)
  ;;

  (* [ts_ns]: the message's ITCH timestamp (ns since midnight). *)
  let add t ~ts_ns msg =
    let size = 2 + String.length msg in
    if (not (List.is_empty t.pending))
       && (t.pending_bytes + size > max_udp_payload
           || List.length t.pending >= t.max_messages
           || ts_ns - t.first_ts > t.window_ns)
    then flush t;
    if List.is_empty t.pending then t.first_ts <- ts_ns;
    t.pending <- msg :: t.pending;
    t.pending_bytes <- t.pending_bytes + size
  ;;

  let heartbeat t ~ts_ns =
    flush t;
    t.emit ~ts_ns { session = t.session; sequence = t.next_seq; messages = []; end_of_session = false }
  ;;

  let finish t ~ts_ns =
    flush t;
    t.emit ~ts_ns { session = t.session; sequence = t.next_seq; messages = []; end_of_session = true }
  ;;
end
