(* Latency_monitor against the simulation's latency definition
   (bin/verify.ml: from the cycle a message's last byte is on the MAC stream
   to the cycle its book event is valid). Random message streams in
   MoldUDP64 packets of one to four messages, back to back at 1 Gb/s line
   rate, through the whole Feed_handler. Every hardware sample must equal
   the simulation's latency for that event, and the percentiles the
   monitor's scanner publishes must equal verify's over the same samples. *)

open! Core
open! Hardcaml
open Feed_hw
open Itch_model
open Net

module Top = struct
  module I = struct
    type 'a t =
      { clock : 'a
      ; clear : 'a
      ; rx : 'a Stream.Mac_rx.t [@rtlmangle "_"]
      }
    [@@deriving hardcaml]
  end

  module O = struct
    type 'a t =
      { event : 'a Order_book.Event.t [@rtlmangle "_"]
      ; lat : 'a Latency_monitor.O.t [@rtlmangle "_"]
      }
    [@@deriving hardcaml]
  end

  let create ~offset scope (i : _ I.t) : _ O.t =
    let fh =
      Feed_handler.create scope { clock = i.clock; clear = i.clear; cfg = Timing_top.config (); rx = i.rx }
    in
    let lat =
      Latency_monitor.create
        ~offset
        scope
        { clock = i.clock; clear = i.clear; cmd = fh.cmd; event = fh.event.valid }
    in
    { O.event = fh.event; lat }
  ;;
end

module Sim = Cyclesim.With_interface (Top.I) (Top.O)

