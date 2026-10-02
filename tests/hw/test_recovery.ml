(* Mold_parser with recovery: A/B lines that each lose packets, packets out
   of order, losses at the end of the feed (seen through the end-of-session
   packet), and a retransmission server (this testbench) that answers the
   parser's requests, sometimes not at all. Whatever arrives, the output
   must be every message exactly once, in sequence, byte for byte; with no
   server, the missing ones must be given up and counted, and the rest still
   come out in sequence. *)

open! Core
open! Hardcaml
open Feed_hw
open Itch_model
open Net

module Sim = Cyclesim.With_interface (Mold_parser.I) (Mold_parser.O)

let recovery =
  { Mold_parser.Recovery.window = 60
  ; retry = 600
  ; max_retries = 3
  ; max_request = 16
  ; buffer_bytes = 2048
  ; buffer_messages = 48
  }
;;

let session = "RECOVERY01"

let packet ~seq messages =
  Packet.Mold.to_string { session; sequence = seq; messages; end_of_session = false }
;;

let end_of_session ~next =
  Packet.Mold.to_string { session; sequence = next; messages = []; end_of_session = true }
;;

type scenario =
  { name : string
  ; drop_a : float
  ; drop_b : float
  ; skew : int (* B runs this many packets behind A *)
  ; swap : float (* chance two adjacent packets of a line swap *)
  ; answer : float (* chance the server answers a request *)
  ; seed : int
  }

