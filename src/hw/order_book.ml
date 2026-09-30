(* The hardware order book. The architecture, and the reasons for it, are
   described in src/model/hw_book.ml (a bit-exact untimed model of this
   module) and DESIGN.md. In short:

   - order table   ref -> (level pointer, shares)      BRAM, 2 banks x buckets x ways,
                                                       two-choice + cuckoo displacement
   - level table   (book side, price) -> shares        BRAM, 2 banks x buckets x ways,
                                                       two-choice, entries never move
   - top-of-book   per book side, the best [cache_k]   registers; exact prefix of the
     cache         levels, sorted                      sorted level list; refilled by a
                                                       level-table scan when it drains

   Commands arrive from [Symbol_filter] through a FIFO and are processed one
   at a time by the state machine below; every memory access is a whole
   bucket (all ways) so a lookup is one BRAM read per bank, in parallel.

     Add           Idle Rd_order Order_data Add_write [kicks] Cache_rd
                   Cache_cmp Cache_prefix Cache_wr Finish Emit
     Exec/Cancel/  Idle Rd_order Order_data Rd_level Level_data Level_write
       Delete        Cache_rd Cache_cmp Cache_prefix Cache_wr Finish Emit
     Replace       as Delete, then as Add (same book side, new reference)
     refill        Finish -> Refill (one bucket row of each bank per cycle) -> Emit

   Each command produces one [event] (valid for one cycle) with the symbol's
   top of book after the command, and [changed] set if it differs from before.

   Every memory write is preceded, in an earlier state, by a read of the same
   row, whose value the BRAM output register holds (reads are only enabled
   when issued); commands are not overlapped, so there are no hazards. *)

open! Core
open! Hardcaml
open Signal
module Params = Itch_model.Hw_book

let book_sides = 16
let bs_bits = 4
let ref_bits = 32
let shares_bits = 24 (* per order *)
let level_shares_bits = 32
let price_bits = 32

module Event = struct
  type 'a t =
    { valid : 'a
    ; changed : 'a
    ; seq : 'a [@bits 64]
    ; slot : 'a [@bits 3]
    ; bid_price : 'a [@bits 32]
    ; bid_shares : 'a [@bits 32]
    ; ask_price : 'a [@bits 32]
    ; ask_shares : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module Stats = struct
  type 'a t =
    { processed : 'a [@bits 32]
    ; unsupported : 'a [@bits 32]
    ; order_overflows : 'a [@bits 32]
    ; level_overflows : 'a [@bits 32]
    ; kicks : 'a [@bits 32]
    ; max_kicks : 'a [@bits 8]
    ; refills : 'a [@bits 32]
    ; refill_levels : 'a [@bits 32]
    ; refill_stall_cycles : 'a [@bits 32] (* cycles a command waited for a refill *)
    ; orders : 'a [@bits 20]
    ; levels : 'a [@bits 20]
    ; fifo_overflows : 'a [@bits 32]
    ; fifo_max_used : 'a [@bits 16]
    ; debug_state : 'a [@bits 8] (* state machine's current state, for board bring-up *)
    ; debug_fifo_empty : 'a
    }
  [@@deriving hardcaml]
end

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; cmd : 'a Symbol_filter.Command.t [@rtlmangle "_"]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { event : 'a Event.t [@rtlmangle "_"]
    ; stats : 'a Stats.t [@rtlmangle "_"]
    }
  [@@deriving hardcaml]
end

module State = struct
  (* [Init] must stay first: it is the state after [clear] *)
  type t =
    | Init
    | Idle
    | Rd_order
    | Order_wait
    | Order_data
    | Add_write
    | Kick_rd
    | Kick_wait
    | Kick_data
    | Rd_level
    | Level_wait
    | Level_data
    | Level_write
    | Cache_rd
    | Cache_cmp
    | Cache_prefix
    | Cache_wr
    | Finish
    | Wait_refill
    | Merge_rd
    | Merge_cmp
    | Merge_wr
    | Emit
  [@@deriving sexp_of, compare ~localize, enumerate]
end

(* ---- table entries ---- *)

let way_bits (p : Params.params) = Int.ceil_log2 p.ways
let ptr_bits (p : Params.params) = 1 + p.level_bucket_bits + way_bits p

module Oe = struct
  (* order entry: valid | ref | level pointer | shares *)
  type t =
    { valid : Signal.t
    ; oref : Signal.t
    ; ptr : Signal.t
    ; shares : Signal.t
    }

  let width p = 1 + ref_bits + ptr_bits p + shares_bits
  let pack e = concat_msb [ e.valid; e.oref; e.ptr; e.shares ]

  let unpack p s =
    let pb = ptr_bits p in
    { valid = msb s
    ; oref = select s ~high:(width p - 2) ~low:(pb + shares_bits)
    ; ptr = select s ~high:(pb + shares_bits - 1) ~low:shares_bits
    ; shares = sel_bottom s ~width:shares_bits
    }
  ;;
end

module Le = struct
  (* level entry: valid | book side | price | shares *)
  type t =
    { valid : Signal.t
    ; bs : Signal.t
    ; price : Signal.t
    ; shares : Signal.t
    }

  let width = 1 + bs_bits + price_bits + level_shares_bits
  let pack e = concat_msb [ e.valid; e.bs; e.price; e.shares ]

  let unpack s =
    { valid = msb s
    ; bs = select s ~high:(width - 2) ~low:(price_bits + level_shares_bits)
    ; price = select s ~high:(price_bits + level_shares_bits - 1) ~low:level_shares_bits
    ; shares = sel_bottom s ~width:level_shares_bits
    }
  ;;
end

let split_row row ~ways ~entry_width =
  List.init ways ~f:(fun w -> select row ~high:(((w + 1) * entry_width) - 1) ~low:(w * entry_width))
;;

(* replace way [way] of [row] with [entry] *)
let set_way row ~ways ~entry_width ~way entry =
  split_row row ~ways ~entry_width
  |> List.mapi ~f:(fun w e -> mux2 (way ==:. w) entry e)
  |> concat_lsb
;;

(* H3 hash: index bit i = XOR of the key bits selected by mask i *)
let h3 masks key =
  Array.to_list masks
  |> List.map ~f:(fun m ->
    List.init (Signal.width key) ~f:(fun b -> if m land (1 lsl b) <> 0 then Some (bit key ~pos:b) else None)
    |> List.filter_opt
    |> function
    | [] -> gnd
    | bits -> List.reduce_exn bits ~f:( ^: ))
  |> concat_lsb
;;

(* lowest set bit of a small vector, as an index *)
let lowest_set v =
  let n = Signal.width v in
  List.init n ~f:(fun i -> i)
  |> List.rev
  |> List.fold ~init:(zero (Int.max 1 (Int.ceil_log2 n))) ~f:(fun acc i ->
    mux2 (bit v ~pos:i) (of_unsigned_int ~width:(Int.max 1 (Int.ceil_log2 n)) i) acc)
;;

