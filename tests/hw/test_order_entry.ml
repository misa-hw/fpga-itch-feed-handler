(* Order_entry behind the whole Feed_handler, on random feeds at 1 Gb/s line
   rate: the transmitted frames must be the model's (reference book, then
   Itch_model.Ouch.Strategy, then Net.Packet.frame) byte for byte with a
   correct FCS, and every tick-to-trade sample must be the number of cycles
   from the triggering message's last byte on the receive MAC stream to
   TX_EN rising. *)

open! Core
open! Hardcaml
open Feed_hw
open Itch_model
open Net

let rule = { Ouch.Rule.slot = 0; symbol = "QQQ"; limit = 10_400; quantity = 100 }

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
      { txen : 'a
      ; txd : 'a [@bits 8]
      ; stats : 'a Order_entry.Stats.t [@rtlmangle "_"]
      ; t2t_valid : 'a
      ; t2t : 'a [@bits 32]
      }
    [@@deriving hardcaml]
  end

  let create ~fast scope (i : _ I.t) : _ O.t =
    let fh =
      Feed_handler.create scope { clock = i.clock; clear = i.clear; cfg = Timing_top.config (); rx = i.rx }
    in
    let lat =
      Latency_monitor.create
        ~offset:Feed_handler.command_offset
        scope
        { clock = i.clock; clear = i.clear; cmd = fh.cmd; event = fh.event.valid }
    in
    let oe =
      Order_entry.create
        ~rule
        ?fast:(if fast then Some (fh.command, fh.book_quiet) else None)
        scope
        ~clock:i.clock
        ~clear:i.clear
        ~event:fh.event
        ~message_time:lat.message_time
        ~now:lat.now
    in
    { O.txen = oe.txen; txd = oe.txd; stats = oe.stats; t2t_valid = oe.t2t_valid; t2t = oe.t2t }
  ;;
end

module Sim = Cyclesim.With_interface (Top.I) (Top.O)