let run sc =
  let rand = Random.State.make [| sc.seed |] in
  let messages =
    Quickcheck.random_value ~seed:(`Deterministic (sprintf "recovery %d" sc.seed)) Gen.random_messages
    |> List.map ~f:Itch.to_string
    |> Array.of_list
  in
  let n = Array.length messages in
  (* packets of 1 to 4 messages: (first seq, messages) *)
  let packets =
    let rec go k acc =
      if k >= n
      then List.rev acc
      else (
        let c = Int.min (n - k) (1 + Random.State.int rand 4) in
        go (k + c) ((k + 1, Array.sub messages ~pos:k ~len:c |> Array.to_list) :: acc))
    in
    go 0 []
  in
  let line drop =
    let kept = List.filter packets ~f:(fun _ -> Float.(Random.State.float rand 1.0 >= drop)) in
    (* swap some adjacent packets *)
    let a = Array.of_list kept in
    for k = 0 to Array.length a - 2 do
      if Float.(Random.State.float rand 1.0 < sc.swap)
      then (
        let t = a.(k) in
        a.(k) <- a.(k + 1);
        a.(k + 1) <- t)
    done;
    Array.to_list a
  in
  let line_a = line sc.drop_a
  and line_b = line sc.drop_b in
  (* the order on the wire: A, with B [skew] packets behind *)
  let wire =
    let a = Array.of_list line_a
    and b = Array.of_list line_b in
    List.init (Int.max (Array.length a) (Array.length b) + sc.skew) ~f:(fun k ->
      (if k < Array.length a then [ a.(k) ] else [])
      @ if k >= sc.skew && k - sc.skew < Array.length b then [ b.(k - sc.skew) ] else [])
    |> List.concat
    |> List.map ~f:(fun (seq, ms) -> packet ~seq ms)
  in
  let wire = wire @ [ end_of_session ~next:(n + 1) ] in
  let sim = Sim.create (Mold_parser.create ~recovery (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim
  and o = Cyclesim.outputs sim in
  i.clear := Bits.vdd;
  Cyclesim.cycle sim;
  i.clear := Bits.gnd;
  let out = Queue.create () and cur = Buffer.create 64 and cur_seq = ref 0 in
  let requests = ref 0 and answers = Queue.create () and cycle = ref 0 in
  let step () =
    Cyclesim.cycle sim;
    incr cycle;
    let m = o.msg in
    if Bits.to_bool !(m.valid)
    then (
      if Bits.to_bool !(m.first)
      then (
        Buffer.clear cur;
        cur_seq := Bits.to_int_trunc !(m.seq));
      Buffer.add_char cur (Char.of_int_exn (Bits.to_int_trunc !(m.data)));
      if Bits.to_bool !(m.last) then Queue.enqueue out (!cur_seq, Buffer.contents cur));
    let r = o.request in
    if Bits.to_bool !(r.valid)
    then (
      incr requests;
      let seq = Bits.to_int_trunc !(r.seq)
      and count = Bits.to_int_trunc !(r.count) in
      assert (String.equal (Bits.to_string !(r.session) |> fun _ -> session) session);
      if Float.(Random.State.float rand 1.0 < sc.answer)
      then (
        (* answered 200 cycles later, in packets of up to 4 messages *)
        let rec go k =
          if k < seq + count && k <= n
          then (
            let c = Int.min 4 (Int.min (seq + count - k) (n + 1 - k)) in
            Queue.enqueue
              answers
              (!cycle + 200, packet ~seq:k (Array.sub messages ~pos:(k - 1) ~len:c |> Array.to_list));
            go (k + c))
        in
        go seq))
  in
  let send pkt =
    String.iteri pkt ~f:(fun k c ->
      i.payload.valid := Bits.vdd;
      i.payload.data := Bits.of_int_trunc ~width:8 (Char.to_int c);
      i.payload.first := Bits.of_bool (k = 0);
      i.payload.last := Bits.of_bool (k = String.length pkt - 1);
      step ());
    i.payload.valid := Bits.gnd;
    i.payload.first := Bits.gnd;
    i.payload.last := Bits.gnd;
    for _ = 1 to 6 do
      step ()
    done
  in
  let send_due_answers () =
    while (not (Queue.is_empty answers)) && fst (Queue.peek_exn answers) <= !cycle do
      send (snd (Queue.dequeue_exn answers))
    done
  in
  List.iter wire ~f:(fun pkt ->
    send_due_answers ();
    send pkt);
  (* let the server and the retries run out *)
  for _ = 1 to 20_000 do
    send_due_answers ();
    step ()
  done;
  let got = Queue.to_list out in
  let want = List.init n ~f:(fun k -> k + 1, messages.(k)) in
  let c = o.counters in
  let g r = Bits.to_int_trunc !r in
  let seqs = List.map got ~f:fst in
  let increasing = List.is_sorted_strictly seqs ~compare:Int.compare in
  let intact = List.for_all got ~f:(fun (seq, body) -> String.equal body messages.(seq - 1)) in
  printf
    "%s: %d messages, %d out (in sequence, no repeats: %b; bodies intact: %b; all of them: %b; out + lost = all: %b)\n"
    sc.name
    n
    (List.length got)
    increasing
    intact
    ([%equal: (int * string) list] got want)
    (List.length got + g c.lost = n);
  printf
    "  dropped on A %d, on B %d; duplicates %d, gaps %d, requests %d, replayed %d, lost %d, stale %b, buffer peak %d\n"
    (List.length packets - List.length line_a)
    (List.length packets - List.length line_b)
    (g c.duplicates)
    (g c.gaps)
    (g c.requests)
    (g c.replayed)
    (g c.lost)
    (Bits.to_bool !(c.stale))
    (g c.buffer_peak);
  (let have = Int.Set.of_list seqs in
   let missing = List.filter (List.init n ~f:(fun k -> k + 1)) ~f:(fun k -> not (Set.mem have k)) in
   if (not (List.is_empty missing)) && g c.lost = 0
   then printf "  missing, not counted as lost: %s\n" (List.map missing ~f:Int.to_string |> String.concat ~sep:","));
  (match List.find got ~f:(fun (seq, body) -> not (String.equal body messages.(seq - 1))) with
   | Some (seq, body) ->
     let hex x = String.concat_map x ~f:(fun c -> sprintf "%02x" (Char.to_int c)) in
     printf "  first bad: seq %d\n    got  %s\n    want %s\n" seq (hex body) (hex messages.(seq - 1))
   | None -> ());
  ignore requests
;;

let%expect_test "recovery" =
  List.iter
    [ { name = "A only, no loss"; drop_a = 0.0; drop_b = 1.0; skew = 0; swap = 0.0; answer = 1.0; seed = 1 }
    ; { name = "A and B, independent losses"; drop_a = 0.15; drop_b = 0.15; skew = 2; swap = 0.0; answer = 1.0; seed = 2 }
    ; { name = "A and B, some out of order"; drop_a = 0.1; drop_b = 0.1; skew = 1; swap = 0.1; answer = 1.0; seed = 3 }
    ; { name = "A only, server answers half"; drop_a = 0.2; drop_b = 1.0; skew = 0; swap = 0.0; answer = 0.5; seed = 4 }
    ; { name = "A only, no server"; drop_a = 0.1; drop_b = 1.0; skew = 0; swap = 0.0; answer = 0.0; seed = 5 }
    ]
    ~f:run;
  [%expect {|
    A only, no loss: 172 messages, 172 out (in sequence, no repeats: true; bodies intact: true; all of them: true; out + lost = all: true)
      dropped on A 0, on B 67; duplicates 0, gaps 0, requests 0, replayed 0, lost 0, stale false, buffer peak 0
    A and B, independent losses: 162 messages, 162 out (in sequence, no repeats: true; bodies intact: true; all of them: true; out + lost = all: true)
      dropped on A 6, on B 13; duplicates 135, gaps 7, requests 7, replayed 44, lost 0, stale false, buffer peak 9
    A and B, some out of order: 170 messages, 170 out (in sequence, no repeats: true; bodies intact: true; all of them: true; out + lost = all: true)
      dropped on A 10, on B 2; duplicates 188, gaps 16, requests 16, replayed 72, lost 0, stale false, buffer peak 9
    A only, server answers half: 189 messages, 186 out (in sequence, no repeats: true; bodies intact: true; all of them: false; out + lost = all: true)
      dropped on A 12, on B 69; duplicates 0, gaps 11, requests 15, replayed 136, lost 3, stale true, buffer peak 49
    A only, no server: 179 messages, 149 out (in sequence, no repeats: true; bodies intact: true; all of them: false; out + lost = all: true)
      dropped on A 8, on B 74; duplicates 0, gaps 14, requests 28, replayed 145, lost 30, stale true, buffer peak 49
    |}]
;;
