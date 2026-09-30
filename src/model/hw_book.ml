(* Architectural model of the hardware order book.

   Same data structures, capacities, hash functions, replacement policy and
   top-of-book cache rules as the RTL in src/hw/order_book.ml, but untimed.
   It exists to (1) size the tables on real data before building hardware,
   (2) prove the architecture exact: its top-of-book events must equal the
   reference [Book]'s, and (3) give the RTL a second reference whose internal
   state (occupancy, refills, overflows) can be compared.

   Structures (see DESIGN.md for the reasoning):

   - Order table: order reference -> (level pointer, remaining shares).
     Two banks, [2^order_bucket_bits] buckets each, [ways] entries per bucket.
     A reference may live in bucket h0(ref) of bank 0 or h1(ref) of bank 1
     ("two-choice" hashing). A lookup reads both buckets at once; an insert
     goes to the bucket with more free ways (bank 0 on a tie), lowest free way.
     Orders may move during bounded cuckoo displacement; no other structure
     points to an order slot, so level pointers stored in orders stay valid.

   - Level table: (book side, price) -> aggregate shares, same organisation.
     A "book side" is (slot, side), 16 of them. Orders point at their level.

   - Top-of-book cache: per book side, up to [cache_k] (price, shares) pairs,
     best first. Invariant: the cache holds exactly the best [n] levels of its
     book side for some n (a prefix of the sorted level list). Hence the best
     level is known without any ordered structure over all levels:
       * a new level better than the worst cached one is inserted (the worst
         falls out if the cache is full); a new level worse than all cached
         ones is inserted only if the cache already holds every level;
       * an emptied level is removed from the cache if present;
       * if the cache becomes empty while the book side still has levels, it
         is refilled by scanning the level table (a rare, slow path).

   - Hash: H3 universal hashing. Bucket index bit i is the parity of
     (key AND mask_i) for fixed random masks: a GF(2) matrix product, which
     in hardware is one XOR tree per index bit and needs no multiplier. *)

open! Core

type params =
  { order_bucket_bits : int
  ; level_bucket_bits : int
  ; ways : int
  ; cache_k : int
  ; max_kicks : int
  }
[@@deriving sexp]

let default_params =
  { order_bucket_bits = 12; level_bucket_bits = 11; ways = 4; cache_k = 8; max_kicks = 32 }
;;

(* A refill starts when a book side's cache holds at most this many levels
   (half of it) while more exist. The hardware scans in the background from
   then on, so the book only stalls if the cache empties before the scan
   finishes. Measured on the full replay: starting at 4 of 8 instead of 2 of 8
   cuts the cycles commands wait for a refill from 36,411 to 10,756. *)
let refill_low_water (p : params) = Int.max 1 (p.cache_k / 2)
let banks = 2
let book_sides = 16
let order_ref_bits = 32
let order_shares_bits = 24

(* ---- H3 hashing ---- *)

(* [key_bits]-bit key -> [out_bits]-bit index for [bank]; masks from a fixed
   seed so that model and hardware agree. *)
let h3_masks ~key_bits ~out_bits ~bank =
  let st = Random.State.make [| 0x17c4; key_bits; out_bits; bank |] in
  Array.init out_bits ~f:(fun _ ->
    (* each bit of the key feeds each index bit with probability 1/2 *)
    let m = ref 0 in
    for b = 0 to key_bits - 1 do
      if Random.State.bool st then m := !m lor (1 lsl b)
    done;
    !m)
;;

let parity x = Int.popcount x land 1

let h3 masks key =
  Array.foldi masks ~init:0 ~f:(fun i acc m -> acc lor (parity (key land m) lsl i))
;;

(* level key: book side (4 bits) above the 32-bit price *)
let level_key ~bs ~price = (bs lsl 32) lor price
let level_key_bits = 36

(* ---- state ---- *)

type order =
  { oref : int
  ; ptr : int
  ; mutable shares : int
  }

type level =
  { bs : int
  ; price : int
  ; mutable lshares : int
  }

type cache_entry =
  { cprice : int
  ; mutable cshares : int
  }

type stats =
  { mutable order_overflows : int
  ; mutable level_overflows : int
  ; mutable unsupported : int (* reference >= 2^32 or shares >= 2^24 *)
  ; mutable kicks : int (* cuckoo displacements *)
  ; mutable max_kicks_seen : int
  ; mutable refills : int
  ; mutable refill_levels_found : int
  ; mutable peak_orders : int
  ; mutable peak_levels : int
  ; mutable orders : int
  ; mutable levels : int
  }
