(* CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320) as a hardware
   generator. The update of the CRC register by n data bits is linear over
   GF(2), so each next-state bit is the XOR of a fixed set of current-state
   and data bits; those sets are found by running the bitwise software CRC
   on unit vectors. Used 1 byte wide by the Ethernet receiver (FCS check)
   and 168 bits wide to hash top-of-book events on the board. *)

open! Core
open! Hardcaml
open Signal

let update_bits = Itch_model.Crc32_sw.update_bits

(* Ethernet: initial 0xFFFFFFFF, final complement; running the CRC over a
   frame including its FCS leaves this constant in the register. *)
let residue = 0xDEBB20E3
let init = 0xFFFFFFFF

(* [next ~crc ~data] for a [Signal.width data]-bit update, data LSB first.
   Built from the bitwise model: bit j of the result depends on state bit i
   iff flipping i alone flips j (linearity). *)
let next ~crc ~data =
  let nd = Signal.width data in
  let state_dep = Array.init 32 ~f:(fun i -> update_bits (1 lsl i) ~data:0 ~nbits:nd) in
  let data_dep =
    Array.init nd ~f:(fun i ->
      (* one data bit at a time, from a zero state; data wider than 62 bits
         is fed in 62-bit chunks through the linear state map *)
      let crc = ref 0 in
      let remaining = ref nd and pos = ref 0 in
      while !remaining > 0 do
        let chunk = Int.min 62 !remaining in
        let d = if i >= !pos && i < !pos + chunk then 1 lsl (i - !pos) else 0 in
        crc := update_bits !crc ~data:d ~nbits:chunk;
        pos := !pos + chunk;
        remaining := !remaining - chunk
      done;
      !crc)
  in
  List.init 32 ~f:(fun j ->
    let terms =
      List.filter_mapi (Array.to_list state_dep) ~f:(fun i m ->
        if (m lsr j) land 1 = 1 then Some (bit crc ~pos:i) else None)
      @ List.filter_mapi (Array.to_list data_dep) ~f:(fun i m ->
        if (m lsr j) land 1 = 1 then Some (bit data ~pos:i) else None)
    in
    match terms with
    | [] -> gnd
    | _ -> List.reduce_exn terms ~f:( ^: ))
  |> concat_lsb
;;
