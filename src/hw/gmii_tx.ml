(* GMII transmit MAC for fixed-length frames, one byte per clock.

   On [start] (taken while idle, or while holding a pre-formed preamble)
   the frame is loaded into a shift register, first byte in the least
   significant bits, so each cycle's byte is a register and no wide
   byte-select sits on the 125 MHz path. The wire sees the preamble (at
   least 7 bytes of 0x55), the SFD, the frame, its FCS (the complement of
   the Ethernet CRC-32, least significant byte first) and then at least the
   12-byte inter-frame gap. Frames must be at least 60 bytes: there is no
   padding. Outputs are registered.

   [prestart] begins the preamble before the frame is known and holds it
   (for as long as it takes) until [start], which then sends the SFD as
   soon as 7 preamble bytes are out: a frame decided while its preamble is
   already on the wire starts 8 bytes sooner. [cancel] while holding ends
   the burst before any SFD, which no receiver takes for a frame, and keeps
   the gap. [first] is high in the cycle the frame's first byte is on TXD;
   [sof] in the cycle TX_EN rises.

   [late] = (index, value): frame byte [index] is sent from [value] instead
   of the frame loaded at [start], so it may still change after the frame
   has started (a price's last byte, for an order decided before it
   arrived); the FCS covers the byte actually sent. *)

open! Core
open! Hardcaml
open Signal

type t =
  { txen : Signal.t
  ; txd : Signal.t
  ; busy : Signal.t (* not idle: holding a preamble, or sending *)
  ; holding : Signal.t (* a pre-formed preamble waits for [start] or [cancel] *)
  ; sof : Signal.t
  ; first : Signal.t
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

let min_preamble = 7 (* bytes of 0x55 before the SFD 0xD5 *)
let gap_bytes = 12

let create ?(prestart = gnd) ?(cancel = gnd) ?late ~spec ~start ~frame () =
  let open Always in
  let bytes = Signal.width frame / 8 in
  if bytes * 8 <> Signal.width frame || bytes < 60
  then raise_s [%message "Gmii_tx: frame must be a whole number of bytes, at least 60" (bytes : int)];
  let sm = State_machine.create (module State) spec in
  let count = Variable.reg spec ~width:(num_bits_to_represent bytes) in
  let sent = Variable.reg spec ~width:3 (* preamble bytes out, saturating at 7 *) in
  let started = Variable.reg spec ~width:1 (* the frame is loaded *) in
  let sh = Variable.reg spec ~width:(Signal.width frame) in
  let crc = Variable.reg spec ~width:32 in
  let fcs = Variable.reg spec ~width:32 in
  let txen = Variable.reg spec ~width:1 in
  let txd = Variable.reg spec ~width:8 in
  let sof = Variable.reg spec ~width:1 in
  let first = Variable.reg spec ~width:1 in
  let byte =
    match late with
    | None -> sel_bottom sh.value ~width:8
    | Some (index, value) ->
      if index < 0 || index >= bytes then raise_s [%message "Gmii_tx: late byte outside the frame" (index : int)];
      mux2 (count.value ==:. index) value (sel_bottom sh.value ~width:8)
  in
  let crc_next = Crc32.next ~crc:crc.value ~data:byte in
  let load = [ sh <-- frame; crc <--. Crc32.init; started <-- vdd ] in
  let enough = sent.value ==:. min_preamble in
  compile
    [ sof <-- gnd
    ; first <-- gnd
    ; sm.switch
        [ ( Idle
          , [ txen <-- gnd
            ; started <-- gnd
            ; when_
                (start |: prestart)
                [ when_ start load
                ; txen <-- vdd
                ; txd <--. 0x55
                ; sent <--. 1
                ; sof <-- vdd
                ; sm.set_next Preamble
                ]
            ] )
        ; ( Preamble
          , [ if_
                ((started.value |: start) &: enough)
                [ when_ (~:(started.value)) load
                ; txd <--. 0xd5
                ; count <--. 0
                ; sm.set_next Data
                ]
                [ if_
                    (~:(started.value) &: ~:start &: cancel)
                    [ txen <-- gnd; txd <--. 0; count <--. 0; sm.set_next Gap ]
                    [ when_ (~:(started.value) &: start) load
                    ; txd <--. 0x55
                    ; when_ ~:enough [ sent <-- sent.value +:. 1 ]
                    ]
                ]
            ] )
        ; ( Data
          , [ txd <-- byte
            ; first <-- (count.value ==:. 0)
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
  { txen = txen.value
  ; txd = txd.value
  ; busy = ~:(sm.is Idle)
  ; holding = sm.is Preamble &: ~:(started.value)
  ; sof = sof.value
  ; first = first.value
  }
;;
