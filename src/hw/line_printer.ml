(* Prints fixed-format text lines made of literal characters and hex digits
   of signals: the line layouts are OCaml lists, turned into a character
   multiplexer indexed by a position counter. The fields must stay constant
   while a line is printed (the caller latches them). *)

open! Core
open! Hardcaml
open Signal

type item =
  | Lit of string
  | Hex of Signal.t (* printed as ceil(width/4) hex digits, most significant first *)

let hex_char nibble =
  mux nibble (List.map (String.to_list "0123456789abcdef") ~f:(fun c -> of_unsigned_int ~width:8 (Char.to_int c)))
;;

(* the line as a list of 8-bit character signals *)
let chars items =
  List.concat_map items ~f:(function
    | Lit s -> List.map (String.to_list s) ~f:(fun c -> of_unsigned_int ~width:8 (Char.to_int c))
    | Hex s ->
      let digits = (Signal.width s + 3) / 4 in
      let s = uresize s ~width:(4 * digits) in
      List.init digits ~f:(fun d ->
        let hi = (4 * (digits - d)) - 1 in
        hex_char (select s ~high:hi ~low:(hi - 3))))
;;

(* [start] begins printing [lines.(which)]; [busy] until the last character
   has been handed to the UART. *)
let create ~clock ~clear ~(lines : item list array) ~which ~start ~uart_ready =
  let spec = Reg_spec.create ~clock ~clear () in
  let open Always in
  let lines = Array.map lines ~f:chars in
  let max_len = Array.fold lines ~init:0 ~f:(fun m l -> Int.max m (List.length l)) in
  let pos_w = num_bits_to_represent max_len in
  let busy = Variable.reg spec ~width:1 in
  let line = Variable.reg spec ~width:(Int.max 1 (Signal.width which)) in
  let pos = Variable.reg spec ~width:pos_w in
  let char_of l = mux pos.value (List.map l ~f:Fn.id @ [ zero 8 ]) in
  let len_of l = of_unsigned_int ~width:pos_w (List.length l) in
  let cur_char = mux line.value (Array.to_list (Array.map lines ~f:char_of)) in
  let cur_len = mux line.value (Array.to_list (Array.map lines ~f:len_of)) in
  let send = busy.value &: uart_ready in
  compile
    [ if_
        busy.value
        [ when_
            uart_ready
            [ pos <-- pos.value +:. 1; when_ (pos.value +:. 1 ==: cur_len) [ busy <-- gnd ] ]
        ]
        [ when_ start [ busy <-- vdd; line <-- which; pos <--. 0 ] ]
    ];
  busy.value, send, cur_char
;;