[@@deriving sexp_of]

type t =
  { p : params
  ; symbols : string array (* padded *)
  ; slot_locate : int option array
  ; orders : order option array array array (* bank, bucket, way *)
  ; levels : level option array array array
  ; omasks : int array array (* per bank *)
  ; lmasks : int array array
  ; cache : cache_entry list array (* per book side, best first *)
  ; nlevels : int array (* per book side *)
  ; stats : stats
  ; mutable victim : int (* round-robin victim way for cuckoo kicks *)
  }

let create ?(p = default_params) symbols =
  let n = List.length symbols in
  if n = 0 || n > 8 then invalid_arg "1..8 symbols";
  let table bits = Array.init banks ~f:(fun _ -> Array.init (1 lsl bits) ~f:(fun _ -> Array.create ~len:p.ways None)) in
  { p
  ; symbols = Array.of_list_map symbols ~f:Itch.pad_stock
  ; slot_locate = Array.create ~len:8 None
  ; orders = table p.order_bucket_bits
  ; levels = table p.level_bucket_bits
  ; omasks = Array.init banks ~f:(fun bank -> h3_masks ~key_bits:order_ref_bits ~out_bits:p.order_bucket_bits ~bank)
  ; lmasks = Array.init banks ~f:(fun bank -> h3_masks ~key_bits:level_key_bits ~out_bits:p.level_bucket_bits ~bank:(bank + 2))
  ; cache = Array.create ~len:book_sides []
  ; nlevels = Array.create ~len:book_sides 0
  ; stats =
      { order_overflows = 0
      ; level_overflows = 0
      ; unsupported = 0
      ; kicks = 0
      ; max_kicks_seen = 0
      ; refills = 0
      ; refill_levels_found = 0
      ; peak_orders = 0
      ; peak_levels = 0
      ; orders = 0
      ; levels = 0
      }
  ; victim = 0
  }
;;

let stats t = t.stats

(* pointer = bank | bucket | way *)
let way_bits t = Int.ceil_log2 t.p.ways
let encode_ptr t ~bank ~bucket ~way = (((bank lsl t.p.level_bucket_bits) lor bucket) lsl way_bits t) lor way

let decode_ptr t ptr =
  let way = ptr land ((1 lsl way_bits t) - 1) in
  let rest = ptr lsr way_bits t in
  rest lsr t.p.level_bucket_bits, rest land ((1 lsl t.p.level_bucket_bits) - 1), way
;;

(* Find [pred] in the two candidate buckets; else the insert position. *)
let locate_in (tbl : 'a option array array array) masks key ~pred =
  let b0 = h3 masks.(0) key and b1 = h3 masks.(1) key in
  let bucket bank = tbl.(bank).(if bank = 0 then b0 else b1) in
  let find bank =
    Array.find_mapi (bucket bank) ~f:(fun way e ->
      match e with
      | Some x when pred x -> Some (bank, (if bank = 0 then b0 else b1), way, x)
      | _ -> None)
  in
  match find 0 with
  | Some hit -> `Hit hit
  | None ->
    (match find 1 with
     | Some hit -> `Hit hit
     | None ->
       let free bank = Array.count (bucket bank) ~f:Option.is_none in
       let bank = if free 1 > free 0 then 1 else 0 in
       (match Array.findi (bucket bank) ~f:(fun _ e -> Option.is_none e) with
        | None -> `Full
        | Some (way, _) -> `Free (bank, (if bank = 0 then b0 else b1), way)))
;;

(* larger = better *)
let goodness ~bs price = if bs land 1 = 0 then price else 0xffff_ffff - price
let side_of_bs bs : Itch.side = if bs land 1 = 0 then Buy else Sell

let tob_of t slot : Book.Tob.t =
  let best bs =
    match t.cache.(bs) with
    | [] -> 0, 0
    | e :: _ -> e.cprice, e.cshares
  in
  let bid_price, bid_shares = best (2 * slot) and ask_price, ask_shares = best ((2 * slot) + 1) in
  { slot; bid_price; bid_shares; ask_price; ask_shares }
;;

(* ---- cache maintenance ---- *)

