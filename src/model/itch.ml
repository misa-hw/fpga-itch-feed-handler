(* Nasdaq TotalView-ITCH 5.0 messages.

   Every message starts with the same 11-byte header:
     0     message type (ASCII)
     1-2   stock locate      (u16, big endian)
     3-4   tracking number   (u16)
     5-10  timestamp         (u48, ns since midnight)

   We decode in full the eight types a price-level order book needs and keep
   every other type as raw bytes (their lengths are still validated, so a
   corrupt stream is detected rather than silently mis-framed).

   Order reference numbers are u64 on the wire. They are held in an OCaml
   [int] (63 bits); Nasdaq assigns them sequentially from 0 each day, so the
   top bit is never set in practice. [decode] rejects any that are. *)

open! Core

type side =
  | Buy
  | Sell
[@@deriving sexp, compare, equal]

let side_to_char = function
  | Buy -> 'B'
  | Sell -> 'S'
;;

type header =
  { locate : int
  ; tracking : int
  ; timestamp : int
  }
[@@deriving sexp, compare, equal]

type body =
  | Stock_directory of
      { stock : string (* 8 chars, space padded *)
      ; rest : string (* the remaining 20 bytes, kept verbatim *)
      }
  | Add_order of
      { order_ref : int
      ; side : side
      ; shares : int
      ; stock : string
      ; price : int (* 4 implied decimals *)
      ; mpid : string option (* Some _ for type 'F' *)
      }
  | Order_executed of
      { order_ref : int
      ; shares : int
      ; match_number : int
      }
  | Order_executed_with_price of
      { order_ref : int
      ; shares : int
      ; match_number : int
      ; printable : bool
      ; price : int
      }
  | Order_cancel of
      { order_ref : int
      ; shares : int
      }
  | Order_delete of { order_ref : int }
  | Order_replace of
      { orig_ref : int
      ; new_ref : int
      ; shares : int
      ; price : int
      }
  | Other of
      { typ : char
      ; payload : string (* everything after the 11-byte header *)
      }
[@@deriving sexp, compare, equal]

type t =
  { header : header
  ; body : body
  }
[@@deriving sexp, compare, equal]

(* Total message length (including the type byte) for every ITCH 5.0 type. *)
let length_of_type = function
  | 'S' -> Some 12 (* system event *)
  | 'R' -> Some 39 (* stock directory *)
  | 'H' -> Some 25 (* stock trading action *)
  | 'Y' -> Some 20 (* Reg SHO restriction *)
  | 'L' -> Some 26 (* market participant position *)
  | 'V' -> Some 35 (* MWCB decline level *)
  | 'W' -> Some 12 (* MWCB status *)
  | 'K' -> Some 28 (* IPO quoting period *)
  | 'J' -> Some 35 (* LULD auction collar *)
  | 'h' -> Some 21 (* operational halt *)
  | 'A' -> Some 36 (* add order, no MPID *)
  | 'F' -> Some 40 (* add order with MPID *)
  | 'E' -> Some 31 (* order executed *)
  | 'C' -> Some 36 (* order executed with price *)
  | 'X' -> Some 23 (* order cancel *)
  | 'D' -> Some 19 (* order delete *)
  | 'U' -> Some 35 (* order replace *)
  | 'P' -> Some 44 (* trade, non-cross *)
  | 'Q' -> Some 40 (* cross trade *)
  | 'B' -> Some 19 (* broken trade *)
  | 'I' -> Some 50 (* NOII *)
  | 'N' -> Some 20 (* retail price improvement indicator *)
  | 'O' -> Some 48 (* direct listing with capital raise *)
  | _ -> None
;;

let typ t =
  match t.body with
  | Stock_directory _ -> 'R'
  | Add_order { mpid = None; _ } -> 'A'
  | Add_order { mpid = Some _; _ } -> 'F'
  | Order_executed _ -> 'E'
  | Order_executed_with_price _ -> 'C'
  | Order_cancel _ -> 'X'
  | Order_delete _ -> 'D'
  | Order_replace _ -> 'U'
  | Other { typ; _ } -> typ
;;

(* ---- decoding ---- *)

exception Decode_error of string

let fail fmt = Printf.ksprintf (fun s -> raise (Decode_error s)) fmt

let be buf ~pos ~len =
  let v = ref 0 in
  for i = 0 to len - 1 do
    v := (!v lsl 8) lor Char.to_int (String.unsafe_get buf (pos + i))
  done;
  !v
;;

let u16 buf pos = be buf ~pos ~len:2
let u32 buf pos = be buf ~pos ~len:4
let u48 buf pos = be buf ~pos ~len:6

let u64 buf pos =
  if Char.to_int buf.[pos] land 0x80 <> 0 then fail "u64 at %d has its top bit set" pos;
  be buf ~pos ~len:8
;;

let side_of_char = function
  | 'B' -> Buy
  | 'S' -> Sell
  | c -> fail "bad side %C" c
;;