(* verify's percentile: index floor(p * n / 100) of the sorted samples *)
let percentile sorted ~num ~den =
  let n = Array.length sorted in
  if n = 0 then 0 else sorted.(Int.min (n - 1) (num * n / den))
;;

let run ~offset =
  let sim = Sim.create (Top.create ~offset (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim
  and o = Cyclesim.outputs sim in
  let cycle = ref 0 in
  let last_byte = Hashtbl.create (module Int) in
  let offsets = Hash_set.create (module Int) in
  let latencies = Queue.create () in
  let step () =
    Cyclesim.cycle sim;
    incr cycle;
    if Bits.to_bool !(o.lat.sample_valid)
    then (
      let seq = Bits.to_int_trunc !(o.event.seq) in
      let sim_latency = !cycle - Hashtbl.find_exn last_byte seq in
      Queue.enqueue latencies sim_latency;
      Hash_set.add offsets (sim_latency - Bits.to_int_trunc !(o.lat.sample)))
  in
  let idle n =
    i.rx.valid := Bits.gnd;
    for _ = 1 to n do
      step ()
    done
  in
  i.clear := Bits.vdd;
  step ();
  i.clear := Bits.gnd;
  idle 5000 (* the order book and the histogram clear their memories *);
  let next_seq = ref 1 in
  for trial = 0 to 7 do
    let messages =
      Quickcheck.random_value ~seed:(`Deterministic (sprintf "latency %d" trial)) Gen.random_messages
      |> List.map ~f:Itch.to_string
    in
    let rec packets ms k =
      match ms with
      | [] -> ()
      | _ ->
        let now = List.take ms (1 + (k % 4)) and rest = List.drop ms (1 + (k % 4)) in
        let sequence = !next_seq in
        next_seq := !next_seq + List.length now;
        let frame =
          Packet.frame
            Packet.default_endpoints
            (Packet.Mold.to_string
               { session = "LATENCY001"; sequence; messages = now; end_of_session = false })
        in
        (* the byte index where each message ends *)
        let ends = Hashtbl.create (module Int) in
        let pos = ref Packet.first_block_offset in
        List.iteri now ~f:(fun j m ->
          pos := !pos + 2 + String.length m;
          Hashtbl.set ends ~key:(!pos - 1) ~data:(sequence + j));
        let n = String.length frame in
        String.iteri frame ~f:(fun k c ->
          i.rx.valid := Bits.vdd;
          i.rx.data := Bits.of_int_trunc ~width:8 (Char.to_int c);
          i.rx.first := Bits.of_bool (k = 0);
          i.rx.last := Bits.of_bool (k = n - 1);
          Option.iter (Hashtbl.find ends k) ~f:(fun seq ->
            Hashtbl.set last_byte ~key:seq ~data:(!cycle + 1));
          step ());
        i.rx.first := Bits.gnd;
        i.rx.last := Bits.gnd;
        idle 20;
        packets rest (k + 1)
    in
    packets messages trial
  done;
  idle 5000 (* the book finishes, and the scanner completes two passes *);
  let sorted = Queue.to_array latencies in
  Array.sort sorted ~compare:Int.compare;
  let s = o.lat.stats in
  let g r = Bits.to_int_trunc !r in
  printf
    "samples %d; sim - hardware: %s\n"
    (Array.length sorted)
    (Hash_set.to_list offsets |> List.sort ~compare:Int.compare |> List.map ~f:Int.to_string |> String.concat ~sep:",");
  printf
    "hardware: count %d p50 %d p99 %d p99.9 %d max %d\n"
    (g s.count)
    (g s.p50)
    (g s.p99)
    (g s.p999)
    (g s.max);
  printf
    "verify:   count %d p50 %d p99 %d p99.9 %d max %d\n"
    (Array.length sorted)
    (percentile sorted ~num:50 ~den:100)
    (percentile sorted ~num:99 ~den:100)
    (percentile sorted ~num:999 ~den:1000)
    (if Array.length sorted = 0 then 0 else sorted.(Array.length sorted - 1))
;;

let%expect_test "every sample equals verify's latency; the scanner's percentiles equal verify's" =
  run ~offset:Feed_handler.command_offset;
  [%expect {|
    samples 934; sim - hardware: 0
    hardware: count 934 p50 20 p99 28 p99.9 28 max 28
    verify:   count 934 p50 20 p99 28 p99.9 28 max 28
    |}]
;;


(* The monitor on its own, with a synthetic schedule the feed does not
   produce: latencies from 3 to 3,000 cycles (bins saturate at 1,023; the
   maximum stays exact), many commands outstanding, and events as close as
   the 3 cycles the histogram's read-modify-write allows. *)
module Mon = Cyclesim.With_interface (Latency_monitor.I) (Latency_monitor.O)

let%expect_test "histogram and percentiles across the whole range, with saturation" =
  let rand = Random.State.make [| 7 |] in
  let n = 2_000 in
  let cmds = Array.create ~len:n 0
  and events = Array.create ~len:n 0 in
  let t = ref 2_000 (* after the histogram has cleared its bins *)
  and last_event = ref 0 in
  for k = 0 to n - 1 do
    (* a new command arrives shortly before or after the previous event, so
       only a few are outstanding and most latencies are the drawn ones *)
    t := Int.max (!t + 1) (!last_event + Random.State.int_incl rand (-40) 200);
    let latency =
      match Random.State.int rand 200 with
      | 0 -> Random.State.int_incl rand 1_000 3_000
      | k when k < 50 -> Random.State.int_incl rand 60 1_000
      | _ -> Random.State.int_incl rand 3 60
    in
    cmds.(k) <- !t;
    events.(k) <- Int.max (!t + latency) (!last_event + 3);
    last_event := events.(k)
  done;
  let is_cmd = Hash_set.of_array (module Int) cmds
  and is_event = Hash_set.of_array (module Int) events in
  let sim = Mon.create (Latency_monitor.create ~offset:0 (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim
  (* [sample_valid] follows the [event] input combinationally: read it
     before the clock edge (the feed's events are registered, so the first
     test does not need this) *)
  and o = Cyclesim.outputs ~clock_edge:Before sim in
  i.clear := Bits.vdd;
  Cyclesim.cycle sim;
  i.clear := Bits.gnd;
  let samples = Queue.create () in
  for c = 0 to !last_event + 3_000 do
    i.cmd := Bits.of_bool (Hash_set.mem is_cmd c);
    i.event := Bits.of_bool (Hash_set.mem is_event c);
    Cyclesim.cycle sim;
    if Bits.to_bool !(o.sample_valid) then Queue.enqueue samples (Bits.to_int_trunc !(o.sample))
  done;
  let want = Array.map2_exn events cmds ~f:( - ) in
  let got = Queue.to_array samples in
  printf "samples equal the schedule: %b\n" ([%equal: int array] got want);
  Array.sort want ~compare:Int.compare;
  let sat x = Int.min x 1023 in
  let g r = Bits.to_int_trunc !r in
  let s = o.stats in
  printf
    "hardware: count %d p50 %d p99 %d p99.9 %d max %d\n"
    (g s.count)
    (g s.p50)
    (g s.p99)
    (g s.p999)
    (g s.max);
  printf
    "expected: count %d p50 %d p99 %d p99.9 %d max %d\n"
    n
    (sat (percentile want ~num:50 ~den:100))
    (sat (percentile want ~num:99 ~den:100))
    (sat (percentile want ~num:999 ~den:1000))
    want.(n - 1);
  [%expect {|
    samples equal the schedule: true
    hardware: count 2000 p50 41 p99 959 p99.9 1023 max 2979
    expected: count 2000 p50 41 p99 959 p99.9 1023 max 2979
    |}]
;;