let run ~fast =
  let sim = Sim.create (Top.create ~fast (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim
  and o = Cyclesim.outputs sim in
  let cycle = ref 0 in
  let last_byte = Hashtbl.create (module Int) in
  let wire = Buffer.create 256 in
  let frames = Queue.create () in
  let rises = Queue.create () (* cycle of each TX_EN rise *) in
  let samples = Queue.create () in
  let prev_en = ref false in
  let step () =
    Cyclesim.cycle sim;
    incr cycle;
    let en = Bits.to_bool !(o.txen) in
    if en && not !prev_en then Queue.enqueue rises !cycle;
    if en then Buffer.add_char wire (Char.of_int_exn (Bits.to_int_trunc !(o.txd)));
    if (not en) && !prev_en
    then (
      Queue.enqueue frames (Buffer.contents wire);
      Buffer.clear wire);
    prev_en := en;
    if Bits.to_bool !(o.t2t_valid) then Queue.enqueue samples (Bits.to_int_trunc !(o.t2t))
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
  idle 5000;
  (* the model *)
  let book = Book.create Timing_top.default_symbols in
  let strategy = Ouch.Strategy.create rule in
  let expected = Queue.create () in
  let next_seq = ref 1 in
  for trial = 0 to 15 do
    let messages =
      Quickcheck.random_value ~seed:(`Deterministic (sprintf "orders %d" trial)) Gen.random_messages
      |> Gen.batch ~index:trial
    in
    let rec packets ms k =
      match ms with
      | [] -> ()
      | _ ->
        let now = List.take ms (1 + (k % 4))
        and rest = List.drop ms (1 + (k % 4)) in
        let sequence = !next_seq in
        next_seq := !next_seq + List.length now;
        List.iteri now ~f:(fun j m ->
          Option.iter (Book.apply book m) ~f:(fun tob ->
            Option.iter (Ouch.Strategy.on_tob strategy ~seq:(sequence + j) tob) ~f:(fun order ->
              Queue.enqueue expected (sequence + j, order))));
        let raw = List.map now ~f:Itch.to_string in
        let frame =
          Packet.frame
            Packet.default_endpoints
            (Packet.Mold.to_string
               { session = "ORDERS0001"; sequence; messages = raw; end_of_session = false })
        in
        let ends = Hashtbl.create (module Int) in
        let pos = ref Packet.first_block_offset in
        List.iteri raw ~f:(fun j m ->
          pos := !pos + 2 + String.length m;
          Hashtbl.set ends ~key:(!pos - 1) ~data:(sequence + j));
        let n = String.length frame in
        String.iteri frame ~f:(fun k c ->
          i.rx.valid := Bits.vdd;
          i.rx.data := Bits.of_int_trunc ~width:8 (Char.to_int c);
          i.rx.first := Bits.of_bool (k = 0);
          i.rx.last := Bits.of_bool (k = n - 1);
          Option.iter (Hashtbl.find ends k) ~f:(fun seq -> Hashtbl.set last_byte ~key:seq ~data:(!cycle + 1));
          step ());
        i.rx.first := Bits.gnd;
        i.rx.last := Bits.gnd;
        idle 20;
        packets rest (k + 1)
    in
    packets messages trial
  done;
  idle 20_000;
  (* frames: preamble and SFD, the model's frame, its FCS *)
  let want =
    Queue.to_list expected
    |> List.map ~f:(fun (_, order) ->
      let f =
        Packet.frame ~udp_checksum:false Packet.order_endpoints (Ouch.enter_order_to_string order)
      in
      let fcs = Crc32_sw.fcs f in
      String.make 7 '\x55'
      ^ "\xd5"
      ^ f
      ^ String.init 4 ~f:(fun k -> Char.of_int_exn ((fcs lsr (8 * k)) land 0xff)))
  in
  let got = Queue.to_list frames in
  printf "orders: model %d, hardware %d (fast path %d, dropped %d)\n" (List.length want) (List.length got)
    (Bits.to_int_trunc !(o.stats.fast)) (Bits.to_int_trunc !(o.stats.dropped));
  printf "frames equal the model's: %b\n" ([%equal: string list] got want);
  (* tick-to-trade: TX_EN rise minus the trigger's last byte *)
  let t2t_want =
    List.map2_exn (Queue.to_list expected) (Queue.to_list rises) ~f:(fun (seq, _) rise ->
      rise - Hashtbl.find_exn last_byte seq)
  in
  printf "tick-to-trade samples equal the definition: %b\n"
    ([%equal: int list] (Queue.to_list samples) t2t_want);
  let sorted = List.sort t2t_want ~compare:Int.compare |> Array.of_list in
  let n = Array.length sorted in
  printf "tick-to-trade, cycles: min %d median %d max %d\n" sorted.(0) sorted.(n / 2) sorted.(n - 1);
  let s = o.stats.t2t in
  let g r = Bits.to_int_trunc !r in
  printf "hardware histogram: count %d p50 %d max %d\n" (g s.count) (g s.p50) (g s.max);
  ()
;;

let%expect_test "orders equal the model's, byte for byte; tick-to-trade per order" =
  print_endline "waiting for the book:";
  run ~fast:false;
  print_endline "with the fast path:";
  run ~fast:true;
  [%expect {|
    waiting for the book:
    orders: model 41, hardware 41 (fast path 0, dropped 0)
    frames equal the model's: true
    tick-to-trade samples equal the definition: true
    tick-to-trade, cycles: min 19 median 19 max 30
    hardware histogram: count 41 p50 19 max 30
    with the fast path:
    orders: model 41, hardware 41 (fast path 32, dropped 0)
    frames equal the model's: true
    tick-to-trade samples equal the definition: true
    tick-to-trade, cycles: min 7 median 7 max 30
    hardware histogram: count 41 p50 7 max 30
    |}]
;;