let cache_level_created t ~bs ~price ~shares =
  let k = t.p.cache_k in
  let c = t.cache.(bs) in
  let n = List.length c in
  let complete = n = t.nlevels.(bs) (* before counting the new level *) in
  let g = goodness ~bs price in
  let pos = List.count c ~f:(fun e -> goodness ~bs e.cprice > g) in
  if pos < n || (complete && n < k)
  then (
    let c = List.take c pos @ ({ cprice = price; cshares = shares } :: List.drop c pos) in
    t.cache.(bs) <- List.take c k)
;;

let cache_level_changed t ~bs ~price ~shares =
  List.iter t.cache.(bs) ~f:(fun e -> if e.cprice = price then e.cshares <- shares)
;;

let cache_level_deleted t ~bs ~price =
  t.cache.(bs) <- List.filter t.cache.(bs) ~f:(fun e -> e.cprice <> price)
;;

(* The refill scan, exactly as the hardware does it: one bucket row of each
   bank per cycle (2 x ways candidates); the best candidate of the cycle goes
   into a [cache_k]-deep insertion sorter; [discard] tracks the best level not
   kept (runners-up and sorter evictions). The result is the sorted levels
   strictly better than [discard]: a prefix, and never empty. *)
let refill t bs =
  t.stats.refills <- t.stats.refills + 1;
  let k = t.p.cache_k in
  let sorter = ref [] (* best first *) and discard = ref (-1) in
  let g (l : level) = goodness ~bs l.price in
  for bucket = 0 to (1 lsl t.p.level_bucket_bits) - 1 do
    let cands =
      List.concat_map [ 0; 1 ] ~f:(fun bank ->
        Array.to_list t.levels.(bank).(bucket)
        |> List.filter_map ~f:(function
          | Some l when l.bs = bs -> Some l
          | _ -> None))
    in
    match List.max_elt cands ~compare:(fun a b -> Int.compare (g a) (g b)) with
    | None -> ()
    | Some best ->
      List.iter cands ~f:(fun l -> if not (phys_equal l best) then discard := Int.max !discard (g l));
      let s = List.sort (best :: !sorter) ~compare:(fun a b -> Int.compare (g b) (g a)) in
      if List.length s > k then discard := Int.max !discard (g (List.last_exn s));
      sorter := List.take s k
  done;
  let kept = List.filter !sorter ~f:(fun l -> g l > !discard) in
  t.stats.refill_levels_found <- t.stats.refill_levels_found + List.length kept;
  t.cache.(bs) <- List.map kept ~f:(fun l -> { cprice = l.price; cshares = l.lshares })
;;

(* ---- operations ---- *)

