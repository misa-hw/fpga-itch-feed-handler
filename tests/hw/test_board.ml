(* The whole board design in simulation: GMII frames (preamble, SFD, frame,
   FCS) in, UART text out, decoded from the tx pin and compared with the
   model. Cyclesim ticks every register on every cycle, so the two clock
   domains run at the same rate here; the asynchronous FIFO and the counter
   handshake still go through their synchronisers. Short UART bits and a
   short "second" keep the run small. *)

open! Core
open! Hardcaml
open Feed_hw
open Itch_model
open Net
module Sim = Cyclesim.With_interface (Board_top.I) (Board_top.O)

let bit_cycles = 4

type t =
  { sim : Sim.t
  ; i : Bits.t ref Board_top.I.t
  ; o : Bits.t ref Board_top.O.t
  ; text : Buffer.t
  ; mutable uart_state : [ `Idle | `Bits of int * int * int ] (* start cycle, bit, byte *)
  ; mutable cycle : int
  }

let cycle t =
  Cyclesim.cycle t.sim;
  t.cycle <- t.cycle + 1;
  let tx = Bits.to_bool !(t.o.uart_tx) in
  (* sample each bit in its middle *)
  match t.uart_state with
  | `Idle -> if not tx then t.uart_state <- `Bits (t.cycle, 0, 0)
  | `Bits (start, n, byte) ->
    let middle = start + (bit_cycles / 2) + ((n + 1) * bit_cycles) in
    if t.cycle = middle
    then
      if n < 8
      then t.uart_state <- `Bits (start, n + 1, byte lor ((if tx then 1 else 0) lsl n))
      else (
        Buffer.add_char t.text (Char.of_int_exn byte);
        t.uart_state <- `Idle)
;;

let idle t n =
  t.i.e_rxdv := Bits.gnd;
  for _ = 1 to n do
    cycle t
  done
;;

let wire_frame ?(corrupt = false) frame =
  let fcs = Crc32_sw.fcs frame in
  let fcs = if corrupt then fcs lxor 1 else fcs in
  String.make 7 '\x55'
  ^ "\xd5"
  ^ frame
  ^ String.init 4 ~f:(fun k -> Char.of_int_exn ((fcs lsr (8 * k)) land 0xff))
;;

let send_gmii ?(corrupt = false) t frame =
  String.iter (wire_frame ~corrupt frame) ~f:(fun c ->
    t.i.e_rxdv := Bits.vdd;
    t.i.e_rxd := Bits.of_int_trunc ~width:8 (Char.to_int c);
    cycle t);
  idle t 12
;;

let send_mii ?(corrupt = false) t frame =
  String.iter (wire_frame ~corrupt frame) ~f:(fun c ->
    let byte = Char.to_int c in
    List.iter [ byte land 15; byte lsr 4 ] ~f:(fun nibble ->
      t.i.e_rxdv := Bits.vdd;
      t.i.e_rxd := Bits.of_int_trunc ~width:8 nibble;
      cycle t));
  idle t 12
;;

let create ?(mii_mode = false) () =
  let scope = Scope.create ~flatten_design:true () in
  let sim =
    Sim.create (Board_top.create ~mii_mode ~bit_cycles ~second:20_000 ~phy_reset_cycles:8 scope)
  in
  let t =
    { sim
    ; i = Cyclesim.inputs sim
    ; o = Cyclesim.outputs sim
    ; text = Buffer.create 4096
    ; uart_state = `Idle
    ; cycle = 0
    }
  in
  t.i.reset_n := Bits.vdd;
  idle t 5000 (* power-on reset, then the order book clears its tables *);
  t
;;

let status_field line name =
  String.split line ~on:' '
  |> List.find_map ~f:(fun kv ->
    match String.lsplit2 kv ~on:'=' with
    | Some (k, v) when String.equal k name -> Some v
    | _ -> None)
;;

