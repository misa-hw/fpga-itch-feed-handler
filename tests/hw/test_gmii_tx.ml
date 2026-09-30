(* Gmii_tx: the bytes on the wire (preamble, SFD, frame, FCS from the
   software CRC), the gap between frames, and a loopback into Gmii_rx,
   which must deliver each frame intact with no CRC error. *)

open! Core
open! Hardcaml
open Feed_hw
open Net

let frame_bytes = 89

module Top = struct
  module I = struct
    type 'a t =
      { clock : 'a
      ; clear : 'a
      ; start : 'a
      ; frame : 'a [@bits 8 * frame_bytes]
      }
    [@@deriving hardcaml]
  end

  module O = struct
    type 'a t =
      { txen : 'a
      ; txd : 'a [@bits 8]
      ; busy : 'a
      ; sof : 'a
      ; rx : 'a Stream.Mac_rx.t [@rtlmangle "_"]
      ; crc_errors : 'a [@bits 32]
      }
    [@@deriving hardcaml]
  end

  let create scope (i : _ I.t) : _ O.t =
    let open Signal in
    let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
    let tx = Gmii_tx.create ~spec ~start:i.start ~frame:i.frame in
    let rx =
      Gmii_rx.create
        scope
        { clock = i.clock; clear = i.clear; rx_dv = tx.txen; rx_er = gnd; rxd = tx.txd }
    in
    { O.txen = tx.txen; txd = tx.txd; busy = tx.busy; sof = tx.sof; rx = rx.rx; crc_errors = rx.crc_errors }
  ;;
end

module Sim = Cyclesim.With_interface (Top.I) (Top.O)

(* first byte in the least significant bits *)
let to_bits s =
  String.to_list s
  |> List.map ~f:(fun c -> Bits.of_int_trunc ~width:8 (Char.to_int c))
  |> Bits.concat_lsb
;;

let%expect_test "wire bytes, inter-frame gap, and loopback into the receive MAC" =
  let frames =
    List.init 3 ~f:(fun k ->
      let payload = String.init 47 ~f:(fun j -> Char.of_int_exn (((k * 31) + j) land 0xff)) in
      Packet.frame Packet.default_endpoints payload)
  in
  List.iter frames ~f:(fun f -> assert (String.length f = frame_bytes));
  let sim = Sim.create (Top.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim
  and o = Cyclesim.outputs sim in
  i.clear := Bits.vdd;
  Cyclesim.cycle sim;
  i.clear := Bits.gnd;
  let wire = Buffer.create 512 and received = Buffer.create 512 in
  let gaps = Queue.create () and idle = ref 0 and in_frame = ref false and started = ref 0 in
  let sofs = ref 0 in
  let frames_rx = Queue.create () in
  let cycle () =
    Cyclesim.cycle sim;
    if Bits.to_bool !(o.sof) then incr sofs;
    let en = Bits.to_bool !(o.txen) in
    if en
    then (
      if not !in_frame
      then (
        if !started > 0 then Queue.enqueue gaps !idle;
        incr started);
      in_frame := true;
      idle := 0;
      Buffer.add_char wire (Char.of_int_exn (Bits.to_int_trunc !(o.txd))))
    else (
      in_frame := false;
      incr idle);
    let r = o.rx in
    if Bits.to_bool !(r.valid)
    then (
      Buffer.add_char received (Char.of_int_exn (Bits.to_int_trunc !(r.data)));
      if Bits.to_bool !(r.last)
      then (
        Queue.enqueue frames_rx (Buffer.contents received, Bits.to_bool !(r.err));
        Buffer.clear received))
  in
  (* each frame starts as soon as the MAC is idle again *)
  List.iter frames ~f:(fun f ->
    i.frame := to_bits f;
    i.start := Bits.vdd;
    cycle ();
    i.start := Bits.gnd;
    while Bits.to_bool !(o.busy) do
      cycle ()
    done);
  for _ = 1 to 40 do
    cycle ()
  done;
  let expected_wire =
    List.map frames ~f:(fun f ->
      let fcs = Itch_model.Crc32_sw.fcs f in
      String.make 7 '\x55'
      ^ "\xd5"
      ^ f
      ^ String.init 4 ~f:(fun k -> Char.of_int_exn ((fcs lsr (8 * k)) land 0xff)))
    |> String.concat
  in
  printf "wire bytes as expected: %b (%d bytes)\n" (String.equal (Buffer.contents wire) expected_wire) (Buffer.length wire);
  printf "start-of-frame pulses: %d\n" !sofs;
  printf "idle cycles between frames: %s\n" (Queue.to_list gaps |> List.map ~f:Int.to_string |> String.concat ~sep:", ");
  printf
    "received by Gmii_rx: %d frames, intact: %b, error flags: %b, CRC errors: %d\n"
    (Queue.length frames_rx)
    ([%equal: string list] (Queue.to_list frames_rx |> List.map ~f:fst) frames)
    (Queue.exists frames_rx ~f:snd)
    (Bits.to_int_trunc !(o.crc_errors));
  [%expect {|
    wire bytes as expected: true (303 bytes)
    start-of-frame pulses: 3
    idle cycles between frames: 12, 12
    received by Gmii_rx: 3 frames, intact: true, error flags: false, CRC errors: 0
    |}]
;;