let find_order t oref =
  match locate_in t.orders t.omasks oref ~pred:(fun o -> o.oref = oref) with
  | `Hit (bank, bucket, way, o) -> Some (bank, bucket, way, o)
  | _ -> None
;;

(* Remove [n] shares (all if [n] >= remaining) from an order. Returns the book side. *)
let reduce t oref n =
  match find_order t oref with
  | None -> None
  | Some (bank, bucket, way, o) ->
    let n = Int.min n o.shares in
    o.shares <- o.shares - n;
    if o.shares = 0
    then (
      t.orders.(bank).(bucket).(way) <- None;
      t.stats.orders <- t.stats.orders - 1);
    let lbank, lbucket, lway = decode_ptr t o.ptr in
    let l = Option.value_exn t.levels.(lbank).(lbucket).(lway) in
    l.lshares <- l.lshares - n;
    if l.lshares = 0
    then (
      t.levels.(lbank).(lbucket).(lway) <- None;
      t.stats.levels <- t.stats.levels - 1;
      t.nlevels.(l.bs) <- t.nlevels.(l.bs) - 1;
      cache_level_deleted t ~bs:l.bs ~price:l.price)
    else cache_level_changed t ~bs:l.bs ~price:l.price ~shares:l.lshares;
    Some l.bs
;;

(* Cuckoo insertion into the order table, used when both candidate buckets
   are full. The new entry takes a victim's place in bank [bank]; the victim
   moves to its bucket in the other bank, displacing another if that one is
   full too, for at most [max_kicks] moves. Orders can move because nothing
   points at them (levels, which orders point at, never move). *)
let cuckoo_insert t (entry : order) =
  let rec go (entry : order) bank kicks =
    if kicks > t.p.max_kicks
    then (
      (* give up: the homeless entry is lost *)
      t.stats.order_overflows <- t.stats.order_overflows + 1;
      false)
    else (
      let bucket = h3 t.omasks.(bank) entry.oref in
      let row = t.orders.(bank).(bucket) in
      match Array.findi row ~f:(fun _ e -> Option.is_none e) with
      | Some (way, _) ->
        row.(way) <- Some entry;
        t.stats.max_kicks_seen <- Int.max t.stats.max_kicks_seen kicks;
        true
      | None ->
        let way = t.victim in
        t.victim <- (t.victim + 1) % t.p.ways;
        let victim = Option.value_exn row.(way) in
        row.(way) <- Some entry;
        t.stats.kicks <- t.stats.kicks + 1;
        go victim (1 - bank) (kicks + 1))
  in
  go entry 0 1
;;

let add t ~bs ~oref ~price ~shares =
  if oref >= 1 lsl order_ref_bits || shares >= 1 lsl order_shares_bits
  then t.stats.unsupported <- t.stats.unsupported + 1
  else (
    match locate_in t.orders t.omasks oref ~pred:(fun _ -> false) with
    | `Hit _ -> assert false
    | (`Full | `Free _) as slot ->
      let key = level_key ~bs ~price in
      let ptr =
        match locate_in t.levels t.lmasks key ~pred:(fun l -> l.bs = bs && l.price = price) with
        | `Hit (bank, bucket, way, l) ->
          l.lshares <- l.lshares + shares;
          cache_level_changed t ~bs ~price ~shares:l.lshares;
          Some (encode_ptr t ~bank ~bucket ~way)
        | `Full ->
          t.stats.level_overflows <- t.stats.level_overflows + 1;
          None
        | `Free (bank, bucket, way) ->
          t.levels.(bank).(bucket).(way) <- Some { bs; price; lshares = shares };
          t.stats.levels <- t.stats.levels + 1;
          t.stats.peak_levels <- Int.max t.stats.peak_levels t.stats.levels;
          cache_level_created t ~bs ~price ~shares;
          t.nlevels.(bs) <- t.nlevels.(bs) + 1;
          Some (encode_ptr t ~bank ~bucket ~way)
      in
      Option.iter ptr ~f:(fun ptr ->
        let entry = { oref; ptr; shares } in
        let stored =
          match slot with
          | `Free (obank, obucket, oway) ->
            t.orders.(obank).(obucket).(oway) <- Some entry;
            true
          | `Full -> cuckoo_insert t entry
        in
        if stored
        then (
          t.stats.orders <- t.stats.orders + 1;
          t.stats.peak_orders <- Int.max t.stats.peak_orders t.stats.orders)))
;;

let slot_of_locate t locate =
  Array.findi t.slot_locate ~f:(fun _ l -> Option.equal Int.equal l (Some locate)) |> Option.map ~f:fst
;;

(* Same contract as [Book.apply]. *)
let apply t (msg : Itch.t) =
  match msg.body with
  | Stock_directory { stock; _ } ->
    Array.iteri t.symbols ~f:(fun s sym ->
      if String.equal sym stock then t.slot_locate.(s) <- Some msg.header.locate);
    None
  | Other _ -> None
  | _ ->
    (match slot_of_locate t msg.header.locate with
     | None -> None
     | Some slot ->
       let before = tob_of t slot in
       let touched =
         match msg.body with
         | Add_order { order_ref; side; shares; price; _ } ->
           let bs = (2 * slot) + if Itch.equal_side side Sell then 1 else 0 in
           add t ~bs ~oref:order_ref ~price ~shares;
           Some bs
         | Order_executed { order_ref; shares; _ }
         | Order_executed_with_price { order_ref; shares; _ }
         | Order_cancel { order_ref; shares } -> reduce t order_ref shares
         | Order_delete { order_ref } -> reduce t order_ref Int.max_value
         | Order_replace { orig_ref; new_ref; shares; price } ->
           (match reduce t orig_ref Int.max_value with
            | None -> None
            | Some bs ->
              add t ~bs ~oref:new_ref ~price ~shares;
              Some bs)
         | Stock_directory _ | Other _ -> None
       in
       Option.iter touched ~f:(fun bs ->
         let cached = List.length t.cache.(bs) in
         if t.nlevels.(bs) > cached && cached <= refill_low_water t.p then refill t bs);
       let now = tob_of t slot in
       if Book.Tob.equal before now then None else Some now)
;;