let replay_real_pcap ~mii_mode =
  match Lazy.force Sample_data.tracked_pcap with
  | None -> ()
  | Some _ ->
    (match Sample_data.find "build/board_slow.pcap" with
     | None -> ()
     | Some pcap ->
       let t = create ~mii_mode () in
       let book = Book.create Timing_top.default_symbols in
       let expected = Queue.create () and hash = ref 0 in
       let n_packets = 400 in
       let _ =
         Pcap.iter ~max_packets:n_packets pcap ~f:(fun ~ts_ns:_ frame ->
           (match Packet.parse frame with
            | Error e -> failwith e
            | Ok p ->
              let mold = Packet.Mold.of_string p.udp_payload |> Result.ok_or_failwith in
              List.iteri mold.messages ~f:(fun k m ->
                let seq = mold.sequence + k in
                Option.iter (Book.apply book (Itch.of_string m)) ~f:(fun (e : Book.Tob.t) ->
                  hash := Crc32_sw.hash_tob_event !hash ~seq e;
                  Queue.enqueue
                    expected
                    (sprintf
                       "E %08x %x %08x %08x %08x %08x"
                       seq
                       e.slot
                       e.bid_price
                       e.bid_shares
                       e.ask_price
                       e.ask_shares))));
           (if mii_mode then send_mii else send_gmii) t frame;
           (* slow enough for the UART: ~2 lines per packet at most *)
           idle t 1500)
       in
       (if mii_mode then send_mii else send_gmii)
         t
         ~corrupt:true
         (Packet.frame Packet.default_endpoints "garbage");
       idle t 400_000 (* let the UART drain: status lines are long *);
       let lines = String.split_lines (Buffer.contents t.text) in
       let e_lines = List.filter lines ~f:(String.is_prefix ~prefix:"E ") in
       let status =
         List.filter lines ~f:(fun line ->
           String.is_prefix line ~prefix:"S" && Option.is_some (status_field line "lost"))
         |> List.last_exn
       in
       (* silent when everything matches (so the test also passes without
          the sample data, like every data-dependent test here): all event
          lines equal the model's, all 400 frames accepted, the corrupted
          frame counted as the one FCS error, and the on-chip change count
          and hash equal the model's *)
       let f name = Option.value_exn (status_field status name) in
       let ok =
         [%equal: string list] e_lines (Queue.to_list expected)
         && Char.equal status.[1] '1'
         && String.equal (f "frm") (sprintf "%08x" (n_packets + 1))
         && String.equal (f "acc") (sprintf "%08x" n_packets)
         && String.equal (f "fcs") "00000001"
         && String.equal (f "chg") (sprintf "%08x" (Queue.length expected))
         && String.equal (f "hash") (sprintf "%08x" !hash)
         && String.equal (f "lost") "00000000"
       in
       if not ok
       then (
         printf
           "%d E lines, %d in the model\n"
           (List.length e_lines)
           (Queue.length expected);
         Queue.iter expected ~f:(fun l ->
           if not (List.mem e_lines l ~equal:String.equal) then printf "missing: %s\n" l);
         List.iter lines ~f:(fun l ->
           if not (String.is_prefix l ~prefix:"E " || String.is_prefix l ~prefix:"S")
           then printf "other text: %S\n" l);
         printf "status: %s\nmodel: chg=%08x hash=%08x\n" status (Queue.length expected) !hash))
;;

let%expect_test "board: GMII in, UART out, equal to the model" =
  replay_real_pcap ~mii_mode:false;
  [%expect {| |}]
;;

let%expect_test "board: real packets in MII mode" =
  replay_real_pcap ~mii_mode:true;
  [%expect {| |}]
;;

let%expect_test "board: MII nibbles at 100 Mb/s, including FCS detection" =
  let t = create ~mii_mode:true () in
  let messages = List.take Test_samples.all 3 in
  let mold =
    Packet.Mold.to_string
      { session = "ITCH50SMPL"
      ; sequence = 1
      ; messages = List.map messages ~f:Itch.to_string
      ; end_of_session = false
      }
  in
  let frame = Packet.frame Packet.default_endpoints mold in
  let book = Book.create Timing_top.default_symbols in
  let expected = Queue.create () and hash = ref 0 in
  List.iteri messages ~f:(fun k msg ->
    Option.iter (Book.apply book msg) ~f:(fun (e : Book.Tob.t) ->
      let seq = k + 1 in
      hash := Crc32_sw.hash_tob_event !hash ~seq e;
      Queue.enqueue
        expected
        (sprintf
           "E %08x %x %08x %08x %08x %08x"
           seq
           e.slot
           e.bid_price
           e.bid_shares
           e.ask_price
           e.ask_shares)));
  send_mii t frame;
  idle t 3_000;
  send_mii t ~corrupt:true frame;
  idle t 50_000;
  let lines = String.split_lines (Buffer.contents t.text) in
  let events = List.filter lines ~f:(String.is_prefix ~prefix:"E ") in
  let status =
    List.filter lines ~f:(fun line ->
      String.is_prefix line ~prefix:"S" && Option.is_some (status_field line "lost"))
    |> List.last_exn
  in
  let f = status_field status in
  printf "MII events equal model: %b (%d)\n"
    ([%equal: string list] events (Queue.to_list expected))
    (List.length events);
  printf "frames=%s accepted=%s fcs=%s chg=%s hash=%s lost=%s\n"
    (Option.value_exn (f "frm"))
    (Option.value_exn (f "acc"))
    (Option.value_exn (f "fcs"))
    (Option.value_exn (f "chg"))
    (Option.value_exn (f "hash"))
    (Option.value_exn (f "lost"));
  printf "model chg=%08x hash=%08x\n" (Queue.length expected) !hash;
  [%expect {|
    MII events equal model: true (2)
    frames=00000002 accepted=00000001 fcs=00000001 chg=00000002 hash=0a41f851 lost=00000000
    model chg=00000002 hash=0a41f851
    |}]
;;
