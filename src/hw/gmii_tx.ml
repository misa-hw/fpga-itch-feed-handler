(* GMII transmit MAC for fixed-length frames, one byte per clock.

   On [start] (taken only while idle) the frame is loaded into a shift
   register, first byte in the least significant bits, so each cycle's byte
   is a register and no wide byte-select sits on the 125 MHz path. The wire
   sees 7 preamble bytes, the SFD, the frame, its FCS (the complement of
   the Ethernet CRC-32, least significant byte first) and then at least the
   12-byte inter-frame gap. [sof] is high in the cycle TX_EN rises, for
   latency measurement. Frames must be at least 60 bytes: there is no
   padding. Outputs are registered. *)

open! Core
open! Hardcaml
open Signal

type t =
  { txen : Signal.t
  ; txd : Signal.t
  ; busy : Signal.t
  ; sof : Signal.t
  }

module State = struct
  type t =
    | Idle
    | Preamble
    | Data
    | Fcs
    | Gap
  [@@deriving sexp_of, compare ~localize, enumerate]
end

let preamble_bytes = 8 (* 7 x 0x55, then the SFD 0xD5 *)
let gap_bytes = 12

let create ~spec ~start ~frame =
  let open Always in
  let bytes = Signal.width frame / 8 in
  if bytes * 8 <> Signal.width frame || bytes < 60
  then raise_s [%message "Gmii_tx: frame must be a whole number of bytes, at least 60" (bytes : int)];
  let sm = State_machine.create (module State) spec in
  let count = Variable.reg spec ~width:(num_bits_to_represent (Int.max bytes preamble_bytes)) in
  let sh = Variable.reg spec ~width:(Signal.width frame) in
  let crc = Variable.reg spec ~width:32 in
  let fcs = Variable.reg spec ~width:32 in
  let txen = Variable.reg spec ~width:1 in
  let txd = Variable.reg spec ~width:8 in
  let sof = Variable.reg spec ~width:1 in
  let byte = sel_bottom sh.value ~width:8 in
  let crc_next = Crc32.next ~crc:crc.value ~data:byte in
  compile
    [ sof <-- gnd
    ; sm.switch
        [ ( Idle
          , [ txen <-- gnd
            ; when_
                start
                [ sh <-- frame
                ; crc <--. Crc32.init
                ; count <--. 0
                ; txen <-- vdd
                ; txd <--. 0x55
                ; sof <-- vdd
                ; sm.set_next Preamble
                ] ] )
        ; ( Preamble
          , [ count <-- count.value +:. 1
            ; if_
                (count.value ==:. preamble_bytes - 2)
                [ txd <--. 0xd5; count <--. 0; sm.set_next Data ]
                [ txd <--. 0x55 ]
            ] )
        ; ( Data
          , [ txd <-- byte
            ; sh <-- srl sh.value ~by:8
            ; crc <-- crc_next
            ; count <-- count.value +:. 1
            ; when_ (count.value ==:. bytes - 1) [ fcs <-- ~:crc_next; count <--. 0; sm.set_next Fcs ]
            ] )
        ; ( Fcs
          , [ txd <-- sel_bottom fcs.value ~width:8
            ; fcs <-- srl fcs.value ~by:8
            ; count <-- count.value +:. 1
            ; when_ (count.value ==:. 3) [ count <--. 0; sm.set_next Gap ]
            ] )
        ; ( Gap
          , [ txen <-- gnd
            ; txd <--. 0
            ; count <-- count.value +:. 1
            ; when_ (count.value ==:. gap_bytes - 1) [ sm.set_next Idle ]
            ] )
        ]
    ];
  { txen = txen.value; txd = txd.value; busy = ~:(sm.is Idle); sof = sof.value }
;;
