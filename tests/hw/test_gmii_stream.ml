(* The GMII MAC in front of the complete feed handler, on real frames sent
   the way a PHY delivers them at 1 Gb/s: preamble, SFD, frame, FCS, and
   only the minimum inter-frame gap. The full-replay verification
   (bin/verify.ml) starts after the MAC, so this is where back-to-back
   frames through Gmii_rx are checked: every frame accepted, every message
   in sequence (no duplicates, no gaps), no CRC errors. Also with an 8-byte
   gap and a shortened preamble, which some PHYs deliver. *)

open! Core
open! Hardcaml
open Feed_hw
open Net

module Top = struct
  module I = Gmii_rx.I

  module O = struct
    type 'a t =
      { frames : 'a [@bits 32]
      ; accepted : 'a [@bits 32]
      ; messages : 'a [@bits 32]
      ; duplicates : 'a [@bits 32]
      ; gaps : 'a [@bits 32]
      ; crc_errors : 'a [@bits 32]
      }
    [@@deriving hardcaml]
  end

  let create scope (i : _ I.t) : _ O.t =
    let mac = Gmii_rx.create scope i in
    let fh =
      Feed_handler.create
        scope
        { clock = i.clock; clear = i.clear; cfg = Timing_top.config (); rx = mac.rx }
    in
    let c = fh.counters in
    { frames = c.frame.frames
    ; accepted = c.frame.accepted
    ; messages = c.mold.messages
    ; duplicates = c.mold.duplicates
    ; gaps = c.mold.gaps
    ; crc_errors = mac.crc_errors
    }
  ;;
end

module Sim = Cyclesim.With_interface (Top.I) (Top.O)

let run pcap ~frames ~ifg ~preamble =
  let sim = Sim.create (Top.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim
  and o = Cyclesim.outputs sim in
  i.clear := Bits.vdd;
  Cyclesim.cycle sim;
  i.clear := Bits.gnd;
  let idle n =
    i.rx_dv := Bits.gnd;
    for _ = 1 to n do
      Cyclesim.cycle sim
    done
  in
  idle 5000 (* the order book clears its tables *);
  let _ =
    Pcap.iter ~max_packets:frames pcap ~f:(fun ~ts_ns:_ frame ->
      let fcs = Itch_model.Crc32_sw.fcs frame in
      String.make preamble '\x55'
      ^ "\xd5"
      ^ frame
      ^ String.init 4 ~f:(fun k -> Char.of_int_exn ((fcs lsr (8 * k)) land 0xff))
      |> String.iter ~f:(fun c ->
        i.rx_dv := Bits.vdd;
        i.rxd := Bits.of_int_trunc ~width:8 (Char.to_int c);
        Cyclesim.cycle sim);
      idle ifg)
  in
  let g r = Bits.to_int_trunc !r in
  (* silent when correct, so the test also passes without the pcap *)
  if not
       (g o.frames = frames
        && g o.accepted = frames
        && g o.messages >= frames
        && g o.duplicates = 0
        && g o.gaps = 0
        && g o.crc_errors = 0)
  then
    printf
      "gap %d, preamble %d: %d frames, %d accepted, %d messages, %d duplicates, %d gaps, %d CRC errors\n"
      ifg
      preamble
      (g o.frames)
      (g o.accepted)
      (g o.messages)
      (g o.duplicates)
      (g o.gaps)
      (g o.crc_errors)
;;

let%expect_test "real frames back to back through the GMII MAC" =
  (match Lazy.force Sample_data.tracked_pcap with
   | None -> ()
   | Some pcap ->
     List.iter [ 12, 7; 8, 7; 12, 5 ] ~f:(fun (ifg, preamble) ->
       run pcap ~frames:6000 ~ifg ~preamble));
  [%expect {| |}]
;;