(* Decode the message occupying [buf.[pos .. pos+len-1]]. *)
let decode buf ~pos ~len =
  if len < 1 then fail "empty message";
  let typ = buf.[pos] in
  (match length_of_type typ with
   | None -> fail "unknown message type %C" typ
   | Some l when l <> len -> fail "type %C: length %d, expected %d" typ len l
   | Some _ -> ());
  let header =
    { locate = u16 buf (pos + 1); tracking = u16 buf (pos + 3); timestamp = u48 buf (pos + 5) }
  in
  let at o = pos + o in
  let body =
    match typ with
    | 'R' ->
      Stock_directory
        { stock = String.sub buf ~pos:(at 11) ~len:8; rest = String.sub buf ~pos:(at 19) ~len:20 }
    | 'A' | 'F' ->
      Add_order
        { order_ref = u64 buf (at 11)
        ; side = side_of_char buf.[at 19]
        ; shares = u32 buf (at 20)
        ; stock = String.sub buf ~pos:(at 24) ~len:8
        ; price = u32 buf (at 32)
        ; mpid = (if Char.equal typ 'F' then Some (String.sub buf ~pos:(at 36) ~len:4) else None)
        }
    | 'E' ->
      Order_executed
        { order_ref = u64 buf (at 11); shares = u32 buf (at 19); match_number = u64 buf (at 23) }
    | 'C' ->
      Order_executed_with_price
        { order_ref = u64 buf (at 11)
        ; shares = u32 buf (at 19)
        ; match_number = u64 buf (at 23)
        ; printable = Char.equal buf.[at 31] 'Y'
        ; price = u32 buf (at 32)
        }
    | 'X' -> Order_cancel { order_ref = u64 buf (at 11); shares = u32 buf (at 19) }
    | 'D' -> Order_delete { order_ref = u64 buf (at 11) }
    | 'U' ->
      Order_replace
        { orig_ref = u64 buf (at 11)
        ; new_ref = u64 buf (at 19)
        ; shares = u32 buf (at 27)
        ; price = u32 buf (at 31)
        }
    | _ -> Other { typ; payload = String.sub buf ~pos:(at 11) ~len:(len - 11) }
  in
  { header; body }
;;

let of_string s = decode s ~pos:0 ~len:(String.length s)

(* ---- encoding (used by the packet generator and the tests) ---- *)

let put_be b ~pos ~len v =
  for i = 0 to len - 1 do
    Bytes.set b (pos + i) (Char.of_int_exn ((v lsr (8 * (len - 1 - i))) land 0xff))
  done
;;

let put_string b ~pos ~len s =
  if String.length s <> len then invalid_arg (sprintf "field %S must be %d bytes" s len);
  Bytes.From_string.blit ~src:s ~src_pos:0 ~dst:b ~dst_pos:pos ~len
;;

let to_string t =
  let typ = typ t in
  let len = Option.value_exn (length_of_type typ) in
  let b = Bytes.make len '\000' in
  Bytes.set b 0 typ;
  put_be b ~pos:1 ~len:2 t.header.locate;
  put_be b ~pos:3 ~len:2 t.header.tracking;
  put_be b ~pos:5 ~len:6 t.header.timestamp;
  (match t.body with
   | Stock_directory { stock; rest } ->
     put_string b ~pos:11 ~len:8 stock;
     put_string b ~pos:19 ~len:20 rest
   | Add_order { order_ref; side; shares; stock; price; mpid } ->
     put_be b ~pos:11 ~len:8 order_ref;
     Bytes.set b 19 (side_to_char side);
     put_be b ~pos:20 ~len:4 shares;
     put_string b ~pos:24 ~len:8 stock;
     put_be b ~pos:32 ~len:4 price;
     Option.iter mpid ~f:(put_string b ~pos:36 ~len:4)
   | Order_executed { order_ref; shares; match_number } ->
     put_be b ~pos:11 ~len:8 order_ref;
     put_be b ~pos:19 ~len:4 shares;
     put_be b ~pos:23 ~len:8 match_number
   | Order_executed_with_price { order_ref; shares; match_number; printable; price } ->
     put_be b ~pos:11 ~len:8 order_ref;
     put_be b ~pos:19 ~len:4 shares;
     put_be b ~pos:23 ~len:8 match_number;
     Bytes.set b 31 (if printable then 'Y' else 'N');
     put_be b ~pos:32 ~len:4 price
   | Order_cancel { order_ref; shares } ->
     put_be b ~pos:11 ~len:8 order_ref;
     put_be b ~pos:19 ~len:4 shares
   | Order_delete { order_ref } -> put_be b ~pos:11 ~len:8 order_ref
   | Order_replace { orig_ref; new_ref; shares; price } ->
     put_be b ~pos:11 ~len:8 orig_ref;
     put_be b ~pos:19 ~len:8 new_ref;
     put_be b ~pos:27 ~len:4 shares;
     put_be b ~pos:31 ~len:4 price
   | Other { typ = _; payload } -> put_string b ~pos:11 ~len:(len - 11) payload);
  Bytes.to_string b
;;

(* Symbols are 8 bytes, left aligned, space padded. *)
let pad_stock s =
  if String.length s > 8 then invalid_arg ("stock symbol too long: " ^ s);
  s ^ String.make (8 - String.length s) ' '
;;

let price_to_string p = sprintf "%d.%04d" (p / 10_000) (p mod 10_000)

(* ---- the binary file format Nasdaq distributes: [u16 length][message]... ---- *)
module File = struct
  (* Calls [f] on every message's raw bytes, in order. Stops cleanly at a
     truncated final message (our sample is a prefix of a full day). Returns
     the number of messages read. *)
  let iter_raw ?(max_messages = Int.max_value) file ~f =
    In_channel.with_file file ~binary:true ~f:(fun ic ->
      let hdr = Bytes.create 2 in
      let buf = Bytes.create 256 in
      let n = ref 0 in
      let rec loop () =
        if !n < max_messages
        then (
          match In_channel.really_input ic ~buf:hdr ~pos:0 ~len:2 with
          | None -> ()
          | Some () ->
            let len = (Char.to_int (Bytes.get hdr 0) lsl 8) lor Char.to_int (Bytes.get hdr 1) in
            (match In_channel.really_input ic ~buf ~pos:0 ~len with
             | None -> ()
             | Some () ->
               f (Bytes.To_string.sub buf ~pos:0 ~len);
               incr n;
               loop ()))
      in
      loop ();
      !n)
  ;;

  let iter ?max_messages file ~f = iter_raw ?max_messages file ~f:(fun s -> f (of_string s))
end