let popcount v = List.map (bits_lsb v) ~f:(fun b -> uresize b ~width:(num_bits_to_represent (Signal.width v))) |> List.reduce_exn ~f:( +: )

(* larger is better: bids by price, asks by inverted price *)
let goodness ~sell price = mux2 sell ~:price price

(* valid-tagged max, used by the refill tournament *)
let vmax (v1, k1) (v2, k2) =
  let first = v1 &: (~:v2 |: (k1 >: k2)) in
  v1 |: v2, mux2 first k1 k2
;;

let create ?(p = Params.default_params) ?(fifo_capacity = 512) scope (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let ways = p.ways and k = p.cache_k in
  let wb = way_bits p in
  let ob = p.order_bucket_bits and lb = p.level_bucket_bits in
  let oe_w = Oe.width p in
  let omasks = Array.init 2 ~f:(fun bank -> Params.h3_masks ~key_bits:ref_bits ~out_bits:ob ~bank) in
  let lmasks =
    Array.init 2 ~f:(fun bank ->
      Params.h3_masks ~key_bits:Params.level_key_bits ~out_bits:lb ~bank:(bank + 2))
  in
  let open Always in
  (* registers are named so that timing reports say which one is slow *)
  let var_reg ?name ?(w = 1) () =
    let v = Variable.reg spec ~width:w in
    Option.iter name ~f:(fun n -> ignore (v.value -- n : Signal.t));
    v
  in
  let incr (v : Variable.t) = v <-- v.value +:. 1 in
  (* ---- input FIFO ---- *)
  let cmd = i.cmd in
  let ref_ok r = select r ~high:63 ~low:32 ==:. 0 in
  let fifo_d =
    concat_msb
      [ cmd.kind
      ; cmd.slot
      ; ref_ok cmd.order_ref
      ; sel_bottom cmd.order_ref ~width:32
      ; ref_ok cmd.new_ref
      ; sel_bottom cmd.new_ref ~width:32
      ; cmd.sell
      ; cmd.shares
      ; cmd.price
      ; cmd.seq
      ]
  in
  let fifo_rd = Variable.wire ~default:gnd () in
  let fifo =
    Fifo.create
      ~showahead:true
      ~scope
      ()
      ~capacity:fifo_capacity
      ~clock:i.clock
      ~clear:i.clear
      ~wr:cmd.valid
      ~d:fifo_d
      ~rd:fifo_rd.value
  in
  let q = fifo.q in
  let q_field ~high ~low = select q ~high ~low in
  let qw = Signal.width q in
  let q_kind = q_field ~high:(qw - 1) ~low:(qw - 3) in
  let q_slot = q_field ~high:(qw - 4) ~low:(qw - 6) in
  let q_ref_ok = bit q ~pos:(qw - 7) in
  let q_ref = q_field ~high:(qw - 8) ~low:(qw - 39) in
  let q_new_ok = bit q ~pos:(qw - 40) in
  let q_new_ref = q_field ~high:(qw - 41) ~low:(qw - 72) in
  let q_sell = bit q ~pos:(qw - 73) in
  let q_shares = q_field ~high:(qw - 74) ~low:(qw - 105) in
  let q_price = q_field ~high:(qw - 106) ~low:(qw - 137) in
  let q_seq = q_field ~high:(qw - 138) ~low:0 in
  let kind_is k s = s ==: Itch_decoder.Kind.const k in
  (* ---- command registers ---- *)
  let c_kind = var_reg ~name:"ob_c_kind" ~w:3 () in
  let c_slot = var_reg ~name:"ob_c_slot" ~w:3 () in
  let c_new_ok = var_reg ~name:"ob_c_new_ok" () in
  let c_new_ref = var_reg ~name:"ob_c_new_ref" ~w:32 () in
  let c_shares = var_reg ~name:"ob_c_shares" ~w:32 () in
  let c_price = var_reg ~name:"ob_c_price" ~w:32 () in
  let c_seq = var_reg ~name:"ob_c_seq" ~w:64 () in
  let phase_b = var_reg ~name:"ob_phase_b" () in
  (* the order reference, book side, price and shares of the current phase *)
  let key_ref = var_reg ~name:"ob_key_ref" ~w:ref_bits () in
  let bs = var_reg ~name:"ob_bs" ~w:bs_bits () in
  let a_price = var_reg ~name:"ob_a_price" ~w:price_bits () in
  let a_shares = var_reg ~name:"ob_a_shares" ~w:shares_bits () in
  let tob_before = var_reg ~name:"ob_tob_before" ~w:128 () in
  (* ---- memories ---- *)
  (* Memories deeper than [max_bram_depth] are built from 2048-deep pieces:
     on the openXC7 flow, a 4096-deep table is mapped to RAMB36E1 in 4K x 9
     mode, whose parity bits read back wrong on odd addresses on silicon
     (found with src/hw/bram_probe.ml), while 2K x 9 RAMB18E1 is correct.
     The piece is selected by the top address bits; the read-side selection
     is registered with the read enable, so the output still holds between
     reads exactly like a single RAM. *)
  let max_bram_depth = 2048 in
  let mem ~name ~depth ~width =
    let ab = Int.ceil_log2 depth in
    let r_en = Variable.wire ~default:gnd () in
    let r_addr = Variable.wire ~default:(zero ab) () in
    let w_en = Variable.wire ~default:gnd () in
    let w_addr = Variable.wire ~default:(zero ab) () in
    let w_data = Variable.wire ~default:(zero width) () in
    let pieces = Int.max 1 (depth / max_bram_depth) in
    let piece_depth = depth / pieces in
    let pb = Int.ceil_log2 piece_depth in
    let low a = sel_bottom a ~width:pb in
    let high a = if pieces = 1 then gnd else drop_bottom a ~width:pb in
    let q_of k =
      ram_rbw
        ~name:(if pieces = 1 then name else sprintf "%s_%d" name k)
        ~write_port:
          { write_clock = i.clock
          ; write_address = low w_addr.value
          ; write_enable = w_en.value &: (high w_addr.value ==:. k)
          ; write_data = w_data.value
          }
        ~read_port:{ read_clock = i.clock; read_address = low r_addr.value; read_enable = r_en.value }
        piece_depth
    in
    let q =
      if pieces = 1
      then q_of 0
      else (
        let sel = reg spec ~enable:r_en.value (high r_addr.value) in
        mux sel (List.init pieces ~f:q_of))
    in
    (r_en, r_addr, w_en, w_addr, w_data), q
  in
  let omem = Array.init 2 ~f:(fun b -> mem ~name:(sprintf "order_bank%d" b) ~depth:(1 lsl ob) ~width:(ways * oe_w)) in
  let lmem = Array.init 2 ~f:(fun b -> mem ~name:(sprintf "level_bank%d" b) ~depth:(1 lsl lb) ~width:(ways * Le.width)) in
  let read (((r_en : Variable.t), (r_addr : Variable.t), _, _, _), _) addr = [ r_en <-- vdd; r_addr <-- addr ] in
  let write ((_, _, (w_en : Variable.t), (w_addr : Variable.t), (w_data : Variable.t)), _) addr data =
    [ w_en <-- vdd; w_addr <-- addr; w_data <-- data ]
  in
  (* BRAM rows, registered: a 4096-deep row is 8 BRAMs deep plus an output
     multiplexer, too slow to compare against in the same cycle. The BRAM
     output holds while no read is issued, so these hold too. *)
  let orow_r = Array.init 2 ~f:(fun b -> reg spec (snd omem.(b))) in
  let lrow_r = Array.init 2 ~f:(fun b -> reg spec (snd lmem.(b))) in
  let orow b = orow_r.(b) and lrow b = lrow_r.(b) in
  let orows = Array.init 2 ~f:(fun b -> split_row (orow b) ~ways ~entry_width:oe_w |> List.map ~f:(Oe.unpack p)) in
  let lrows = Array.init 2 ~f:(fun b -> split_row (lrow b) ~ways ~entry_width:Le.width |> List.map ~f:Le.unpack) in
  let obucket b key = h3 omasks.(b) key in
  let lkey = bs.value @: a_price.value in
  let lbucket b = h3 lmasks.(b) lkey in
  (* free ways in a row, and the insert choice: bank with more free ways (bank 0 on a tie), lowest free way *)
  let free_vec entries = concat_lsb (List.map entries ~f:(fun (e : Oe.t) -> ~:(e.valid))) in
  let lfree_vec entries = concat_lsb (List.map entries ~f:(fun (e : Le.t) -> ~:(e.valid))) in
  let choose_free f0 f1 =
    let use1 = popcount f1 >: popcount f0 in
    let any = f0 <>:. 0 |: (f1 <>:. 0) in
    any, use1, mux2 use1 (lowest_set f1) (lowest_set f0)
  in
  (* ---- order lookup / insert results (Order_data) ---- *)
  let o_hit = var_reg ~name:"ob_o_hit" () and o_bank = var_reg ~name:"ob_o_bank" () and o_way = var_reg ~name:"ob_o_way" ~w:wb () in
  let o_ptr = var_reg ~w:(ptr_bits p) () and o_shares = var_reg ~name:"ob_o_shares" ~w:shares_bits () in
  let o_free = var_reg ~name:"ob_o_free" () and o_free_bank = var_reg ~name:"ob_o_free_bank" () and o_free_way = var_reg ~name:"ob_o_free_way" ~w:wb () in
  let l_hit = var_reg ~name:"ob_l_hit" () and l_bank = var_reg ~name:"ob_l_bank" () and l_way = var_reg ~name:"ob_l_way" ~w:wb () in
  let l_shares = var_reg ~name:"ob_l_shares" ~w:level_shares_bits () in
  let l_free = var_reg ~name:"ob_l_free" () and l_free_bank = var_reg ~name:"ob_l_free_bank" () and l_free_way = var_reg ~name:"ob_l_free_way" ~w:wb () in
  let hits_o b = concat_lsb (List.map orows.(b) ~f:(fun e -> e.valid &: (e.oref ==: key_ref.value))) in
  let hits_l b =
    concat_lsb (List.map lrows.(b) ~f:(fun e -> e.valid &: (e.bs ==: bs.value) &: (e.price ==: a_price.value)))
  in
  let pick_entry entries way = mux way entries in
  let oe_field f b way = mux way (List.map orows.(b) ~f) in
  (* ---- cuckoo state ---- *)
  let homeless = var_reg ~name:"ob_homeless" ~w:oe_w () in
  let kick_bank = var_reg ~name:"ob_kick_bank" () in
  let kick_n = var_reg ~name:"ob_kick_n" ~w:8 () in
  let victim = var_reg ~name:"ob_victim" ~w:wb () in
  (* ---- level update (Level_data -> Level_write) ---- *)
  let lv_entry = var_reg ~name:"ob_lv_entry" ~w:Le.width () in
  let lv_n = var_reg ~name:"ob_lv_n" ~w:shares_bits () in
  (* ---- top-of-book cache ----
     One row per book side in LUT RAM (16 deep, asynchronous read): [k]
     entries of (valid, price, shares), best first. A copy of each row's best
     entry is kept in registers for the top-of-book output. *)
  let ce_w = 1 + price_bits + level_shares_bits in
  let row_w = k * ce_w in
  let cache_we = Variable.wire ~default:gnd () in
  let cache_wdata = Variable.wire ~default:(zero row_w) () in
  let cache_row =
    (multiport_memory
       book_sides
       ~write_ports:
         [| { write_clock = i.clock
            ; write_address = bs.value
            ; write_enable = cache_we.value
            ; write_data = cache_wdata.value
            }
         |]
       ~read_addresses:[| bs.value |]).(0)
  in
  let unpack_entry e =
    msb e, select e ~high:(ce_w - 2) ~low:level_shares_bits, sel_bottom e ~width:level_shares_bits
  in
  let row_entries row = split_row row ~ways:k ~entry_width:ce_w |> List.map ~f:unpack_entry |> Array.of_list in
  let tob_v = Array.init book_sides ~f:(fun _ -> var_reg ()) in
  let tob_p = Array.init book_sides ~f:(fun _ -> var_reg ~w:price_bits ()) in
  let tob_s = Array.init book_sides ~f:(fun _ -> var_reg ~w:level_shares_bits ()) in
  let write_row entries =
    let (v0, p0, s0) = entries.(0) in
    [ cache_we <-- vdd
    ; cache_wdata <-- concat_lsb (Array.to_list (Array.map entries ~f:(fun (v, pr, sh) -> concat_msb [ v; pr; sh ]))) ]
    @ List.init book_sides ~f:(fun b ->
      when_
        (bs.value ==:. b)
        [ tob_v.(b) <-- v0
        ; tob_p.(b) <-- mux2 v0 p0 (zero price_bits)
        ; tob_s.(b) <-- mux2 v0 s0 (zero level_shares_bits)
        ])
  in
  let nlevels = Array.init book_sides ~f:(fun _ -> var_reg ~w:20 ()) in
  let nlevels_of_bs = mux bs.value (Array.to_list (Array.map nlevels ~f:(fun v -> v.value))) in
  (* pending cache operation: 0 none, 1 created, 2 changed, 3 deleted *)
  let op = var_reg ~name:"ob_op" ~w:2 () and op_price = var_reg ~name:"ob_op_price" ~w:price_bits () and op_shares = var_reg ~name:"ob_op_shares" ~w:level_shares_bits () in
  let row = var_reg ~name:"ob_row" ~w:row_w () in
  let row_nl = var_reg ~name:"ob_row_nl" ~w:20 () in
  let better_r = var_reg ~name:"ob_better_r" ~w:k () and match_r = var_reg ~name:"ob_match_r" ~w:k () in
  let upto_r = var_reg ~name:"ob_upto_r" ~w:k () and insert_ok_r = var_reg ~name:"ob_insert_ok_r" () in
  let prefix_group = 8 in
  let group_count = (k + prefix_group - 1) / prefix_group in
  let group_r = var_reg ~name:"ob_group_r" ~w:group_count () in
  let tob_of_slot slot =
    let side sell =
      let pick (a : Variable.t array) = mux slot (List.init 8 ~f:(fun s -> a.((2 * s) + sell).value)) in
      pick tob_p, pick tob_s
    in
    let bp, bsh = side 0 and ap, ash = side 1 in
    concat_msb [ bp; bsh; ap; ash ]
  in
  (* ---- refill scan ---- *)
  let scan_idx = var_reg ~w:(lb + 1) () in
  let sorter_v = Array.init k ~f:(fun j -> var_reg ~name:(sprintf "ob_sorter_v_%d" j) ()) in
  let sorter_k = Array.init k ~f:(fun j -> var_reg ~name:(sprintf "ob_sorter_k_%d" j) ~w:32 ()) in
  let sorter_p = Array.init k ~f:(fun j -> var_reg ~name:(sprintf "ob_sorter_p_%d" j) ~w:price_bits ()) in
  let sorter_s = Array.init k ~f:(fun j -> var_reg ~name:(sprintf "ob_sorter_s_%d" j) ~w:level_shares_bits ()) in
  (* best level not kept: runners-up and evictions are tracked separately
     (one comparison each per cycle) and merged at the end *)
  let disc_v = var_reg ~name:"ob_disc_v" () and disc_k = var_reg ~name:"ob_disc_k" ~w:32 () in
  (* Merge_cmp -> Merge_wr: which sorter entries survive, and whether they
     beat the cached prefix (registered: the compares and popcounts are too
     slow to drive the cache write enable in the same cycle) *)
  let kept_r = var_reg ~name:"ob_kept" ~w:k () and take_r = var_reg ~name:"ob_take" () in
  let ev_v = var_reg ~name:"ob_ev_v" () and ev_k = var_reg ~name:"ob_ev_k" ~w:32 () in
  (* an eviction is registered here first and folded into [ev] the next
     cycle: choosing the evicted key and taking the maximum are two 32-bit
     comparisons, too many for one 8 ns cycle *)
  let pe_v = var_reg ~name:"ob_pe_v" () and pe_k = var_reg ~name:"ob_pe_k" ~w:32 () in
  let scanning = Variable.wire ~default:gnd () in
  (* Background refill. [scan_active]: a scan of the level table for book
     side [rbs] is running or finished and waiting to be merged ([scan_done]).
     [waiting]: the current command's book side [w_bs] has an empty cache and
     the command waits for its refill. *)
  let scan_active = var_reg ~name:"ob_scan_active" () and scan_done = var_reg ~name:"ob_scan_done" () in
  let rbs = var_reg ~name:"ob_rbs" ~w:bs_bits () in
  let drain = var_reg ~name:"ob_drain" ~w:4 () in
  let waiting = var_reg ~name:"ob_waiting" () and w_bs = var_reg ~name:"ob_w_bs" ~w:bs_bits () in
  let low_water = Params.refill_low_water p in
  (* the pending cache operation, as seen by the sorter: computed in
     Cache_prefix, applied in Cache_wr *)
  let so_match = var_reg ~name:"ob_so_match" ~w:k () and so_better = var_reg ~name:"ob_so_better" ~w:k () in
  (* ---- statistics ---- *)
  let st_processed = var_reg ~name:"ob_st_processed" ~w:32 () in
  let st_unsupported = var_reg ~name:"ob_st_unsupported" ~w:32 () in
  let st_oovf = var_reg ~name:"ob_st_oovf" ~w:32 () in
  let st_lovf = var_reg ~name:"ob_st_lovf" ~w:32 () in
  let st_kicks = var_reg ~name:"ob_st_kicks" ~w:32 () in
  let st_max_kicks = var_reg ~name:"ob_st_max_kicks" ~w:8 () in
  let st_refills = var_reg ~name:"ob_st_refills" ~w:32 () in
  let st_refill_levels = var_reg ~name:"ob_st_refill_levels" ~w:32 () in
  let st_stall = var_reg ~name:"ob_st_stall" ~w:32 () in
  let st_orders = var_reg ~name:"ob_st_orders" ~w:20 () in
  let st_levels = var_reg ~name:"ob_st_levels" ~w:20 () in
  let ev = Event.Of_always.reg spec in
  let sm = State_machine.create (module State) spec in
  (* after [clear], zero both tables and the cache rows: a reset does not
     clear BRAM contents (only FPGA configuration does) *)
  let init_bits = Int.max 4 (Int.max ob lb) (* >= 16 cycles for the cache rows *) in
  let init_idx = var_reg ~w:(init_bits + 1) () in
  (* --- the refill pipeline runs whenever [scanning]; see below --- *)
  let sell_of_bs = lsb bs.value in
  (* level row i of the scan: both banks' entries that belong to [rbs] *)
  let scan_cands =
    List.concat_map [ 0; 1 ] ~f:(fun b ->
      List.map lrows.(b) ~f:(fun (e : Le.t) ->
        e.valid &: (e.bs ==: rbs.value), goodness ~sell:(lsb rbs.value) e.price, e.price, e.shares))
  in
  (* pipeline stage A: register the candidates *)
  let scan_valid_a = reg spec (reg spec (reg spec scanning.value)) in
  let stage_a =
    List.map scan_cands ~f:(fun (v, key, pr, sh) -> reg spec v, reg spec key, reg spec pr, reg spec sh)
  in
  (* tournament, one registered level per pairwise round: (best, second) *)
  let leaf (v, key, pr, sh) = (v, key, pr, sh), (gnd, zero 32) in
  let combine ((bv1, bk1, bp1, bs1), s1) ((bv2, bk2, bp2, bs2), s2) =
    let first = bv1 &: (~:bv2 |: (bk1 >: bk2)) in
    let best = mux2 first bv1 bv2, mux2 first bk1 bk2, mux2 first bp1 bp2, mux2 first bs1 bs2 in
    let loser = mux2 first bv2 bv1, mux2 first bk2 bk1 in
    best, vmax (vmax s1 s2) loser
  in
  let reg_node ((bv, bk, bp, bs'), (sv, sk)) =
    (reg spec bv, reg spec bk, reg spec bp, reg spec bs'), (reg spec sv, reg spec sk)
  in
  let rec tournament nodes valid =
    match nodes with
    | [ n ] -> n, valid
    | _ ->
      let rec pairs = function
        | a :: b :: rest -> combine a b :: pairs rest
        | [ a ] -> [ a ]
        | [] -> []
      in
      tournament (List.map (pairs nodes) ~f:reg_node) (reg spec valid)
  in
  let ((w_v, w_k, w_p, w_s), (sec_v, sec_k)), win_valid = tournament (List.map stage_a ~f:leaf) scan_valid_a in
  let win_v = w_v &: win_valid in
  let sec_v = sec_v &: win_valid in
  (* sorter insert position and eviction *)
  let s_better = Array.init k ~f:(fun j -> sorter_v.(j).value &: (sorter_k.(j).value >: w_k)) in
  let s_full = sorter_v.(k - 1).value in
  (* a level already in the sorter (a concurrent Add put it there, or the
     scan re-reads a row it changed) is updated, not inserted twice *)
  let w_dup = Array.init k ~f:(fun j -> sorter_v.(j).value &: (sorter_p.(j).value ==: w_p)) in
  let any_w_dup = Array.to_list w_dup |> List.reduce_exn ~f:( |: ) in
  let evict_v = s_full &: win_v &: ~:any_w_dup in
  let evict_k = mux2 s_better.(k - 1) w_k sorter_k.(k - 1).value in
  let pipeline_depth = 3 + Int.ceil_log2 (2 * ways) in
  (* sorter update for a winner: entries better than it stay, it goes at the
     first position where the entry is not better, the rest shift down *)
  let sorter_updates =
    List.concat
      (List.init k ~f:(fun j ->
         let take_winner = (if j = 0 then vdd else s_better.(j - 1)) &: ~:(s_better.(j)) in
         when_
           take_winner
           [ sorter_v.(j) <-- vdd; sorter_k.(j) <-- w_k; sorter_p.(j) <-- w_p; sorter_s.(j) <-- w_s ]
         ::
         (if j = 0
          then []
          else
            [ when_
                ~:(s_better.(j - 1))
                [ sorter_v.(j) <-- sorter_v.(j - 1).value
                ; sorter_k.(j) <-- sorter_k.(j - 1).value
                ; sorter_p.(j) <-- sorter_p.(j - 1).value
                ; sorter_s.(j) <-- sorter_s.(j - 1).value
                ]
            ])))
  in
  let discard_v, discard_k = vmax (disc_v.value, disc_k.value) (sec_v, sec_k) in
  let evicted_v, evicted_k = vmax (ev_v.value, ev_k.value) (pe_v.value, pe_k.value) in
  let start_scan b =
    [ rbs <-- b
    ; scan_active <-- vdd
    ; scan_done <-- gnd
    ; scan_idx <--. 0
    ; drain <--. 0
    ; disc_v <-- gnd
    ; ev_v <-- gnd
    ; pe_v <-- gnd
    ; incr st_refills
    ]
    @ List.init k ~f:(fun j -> sorter_v.(j) <-- gnd)
  in
  (* The scanner reads the level table only between commands: the command
     states rely on the BRAM output holding the row they read until they
     write it back. Rows in flight land within [pipeline_depth] cycles, before
     any following command's cache update (>= 8 cycles after its pop), so a
     concurrent change is always applied to the sorter after the stale row. *)
  let scan_ok = sm.is Idle |: sm.is Finish |: sm.is Emit |: sm.is Wait_refill in
  let issuing = scan_active.value &: ~:(scan_done.value) &: (msb scan_idx.value ==:. 0) &: scan_ok in
  let scan_addr = sel_bottom scan_idx.value ~width:lb in
  compile
    [ when_
        issuing
        [ proc (read lmem.(0) scan_addr)
        ; proc (read lmem.(1) scan_addr)
        ; scanning <-- vdd
        ; scan_idx <-- scan_idx.value +:. 1
        ]
    ; when_
        (scan_active.value &: ~:(scan_done.value) &: msb scan_idx.value)
        [ drain <-- drain.value +:. 1
        ; when_ (drain.value ==:. pipeline_depth + 2) [ scan_done <-- vdd ]
        ]
    ; when_
        win_v
        [ if_
            any_w_dup
            (List.init k ~f:(fun j -> when_ w_dup.(j) [ sorter_s.(j) <-- w_s ]))
            sorter_updates
        ]
    ; when_ sec_v [ disc_v <-- discard_v; disc_k <-- discard_k ]
    ; pe_v <-- evict_v
    ; pe_k <-- evict_k
    ; when_ pe_v.value [ ev_v <-- evicted_v; ev_k <-- evicted_k ]
    ; sm.switch
        [ ( Init
          , (let a = sel_bottom init_idx.value ~width:init_bits in
             [ when_ (init_idx.value <:. 1 lsl ob) [ proc (write omem.(0) (sel_bottom a ~width:ob) (zero (ways * oe_w))) ; proc (write omem.(1) (sel_bottom a ~width:ob) (zero (ways * oe_w))) ]
             ; when_ (init_idx.value <:. 1 lsl lb) [ proc (write lmem.(0) (sel_bottom a ~width:lb) (zero (ways * Le.width))) ; proc (write lmem.(1) (sel_bottom a ~width:lb) (zero (ways * Le.width))) ]
             ; (* cache rows are addressed by [bs] *)
               cache_we <-- vdd
             ; cache_wdata <-- zero row_w
             ; bs <-- bs.value +:. 1
             ; init_idx <-- init_idx.value +:. 1
             ; when_ (init_idx.value ==:. (1 lsl init_bits) - 1) [ bs <--. 0; sm.set_next Idle ]
             ]) )
        ; ( Idle
          , [ if_
                scan_done.value
                [ sm.set_next Merge_rd ]
                [ when_
                ~:(fifo.empty)
                [ fifo_rd <-- vdd
                ; c_kind <-- q_kind
                ; c_slot <-- q_slot
                ; c_new_ok <-- q_new_ok
                ; c_new_ref <-- q_new_ref
                ; c_shares <-- q_shares
                ; c_price <-- q_price
                ; c_seq <-- q_seq
                ; phase_b <-- gnd
                ; key_ref <-- q_ref
                ; bs <-- q_slot @: q_sell
                ; a_price <-- q_price
                ; a_shares <-- sel_bottom q_shares ~width:shares_bits
                ; op <--. 0
                ; tob_before <-- tob_of_slot q_slot
                ; if_
                    (kind_is Add q_kind &: (~:q_ref_ok |: (select q_shares ~high:31 ~low:shares_bits <>:. 0)))
                    [ incr st_unsupported; sm.set_next Finish ]
                    [ if_ q_ref_ok [ sm.set_next Rd_order ] [ sm.set_next Finish ] ]
                ]
                ]
            ] )
        ; ( Rd_order
          , [ proc (read omem.(0) (obucket 0 key_ref.value))
            ; proc (read omem.(1) (obucket 1 key_ref.value))
            ; proc (read lmem.(0) (lbucket 0))
            ; proc (read lmem.(1) (lbucket 1))
            ; sm.set_next Order_wait
            ] )
        ; Order_wait, [ sm.set_next Order_data ]
        ; ( Order_data
          , (let h0 = hits_o 0 and h1 = hits_o 1 in
             let hit_bank = h0 ==:. 0 in
             let hit_way = mux2 hit_bank (lowest_set h1) (lowest_set h0) in
             let any, use1, fway = choose_free (free_vec orows.(0)) (free_vec orows.(1)) in
             let lh0 = hits_l 0 and lh1 = hits_l 1 in
             let lany, luse1, lfway = choose_free (lfree_vec lrows.(0)) (lfree_vec lrows.(1)) in
             let lhit_bank = lh0 ==:. 0 in
             let lhit_way = mux2 lhit_bank (lowest_set lh1) (lowest_set lh0) in
             [ o_hit <-- (h0 <>:. 0 |: (h1 <>:. 0))
             ; o_bank <-- hit_bank
             ; o_way <-- hit_way
             ; o_ptr <-- mux2 hit_bank (oe_field (fun e -> e.ptr) 1 hit_way) (oe_field (fun e -> e.ptr) 0 hit_way)
             ; o_shares
               <-- mux2 hit_bank (oe_field (fun e -> e.shares) 1 hit_way) (oe_field (fun e -> e.shares) 0 hit_way)
             ; o_free <-- any
             ; o_free_bank <-- use1
             ; o_free_way <-- fway
             ; l_hit <-- (lh0 <>:. 0 |: (lh1 <>:. 0))
             ; l_bank <-- lhit_bank
             ; l_way <-- lhit_way
             ; l_shares
               <-- mux2
                     lhit_bank
                     (pick_entry (List.map lrows.(1) ~f:(fun e -> e.shares)) lhit_way)
                     (pick_entry (List.map lrows.(0) ~f:(fun e -> e.shares)) lhit_way)
             ; l_free <-- lany
             ; l_free_bank <-- luse1
             ; l_free_way <-- lfway
             ; if_
                 (kind_is Add c_kind.value |: phase_b.value)
                 [ sm.set_next Add_write ]
                 [ if_ (h0 <>:. 0 |: (h1 <>:. 0)) [ sm.set_next Rd_level ] [ sm.set_next Finish ] ]
             ]) )
        ; ( Add_write
          , (let ptr_of ~bank ~way = concat_msb [ bank; mux2 bank (lbucket 1) (lbucket 0); way ] in
             let level_ptr = mux2 l_hit.value (ptr_of ~bank:l_bank.value ~way:l_way.value) (ptr_of ~bank:l_free_bank.value ~way:l_free_way.value) in
             let new_order =
               Oe.pack { valid = vdd; oref = key_ref.value; ptr = level_ptr; shares = a_shares.value }
             in
             let new_level_shares = l_shares.value +: uresize a_shares.value ~width:level_shares_bits in
             let lrow_write bank way entry =
               proc
                 [ when_ ~:bank (write lmem.(0) (lbucket 0) (set_way (lrow 0) ~ways ~entry_width:Le.width ~way entry))
                 ; when_ bank (write lmem.(1) (lbucket 1) (set_way (lrow 1) ~ways ~entry_width:Le.width ~way entry))
                 ]
             in
             let orow_write bank way entry =
               proc
                 [ when_ ~:bank [ proc (write omem.(0) (obucket 0 key_ref.value) (set_way (orow 0) ~ways ~entry_width:oe_w ~way entry)) ]
                 ; when_ bank [ proc (write omem.(1) (obucket 1 key_ref.value) (set_way (orow 1) ~ways ~entry_width:oe_w ~way entry)) ]
                 ]
             in
             [ op_price <-- a_price.value
             ; if_
                 (~:(l_hit.value) &: ~:(l_free.value))
                 [ incr st_lovf; sm.set_next Cache_rd ]
                 [ if_
                     l_hit.value
                     [ lrow_write l_bank.value l_way.value
                         (Le.pack { valid = vdd; bs = bs.value; price = a_price.value; shares = new_level_shares })
                     ; op <--. 2
                     ; op_shares <-- new_level_shares
                     ]
                     [ lrow_write l_free_bank.value l_free_way.value
                         (Le.pack { valid = vdd; bs = bs.value; price = a_price.value; shares = uresize a_shares.value ~width:level_shares_bits })
                     ; op <--. 1
                     ; op_shares <-- uresize a_shares.value ~width:level_shares_bits
                     ; incr st_levels
                     ]
                 ; if_
                     o_free.value
                     [ orow_write o_free_bank.value o_free_way.value new_order; incr st_orders; sm.set_next Cache_rd ]
                     [ (* both buckets full: evict a victim from bank 0 *)
                       write omem.(0) (obucket 0 key_ref.value)
                         (set_way (orow 0) ~ways ~entry_width:oe_w ~way:victim.value new_order)
                       |> proc
                     ; homeless <-- mux victim.value (split_row (orow 0) ~ways ~entry_width:oe_w)
                     ; incr victim
                     ; incr st_kicks
                     ; kick_bank <-- vdd
                     ; kick_n <--. 2
                     ; sm.set_next Kick_rd
                     ]
                 ]
             ]) )
        ; ( Kick_rd
          , (let h = Oe.unpack p homeless.value in
             [ if_
                 (kick_n.value >:. p.max_kicks)
                 [ incr st_oovf; sm.set_next Cache_rd ]
                 [ when_ ~:(kick_bank.value) [ proc (read omem.(0) (obucket 0 h.oref)) ]
                 ; when_ kick_bank.value [ proc (read omem.(1) (obucket 1 h.oref)) ]
                 ; sm.set_next Kick_wait
                 ]
             ]) )
        ; Kick_wait, [ sm.set_next Kick_data ]
        ; ( Kick_data
          , (let h = Oe.unpack p homeless.value in
             let row = mux2 kick_bank.value (orow 1) (orow 0) in
             let entries = split_row row ~ways ~entry_width:oe_w |> List.map ~f:(Oe.unpack p) in
             let free = free_vec entries in
             let wr way entry =
               proc
                 [ when_ ~:(kick_bank.value) [ proc (write omem.(0) (obucket 0 h.oref) (set_way row ~ways ~entry_width:oe_w ~way entry)) ]
                 ; when_ kick_bank.value [ proc (write omem.(1) (obucket 1 h.oref) (set_way row ~ways ~entry_width:oe_w ~way entry)) ]
                 ]
             in
             [ if_
                 (free <>:. 0)
                 [ wr (lowest_set free) homeless.value
                 ; incr st_orders
                 ; when_ (kick_n.value >: st_max_kicks.value) [ st_max_kicks <-- kick_n.value ]
                 ; sm.set_next Cache_rd
                 ]
                 [ wr victim.value homeless.value
                 ; homeless <-- mux victim.value (split_row row ~ways ~entry_width:oe_w)
                 ; incr victim
                 ; incr st_kicks
                 ; kick_bank <-- ~:(kick_bank.value)
                 ; kick_n <-- kick_n.value +:. 1
                 ; sm.set_next Kick_rd
                 ]
             ]) )
        ; ( Rd_level
          , (let bank = msb o_ptr.value in
             let bucket = select o_ptr.value ~high:(ptr_bits p - 2) ~low:wb in
             [ when_ ~:bank [ proc (read lmem.(0) bucket) ]
             ; when_ bank [ proc (read lmem.(1) bucket) ]
             ; sm.set_next Level_wait
             ]) )
        ; Level_wait, [ sm.set_next Level_data ]
        ; ( Level_data
          , (let bank = msb o_ptr.value and way = sel_bottom o_ptr.value ~width:wb in
             let entry = mux way (split_row (mux2 bank (lrow 1) (lrow 0)) ~ways ~entry_width:Le.width) in
             let everything = kind_is Delete c_kind.value |: kind_is Replace c_kind.value in
             let req = c_shares.value in
             let n =
               mux2
                 (everything |: (req >=: uresize o_shares.value ~width:32))
                 o_shares.value
                 (sel_bottom req ~width:shares_bits)
             in
             [ lv_entry <-- entry; lv_n <-- n; sm.set_next Level_write ]) )
        ; ( Level_write
          , (let bank = msb o_ptr.value and way = sel_bottom o_ptr.value ~width:wb in
             let bucket = select o_ptr.value ~high:(ptr_bits p - 2) ~low:wb in
             let l = Le.unpack lv_entry.value in
             let n = lv_n.value in
             let o_left = o_shares.value -: n in
             let l_left = l.shares -: uresize n ~width:level_shares_bits in
             let new_o =
               mux2 (o_left ==:. 0) (zero oe_w)
                 (Oe.pack { valid = vdd; oref = key_ref.value; ptr = o_ptr.value; shares = o_left })
             in
             let new_l = mux2 (l_left ==:. 0) (zero Le.width) (Le.pack { l with shares = l_left }) in
             [ when_ ~:(o_bank.value) [ proc (write omem.(0) (obucket 0 key_ref.value) (set_way (orow 0) ~ways ~entry_width:oe_w ~way:o_way.value new_o)) ]
             ; when_ o_bank.value [ proc (write omem.(1) (obucket 1 key_ref.value) (set_way (orow 1) ~ways ~entry_width:oe_w ~way:o_way.value new_o)) ]
             ; when_ ~:bank [ proc (write lmem.(0) bucket (set_way (lrow 0) ~ways ~entry_width:Le.width ~way new_l)) ]
             ; when_ bank [ proc (write lmem.(1) bucket (set_way (lrow 1) ~ways ~entry_width:Le.width ~way new_l)) ]
             ; when_ (o_left ==:. 0) [ st_orders <-- st_orders.value -:. 1 ]
             ; when_ (l_left ==:. 0) [ st_levels <-- st_levels.value -:. 1 ]
             ; bs <-- l.bs
             ; op <-- mux2 (l_left ==:. 0) (of_unsigned_int ~width:2 3) (of_unsigned_int ~width:2 2)
             ; op_price <-- l.price
             ; op_shares <-- l_left
             ; sm.set_next Cache_rd
             ]) )
        ; ( Cache_rd
          , [ row <-- cache_row; row_nl <-- nlevels_of_bs; sm.set_next Cache_cmp ] )
        ; ( Cache_cmp
          , (let e = row_entries row.value in
             let g = goodness ~sell:sell_of_bs op_price.value in
             let valid j = let v, _, _ = e.(j) in v in
             let better = List.init k ~f:(fun j -> let v, pr, _ = e.(j) in v &: (goodness ~sell:sell_of_bs pr >: g)) in
             let matches = List.init k ~f:(fun j -> let v, pr, _ = e.(j) in v &: (pr ==: op_price.value)) in
             let groups =
               List.init group_count ~f:(fun b ->
                 List.slice matches (b * prefix_group) (Int.min k ((b + 1) * prefix_group))
                 |> List.reduce_exn ~f:( |: ))
             in
             let count = popcount (concat_lsb (List.init k ~f:valid)) in
             let complete = uresize count ~width:20 ==: row_nl.value in
             let insert_ok =
               List.map2_exn (List.init k ~f:valid) better ~f:(fun v b -> v &: ~:b) |> List.reduce_exn ~f:( |: )
               |: (complete &: ~:(valid (k - 1)))
             in
             [ better_r <-- concat_lsb better
             ; match_r <-- concat_lsb matches
             ; group_r <-- concat_lsb groups
             ; insert_ok_r <-- insert_ok
             ; sm.set_next Cache_prefix
             ]) )
        ; ( Cache_prefix
          , (let upto =
               List.init k ~f:(fun j ->
                 let b = j / prefix_group in
                 let local =
                   List.init (j - (b * prefix_group) + 1) ~f:(fun n ->
                     bit match_r.value ~pos:((b * prefix_group) + n))
                 in
                 let preceding = List.init b ~f:(fun n -> bit group_r.value ~pos:n) in
                 List.reduce_exn (preceding @ local) ~f:( |: ))
             in
             let g = goodness ~sell:sell_of_bs op_price.value in
             [ upto_r <-- concat_lsb upto
             ; so_match
               <-- concat_lsb
                     (List.init k ~f:(fun j ->
                        sorter_v.(j).value &: (sorter_p.(j).value ==: op_price.value)))
             ; so_better
               <-- concat_lsb
                     (List.init k ~f:(fun j -> sorter_v.(j).value &: (sorter_k.(j).value >: g)))
             ; sm.set_next Cache_wr
             ]) )
        ; ( Cache_wr
          , (let e = row_entries row.value in
             let better j = bit better_r.value ~pos:j and matches j = bit match_r.value ~pos:j in
             let invalid = gnd, zero price_bits, zero level_shares_bits in
             let entry j = if j < 0 || j >= k then invalid else e.(j) in
             let mux3 c (a1, b1, c1) (a2, b2, c2) = mux2 c a1 a2, mux2 c b1 b2, mux2 c c1 c2 in
             let insert_ok = insert_ok_r.value in
             let fresh = vdd, op_price.value, op_shares.value in
             let created j =
               let take_new = ~:(better j) &: (if j = 0 then vdd else better (j - 1)) in
               mux3 (better j) (entry j) (mux3 take_new fresh (entry (j - 1)))
             in
             let changed j =
               let v, pr, sh = entry j in
               v, pr, mux2 (matches j) op_shares.value sh
             in
             let upto = Array.init k ~f:(fun j -> bit upto_r.value ~pos:j) in
             let deleted j = mux3 upto.(j) (entry (j + 1)) (entry j) in
             let o = op.value in
             let new_entry j =
               let choose (x : Signal.t * Signal.t * Signal.t) y z w =
                 let f g = mux o [ g x; g y; g z; g w ] in
                 f (fun (a, _, _) -> a), f (fun (_, b, _) -> b), f (fun (_, _, c) -> c)
               in
               mux3 ((o ==:. 1) &: ~:insert_ok) (entry j) (choose (entry j) (created j) (changed j) (deleted j))
             in
             let sorter_op =
               let m j = bit so_match.value ~pos:j and b j = bit so_better.value ~pos:j in
               let any_match = so_match.value <>:. 0 in
               let g = goodness ~sell:sell_of_bs op_price.value in
               let upto = Array.folding_map (Array.init k ~f:m) ~init:gnd ~f:(fun acc x -> let a = acc |: x in a, a) in
               let set j (v, key, pr, sh) =
                 [ sorter_v.(j) <-- v; sorter_k.(j) <-- key; sorter_p.(j) <-- pr; sorter_s.(j) <-- sh ]
               in
               let get j =
                 sorter_v.(j).value, sorter_k.(j).value, sorter_p.(j).value, sorter_s.(j).value
               in
               let insert =
                 (* same shape as a scan winner's insertion; a full sorter
                    evicts its worst entry (or the new one) into [ev] *)
                 let evict_v = sorter_v.(k - 1).value in
                 let evict_k = mux2 (b (k - 1)) g sorter_k.(k - 1).value in
                 [ pe_v <-- evict_v; pe_k <-- evict_k ]
                 @ List.concat
                     (List.init k ~f:(fun j ->
                        let take = (if j = 0 then vdd else b (j - 1)) &: ~:(b j) in
                        when_ take (set j (vdd, g, op_price.value, op_shares.value))
                        :: (if j = 0 then [] else [ when_ ~:(b (j - 1)) (set j (get (j - 1))) ])))
               in
               let update = List.init k ~f:(fun j -> when_ (m j) [ sorter_s.(j) <-- op_shares.value ]) in
               let remove =
                 List.init k ~f:(fun j ->
                   when_
                     upto.(j)
                     (set j (if j = k - 1 then gnd, zero 32, zero price_bits, zero level_shares_bits else get (j + 1))))
               in
               when_
                 (scan_active.value &: (rbs.value ==: bs.value))
                 [ switch
                     o
                     [ of_unsigned_int ~width:2 1, [ if_ any_match update insert ]
                     ; of_unsigned_int ~width:2 2, update
                     ; of_unsigned_int ~width:2 3, remove
                     ; of_unsigned_int ~width:2 0, []
                     ]
                 ]
             in
             sorter_op
             :: write_row (Array.init k ~f:new_entry)
             @ List.init book_sides ~f:(fun b ->
               when_
                 (bs.value ==:. b)
                 [ when_ (o ==:. 1) [ incr nlevels.(b) ]
                 ; when_ (o ==:. 3) [ nlevels.(b) <-- nlevels.(b).value -:. 1 ]
                 ])
             @ [ op <--. 0
               ; if_
                   (kind_is Replace c_kind.value &: ~:(phase_b.value))
                   [ (* second half of a replace: add the new reference on the same side *)
                     phase_b <-- vdd
                     ; key_ref <-- c_new_ref.value
                     ; a_price <-- c_price.value
                     ; a_shares <-- sel_bottom c_shares.value ~width:shares_bits
                     ; if_
                         (~:(c_new_ok.value) |: (select c_shares.value ~high:31 ~low:shares_bits <>:. 0))
                         [ incr st_unsupported; sm.set_next Finish ]
                         [ sm.set_next Rd_order ]
                   ]
                   [ sm.set_next Finish ]
               ]) )
        ; ( Finish
          , (let cached = popcount (concat_lsb (Array.to_list (Array.map (row_entries cache_row) ~f:(fun (v, _, _) -> v)))) in
             let cached = uresize cached ~width:20 in
             [ if_
                 ((cached ==:. 0) &: (nlevels_of_bs <>:. 0))
                 [ (* the best level is unknown until this side is refilled *)
                   w_bs <-- bs.value; waiting <-- vdd; sm.set_next Wait_refill ]
                 [ when_
                     ((cached <=:. low_water) &: (nlevels_of_bs >: cached) &: ~:(scan_active.value))
                     (start_scan bs.value)
                 ; sm.set_next Emit
                 ]
             ]) )
        ; ( Wait_refill
          , [ incr st_stall
            ; if_
                scan_done.value
                [ sm.set_next Merge_rd ]
                [ when_ ~:(scan_active.value) (start_scan w_bs.value) ]
            ] )
        ; ( Merge_rd
          , (let v, key = vmax (disc_v.value, disc_k.value) (ev_v.value, ev_k.value) in
             [ bs <-- rbs.value; disc_v <-- v; disc_k <-- key; sm.set_next Merge_cmp ]) )
        ; ( Merge_cmp
          , (let kept =
               List.init k ~f:(fun j ->
                 sorter_v.(j).value &: (~:(disc_v.value) |: (sorter_k.(j).value >: disc_k.value)))
               |> concat_lsb
             in
             let n_cached =
               popcount (concat_lsb (Array.to_list (Array.map (row_entries cache_row) ~f:(fun (v, _, _) -> v))))
             in
             (* the cache and the scan result are both prefixes of the book
                side's sorted levels: keep the longer *)
             [ kept_r <-- kept; take_r <-- (popcount kept >: n_cached); sm.set_next Merge_wr ]) )
        ; ( Merge_wr
          , (let kept j = bit kept_r.value ~pos:j in
             [ when_
                 take_r.value
                 (write_row (Array.init k ~f:(fun j -> kept j, sorter_p.(j).value, sorter_s.(j).value)))
             ; st_refill_levels <-- st_refill_levels.value +: uresize (popcount kept_r.value) ~width:32
             ; scan_active <-- gnd
             ; scan_done <-- gnd
             ; if_
                 waiting.value
                 [ bs <-- w_bs.value
                 ; (* the waiting side's cache is empty, so [take_r] says
                      whether this scan found anything for it. A scan that
                      was already running when the side emptied may have
                      discarded the levels that are now best: scan again. *)
                   if_
                     ((rbs.value ==: w_bs.value) &: take_r.value)
                     [ waiting <-- gnd; sm.set_next Emit ]
                     [ sm.set_next Wait_refill ]
                 ]
                 [ sm.set_next Idle ]
             ]) )
        ; ( Emit
          , (let now = tob_of_slot c_slot.value in
             [ ev.valid <-- vdd
             ; ev.changed <-- (now <>: tob_before.value)
             ; ev.seq <-- c_seq.value
             ; ev.slot <-- c_slot.value
             ; ev.bid_price <-- select now ~high:127 ~low:96
             ; ev.bid_shares <-- select now ~high:95 ~low:64
             ; ev.ask_price <-- select now ~high:63 ~low:32
             ; ev.ask_shares <-- select now ~high:31 ~low:0
             ; incr st_processed
             ; sm.set_next Idle
             ]) )
        ]
    ; when_ ~:(sm.is Emit) [ ev.valid <-- gnd ]
    ];
  let fifo_overflows = reg_fb spec ~width:32 ~f:(fun c -> mux2 (cmd.valid &: fifo.full) (c +:. 1) c) in
  let fifo_max_used =
    reg_fb spec ~width:16 ~f:(fun m ->
      let u = uresize fifo.used ~width:16 in
      mux2 (u >: m) u m)
  in
  { O.event = Event.Of_always.value ev
  ; stats =
      { Stats.processed = st_processed.value
      ; unsupported = st_unsupported.value
      ; order_overflows = st_oovf.value
      ; level_overflows = st_lovf.value
      ; kicks = st_kicks.value
      ; max_kicks = st_max_kicks.value
      ; refills = st_refills.value
      ; refill_levels = st_refill_levels.value
      ; refill_stall_cycles = st_stall.value
      ; orders = st_orders.value
      ; levels = st_levels.value
      ; fifo_overflows
      ; fifo_max_used
      ; debug_state = uresize sm.current ~width:8
      ; debug_fifo_empty = fifo.empty
      }
  }
;;

let hierarchical ?p ?fifo_capacity scope =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical ~scope ~name:"order_book" (create ?p ?fifo_capacity)
;;
