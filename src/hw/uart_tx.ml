(* 8N1 UART transmitter with a one-byte handshake: [ready] is high when a
   byte can be accepted; a byte is taken in the cycle [valid &: ready]. *)

open! Core
open! Hardcaml
open Signal

let create ~clock ~clear ~bit_cycles ~valid ~data =
  let spec = Reg_spec.create ~clock ~clear () in
  let open Always in
  (* 10-bit frame: stop(1) data(8, LSB first) start(0); shifted out LSB first *)
  let shreg = Variable.reg spec ~width:10 in
  let bits_left = Variable.reg spec ~width:4 in
  let timer = Variable.reg spec ~width:(num_bits_to_represent bit_cycles) in
  let busy = bits_left.value <>:. 0 in
  let ready = ~:busy in
  compile
    [ if_
        busy
        [ if_
            (timer.value ==:. bit_cycles - 1)
            [ timer <--. 0
            ; shreg <-- (vdd @: select shreg.value ~high:9 ~low:1)
            ; bits_left <-- bits_left.value -:. 1
            ]
            [ timer <-- timer.value +:. 1 ]
        ]
        [ when_ valid [ shreg <-- (vdd @: data @: gnd); bits_left <--. 10; timer <--. 0 ] ]
    ];
  (* idle high; while busy, the current bit *)
  let tx = mux2 busy (lsb shreg.value) vdd in
  ready, reg spec ~clear_to:vdd tx
;;
