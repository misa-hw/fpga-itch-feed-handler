(* Reference behaviour of Rx_front (frame filter + MoldUDP64 splitter),
   written directly from the spec in frame_parser.ml / mold_parser.ml, byte
   by byte, so that truncated and malformed inputs are modelled exactly. *)

open! Core
open Net

type cfg =
  { mac : string
  ; ip : int
  ; port : int
  }

let cfg_of_endpoints (ep : Packet.endpoints) = { mac = ep.dst_mac; ip = ep.dst_ip; port = ep.dst_port }

type frame_class =
  | Filtered
  | Error
  | Accepted

type t =
  { cfg : cfg
  ; mutable synced : bool
  ; mutable expected : int
  ; mutable frames : int
  ; mutable accepted : int
  ; mutable filtered : int
  ; mutable errors : int
  ; mutable packets : int
  ; mutable messages : int
  ; mutable duplicates : int
  ; mutable gaps : int
  ; mutable malformed : int
  }

let create cfg =
  { cfg
  ; synced = false
  ; expected = 0
  ; frames = 0
  ; accepted = 0
  ; filtered = 0
  ; errors = 0
  ; packets = 0
  ; messages = 0
  ; duplicates = 0
  ; gaps = 0
  ; malformed = 0
  }
;;

let be = Packet.be

(* Does any header check fail on the bytes present? *)
let header_mismatch t f =
  let n = String.length f in
  let byte k = Char.to_int f.[k] in
  let chk k ~mask v = k < n && byte k land mask <> v in
  List.exists (List.init 6 ~f:Fn.id) ~f:(fun k -> chk k ~mask:0xff (Char.to_int t.cfg.mac.[k]))
  || chk 12 ~mask:0xff 0x08
  || chk 13 ~mask:0xff 0
  || chk 14 ~mask:0xff 0x45
  || chk 20 ~mask:0xbf 0
  || chk 21 ~mask:0xff 0
  || chk 23 ~mask:0xff 17
  || List.exists (List.init 4 ~f:Fn.id) ~f:(fun k -> chk (30 + k) ~mask:0xff ((t.cfg.ip lsr (8 * (3 - k))) land 255))
  || List.exists (List.init 2 ~f:Fn.id) ~f:(fun k -> chk (36 + k) ~mask:0xff ((t.cfg.port lsr (8 * (1 - k))) land 255))
  || (n > 39 && be f ~pos:38 ~len:2 < 8)
;;

(* Walk a (possibly truncated) MoldUDP64 payload; [emit seq msg] for every
   complete message that is forwarded. *)
let mold t payload ~complete ~emit =
  let n = String.length payload in
  if n < 20
  then (if complete then t.malformed <- t.malformed + 1)
  else (
    t.packets <- t.packets + 1;
    let seq = be payload ~pos:10 ~len:8 and count = be payload ~pos:18 ~len:2 in
    if count = 0 || count = 0xffff
    then ()
    else (
      let rec go pos k seq =
        if k = count
        then ()
        else if pos + 2 > n
        then (if complete then t.malformed <- t.malformed + 1)
        else (
          let len = be payload ~pos ~len:2 in
          if len = 0
          then go (pos + 2) (k + 1) (seq + 1)
          else if pos + 2 + len > n
          then (
            (* the first body byte (if present) already made the dup/gap decision *)
            if pos + 2 < n
            then (
              let accept = (not t.synced) || seq >= t.expected in
              if not accept then t.duplicates <- t.duplicates + 1
              else if t.synced && seq > t.expected then t.gaps <- t.gaps + 1);
            (if complete then t.malformed <- t.malformed + 1))
          else (
            let accept = (not t.synced) || seq >= t.expected in
            if accept
            then (
              if t.synced && seq > t.expected then t.gaps <- t.gaps + 1;
              t.synced <- true;
              t.expected <- seq + 1;
              t.messages <- t.messages + 1;
              emit ~seq (String.sub payload ~pos:(pos + 2) ~len))
            else t.duplicates <- t.duplicates + 1;
            go (pos + 2 + len) (k + 1) (seq + 1)))
      in
      go 20 0 seq))
;;

let frame t ?(err = false) f ~emit =
  t.frames <- t.frames + 1;
  let n = String.length f in
  if header_mismatch t f
  then t.filtered <- t.filtered + 1
  else if n < 42 || n < 42 + (be f ~pos:38 ~len:2 - 8)
  then (
    t.errors <- t.errors + 1;
    (* cut-through: complete messages in the truncated payload still go out *)
    if n > 42
    then (
      mold t (String.sub f ~pos:42 ~len:(n - 42)) ~complete:false ~emit;
      (* the parser's abort *)
      t.malformed <- t.malformed + 1))
  else (
    if err then t.errors <- t.errors + 1 else t.accepted <- t.accepted + 1;
    let payload = String.sub f ~pos:42 ~len:(be f ~pos:38 ~len:2 - 8) in
    mold t payload ~complete:true ~emit)
;;
