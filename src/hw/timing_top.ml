(* A wrapper around [Feed_handler] for synthesis and timing reports only.

   The pipeline has >1000 configuration and counter ports, more than the
   package has pins, so here: configuration is constant (the default
   endpoints and symbols), the MAC byte stream comes from pins through
   input registers, and every output bit (event and counters) is XOR-folded,
   through a register, into 8 output pins, so that no logic can be optimised
   away. There is a power-on reset as on the board (see [Board_top]). *)

open! Core
open! Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; rx_valid : 'a
    ; rx_data : 'a [@bits 8]
    ; rx_first : 'a
    ; rx_last : 'a
    ; rx_err : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t = { fold : 'a [@bits 8] } [@@deriving hardcaml]
end

let symbol_const s =
  String.to_list (Itch_model.Itch.pad_stock s)
  |> List.map ~f:(fun c -> of_unsigned_int ~width:8 (Char.to_int c))
  |> concat_msb
;;

let default_symbols = [ "QQQ"; "SPY"; "IWM"; "DIA"; "TQQQ"; "SQQQ"; "AMD"; "UVXY" ]

let config ?(symbols = default_symbols) () : Signal.t Feed_handler.Config.t =
  let ep = Net_config.endpoints in
  { net =
      { mac = of_unsigned_int ~width:48 ep.mac
      ; ip = of_unsigned_int ~width:32 ep.ip
      ; port = of_unsigned_int ~width:16 ep.port
      }
  ; symbols =
      Array.init Symbol_filter.num_slots ~f:(fun k ->
        match List.nth symbols k with
        | Some s -> symbol_const s
        | None -> zero 64)
  ; symbol_enable = of_unsigned_int ~width:8 ((1 lsl List.length symbols) - 1)
  }
;;

(* Holds [clear] high for the first 16 cycles after configuration: the FPGA
   starts with every flip-flop at 0, which is not a valid one-hot state. *)
let power_on_clear ~clock =
  let count =
    reg_fb (Reg_spec.create ~clock ()) ~width:5 ~f:(fun c -> mux2 (msb c) c (c +:. 1))
  in
  ~:(msb count)
;;

let create scope (i : _ I.t) : _ O.t =
  let clear = power_on_clear ~clock:i.clock in
  let spec = Reg_spec.create ~clock:i.clock () in
  let r = reg spec in
  let rx =
    { Stream.Mac_rx.valid = r i.rx_valid
    ; data = r i.rx_data
    ; first = r i.rx_first
    ; last = r i.rx_last
    ; err = r i.rx_err
    }
  in
  let o = Feed_handler.create scope { clock = i.clock; clear; cfg = config (); rx } in
  let all_bits =
    Feed_handler.O.to_list o |> List.concat_map ~f:bits_lsb
  in
  (* fold in chunks of 8, registered at each level so the fold is not critical *)
  let rec fold bits =
    if List.length bits <= 8
    then bits
    else (
      let groups = List.chunks_of bits ~length:8 in
      let xors = List.map groups ~f:(fun g -> r (List.reduce_exn g ~f:( ^: ))) in
      fold xors)
  in
  { O.fold = concat_lsb (fold all_bits) |> fun s -> uresize s ~width:8 }
;;
