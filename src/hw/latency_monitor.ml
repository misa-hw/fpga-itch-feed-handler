(* On-chip latency measurement of every book command.

   Book commands and book events are one to one and in order (every
   command, changed or not, produces exactly one event), so a timestamp
   FIFO beside the book's command FIFO pairs them: a command pushes the
   cycle counter, its event pops it. [offset] is the fixed number of
   cycles from a message's last byte on the MAC stream to its command, so
   a sample is the latency bin/verify.ml measures in simulation (last byte
   on rx to event valid); tests/hw/test_latency.ml checks that per event.

   Samples go into a histogram of one-cycle bins in block RAM (1023 and
   above share the last bin; the exact maximum is kept in a register). A
   scanner walks a second copy of the histogram continuously and finds the
   percentiles with verify's definition: the value at index floor(p*n/100)
   of the sorted samples, which is the smallest bin whose cumulative count
   c has 100c > pn. Every pass publishes a consistent (count, p50, p99,
   p99.9) set; once traffic stops, the next pass is exact.

   Two events are never closer than 3 cycles (a command takes more), which
   the histogram's read-modify-write relies on. *)

open! Core
open! Hardcaml
open Signal

let bin_bits = 10
let bins = 1 lsl bin_bits

module Stats = struct
  type 'a t =
    { count : 'a [@bits 32]
    ; p50 : 'a [@bits 16]
    ; p99 : 'a [@bits 16]
    ; p999 : 'a [@bits 16]
    ; max : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; cmd : 'a (* a book command enters the book's FIFO *)
    ; event : 'a (* the book emits an event *)
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { stats : 'a Stats.t [@rtlmangle "_"]
    ; sample_valid : 'a
    ; sample : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

(* x * k for a small constant k: one shifted copy of x per set bit of k,
   summed by a tree of adders with a register after every level, padded to
   [product_latency] cycles (too wide and deep to add in one 8 ns cycle) *)
let product_latency = 3

let times spec x k ~width =
  let x = uresize x ~width in
  let terms =
    List.init 12 ~f:Fn.id
    |> List.filter ~f:(fun b -> k land (1 lsl b) <> 0)
    |> List.map ~f:(fun b -> sll x ~by:b)
  in
  let rec tree terms level =
    match terms with
    | [ t ] -> t, level
    | _ ->
      let rec pairs = function
        | a :: b :: rest -> (a +: b) :: pairs rest
        | rest -> rest
      in
      tree (List.map (pairs terms) ~f:(reg spec)) (level + 1)
  in
  let sum, levels = tree terms 0 in
  assert (levels <= product_latency);
  pipeline spec ~n:(product_latency - levels) sum
;;

let create ~offset ?(capacity = 512 + 16) scope (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let now = reg_fb spec ~width:32 ~f:(fun t -> t +:. 1) in
  (* after reset, zero the histograms (a reset does not clear BRAM) *)
  let init = reg_fb spec ~width:(bin_bits + 1) ~f:(fun c -> mux2 (msb c) c (c +:. 1)) in
  let ready = msb init in
  (* ---- pair commands with events ---- *)
  let rd = wire 1 in
  let fifo =
    Fifo.create
      ~showahead:true
      ~scope
      ()
      ~capacity
      ~clock:i.clock
      ~clear:i.clear
      ~wr:i.cmd
      ~d:now
      ~rd
  in
  let pop = i.event &: ~:(fifo.empty) in
  assign rd pop;
  let sample = now -: fifo.q +:. offset in
  (* ---- histogram: read-modify-write, and a mirror for the scanner ---- *)
  let v1 = reg spec (pop &: ready) in
  let s1 = reg spec sample in
  let b1 = mux2 (s1 >=:. bins - 1) (ones bin_bits) (sel_bottom s1 ~width:bin_bits) in
  let v2 = reg spec v1 in
  let b2 = reg spec b1 in
  let wr_en = v2 |: ~:ready in
  let wr_addr = mux2 ready b2 (sel_bottom init ~width:bin_bits) in
  let old = wire 32 in
  let wr_data = mux2 ready (old +:. 1) (zero 32) in
  let memory ~read_address ~read_enable =
    ram_rbw
      ~write_port:
        { write_clock = i.clock; write_address = wr_addr; write_enable = wr_en; write_data = wr_data }
      ~read_port:{ read_clock = i.clock; read_address; read_enable }
      bins
  in
  assign old (memory ~read_address:b1 ~read_enable:v1);
  let count = reg_fb spec ~width:32 ~f:(fun c -> mux2 v2 (c +:. 1) c) in
  let max = reg_fb spec ~width:32 ~f:(fun m -> mux2 (v1 &: (s1 >: m)) s1 m) in
  (* ---- scanner ----
     One pass: bins 0..1023 are read on sc = 0..1023. A bin's cumulative
     count is ready 2 cycles later, its products with 100 and 1000
     [product_latency] cycles after that, and the first bin passing each
     threshold is latched a cycle later; results are published at
     sc = bins + 10. The next pass's count is taken at sc = bins + 14 and its
     thresholds are ready [product_latency] cycles later, in the gap, so
     nothing in the pipeline straddles two passes. *)
  let sc_bits = bin_bits + 1 in
  let last_sc = bins + 23 in
  let sc =
    reg_fb spec ~width:sc_bits ~f:(fun c ->
      mux2 ready (mux2 (c ==:. last_sc) (zero sc_bits) (c +:. 1)) c)
  in
  let at k = sc ==:. k in
  let reading = ready &: (sc <:. bins) in
  let a0 = sel_bottom sc ~width:bin_bits in
  let d1 = memory ~read_address:a0 ~read_enable:reading in
  let vs1 = reg spec reading in
  let a1 = reg spec a0 in
  let cum = reg_fb spec ~width:32 ~f:(fun c -> mux2 vs1 (mux2 (a1 ==:. 0) d1 (c +: d1)) c) in
  let vs2 = reg spec vs1 in
  let a2 = reg spec a1 in
  let tw = 32 + 10 in
  let c100 = times spec cum 100 ~width:tw in
  let c1000 = times spec cum 1000 ~width:tw in
  let vs5 = pipeline spec ~n:product_latency vs2 in
  let a5 = pipeline spec ~n:product_latency a2 in
  let n_pass = reg spec ~enable:(at (bins + 14)) count in
  let thr50 = times spec n_pass 50 ~width:tw
  and thr99 = times spec n_pass 99 ~width:tw
  and thr999 = times spec n_pass 999 ~width:tw in
  (* the smallest bin of the pass whose cumulative count passes each threshold *)
  let first_hit hit =
    let found = reg_fb spec ~width:1 ~f:(fun f -> mux2 (at (bins + 12)) gnd (f |: (vs5 &: hit))) in
    let bin = reg spec ~enable:(vs5 &: hit &: ~:found) a5 in
    found, bin
  in
  let publish (found, bin) = reg spec ~enable:(at (bins + 10)) (mux2 found (uresize bin ~width:16) (zero 16)) in
  let p50 = publish (first_hit (c100 >: thr50)) in
  let p99 = publish (first_hit (c100 >: thr99)) in
  let p999 = publish (first_hit (c1000 >: thr999)) in
  let published_count = reg spec ~enable:(at (bins + 10)) n_pass in
  { O.stats = { Stats.count = published_count; p50; p99; p999; max }
  ; sample_valid = pop
  ; sample
  }
;;

let hierarchical ~offset ?capacity scope =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical ~scope ~name:"latency_monitor" (create ~offset ?capacity)
;;
