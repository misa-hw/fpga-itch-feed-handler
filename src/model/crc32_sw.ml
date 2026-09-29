(* CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320), bit-serial
   reference. The hardware generator (src/hw/crc32.ml) derives its XOR
   networks from this function. *)

open! Core

let poly = 0xEDB88320

(* process [nbits] bits of [data], LSB first *)
let update_bits crc ~data ~nbits =
  let crc = ref crc in
  for i = 0 to nbits - 1 do
    let b = (data lsr i) land 1 in
    let x = (!crc lxor b) land 1 in
    crc := (!crc lsr 1) lxor (if x = 1 then poly else 0)
  done;
  !crc
;;

let update_string crc s =
  String.fold s ~init:crc ~f:(fun crc c -> update_bits crc ~data:(Char.to_int c) ~nbits:8)
;;

(* Ethernet FCS of a frame (appended little endian) *)
let fcs frame = lnot (update_string 0xFFFFFFFF frame) land 0xFFFFFFFF

(* Hash of top-of-book changes, as computed on the board: CRC-32 from 0,
   no final complement, over seq(4) slot(1) bid_price(4) bid_shares(4)
   ask_price(4) ask_shares(4), each little endian. *)
let tob_event_bytes ~seq (t : Book.Tob.t) =
  let b = Bytes.create 21 in
  let le pos len v =
    for k = 0 to len - 1 do
      Bytes.set b (pos + k) (Char.of_int_exn ((v lsr (8 * k)) land 0xff))
    done
  in
  le 0 4 seq;
  le 4 1 t.slot;
  le 5 4 t.bid_price;
  le 9 4 t.bid_shares;
  le 13 4 t.ask_price;
  le 17 4 t.ask_shares;
  Bytes.to_string b
;;

let hash_tob_event h ~seq t = update_string h (tob_event_bytes ~seq t)
