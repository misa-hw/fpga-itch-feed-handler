(* GMII receive MAC: PHY byte stream -> [Stream.Mac_rx].

   GMII (1000BASE-T): one byte per rising edge of the PHY's 125 MHz RX_CLK,
   qualified by RX_DV; RX_ER flags a symbol error. A frame on the wire is
   7 x 0x55 preamble, 0xD5 SFD, the frame, and a 4-byte FCS.

   - The preamble and SFD are stripped.
   - The FCS is passed on as the frame's last 4 bytes: the frame parser
     delimits the payload by the UDP length, so to it they are padding.
     Stripping it meant holding every byte back until 4 later ones proved
     it was not FCS: 4 cycles on every byte, tick-to-trade included.
   - Each byte is held one cycle, until the next byte or RX_DV falling says
     whether it is the frame's last, marked [last].
   - The CRC-32 over frame + FCS must leave the standard residue; [err] (with
     [last]) reports a bad FCS, an RX_ER, or a frame under 64 bytes.

   Latency: 1 byte + 1 register. The frame parser acts on each byte as it
   is released, cut-through. *)

open! Core
open! Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; rx_dv : 'a
    ; rx_er : 'a
    ; rxd : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { rx : 'a Stream.Mac_rx.t [@rtlmangle "_"]
    ; crc_errors : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

let create ?(mii_mode = false) _scope (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let open Always in
  let rx_byte, byte_strobe, byte_error, nibble_logic, odd_nibble =
    if mii_mode
    then (
      (* At 10/100 Mb/s the RTL8211EG uses MII: RXD[3:0] carries the low
         nibble first, then the high nibble, at 2.5/25 MHz. RX_DV remains
         high across both nibbles. Assemble bytes before the GMII MAC below. *)
      let low = Variable.reg spec ~width:4 in
      let low_error = Variable.reg spec ~width:1 in
      let phase = Variable.reg spec ~width:1 in
      ( sel_bottom i.rxd ~width:4 @: low.value
      , i.rx_dv &: phase.value
      , low_error.value |: i.rx_er
      , [ if_
            i.rx_dv
            [ if_
                phase.value
                [ phase <-- gnd ]
                [ low <-- sel_bottom i.rxd ~width:4
                ; low_error <-- i.rx_er
                ; phase <-- vdd
                ]
            ]
            [ phase <-- gnd ]
        ]
      , phase.value ))
    else i.rxd, i.rx_dv, i.rx_er, [], gnd
  in
  let in_frame = Variable.reg spec ~width:1 in
  let held = Variable.reg spec ~width:1 (* [d] holds a byte to release *) in
  let d = Variable.reg spec ~width:8 in
  let crc = Variable.reg spec ~width:32 in
  let len = Variable.reg spec ~width:11 in
  let er = Variable.reg spec ~width:1 in
  let emitted_any = Variable.reg spec ~width:1 in
  let out = Stream.Mac_rx.Of_always.reg spec in
  let crc_errors = Variable.reg spec ~width:32 in
  let crc_next = Crc32.next ~crc:crc.value ~data:rx_byte in
  let bad_now =
    er.value |: odd_nibble |: (crc.value <>:. Crc32.residue) |: (len.value <:. 64)
  in
  compile
    (nibble_logic
    @ [ out.valid <-- gnd
    ; out.first <-- gnd
    ; out.last <-- gnd
    ; out.err <-- gnd
    ; if_
        i.rx_dv
        [ when_
            byte_strobe
            [ if_
            in_frame.value
            [ (* a frame byte (or FCS byte) *)
              crc <-- crc_next
            ; when_ (len.value <>:. 2047) [ len <-- len.value +:. 1 ]
            ; when_ byte_error [ er <-- vdd ]
            ; when_
                held.value
                [ out.valid <-- vdd
                ; out.data <-- d.value
                ; out.first <-- ~:(emitted_any.value)
                ; emitted_any <-- vdd
                ]
            ; held <-- vdd
            ; d <-- rx_byte
            ]
            [ (* preamble: wait for the SFD *)
              when_
                (rx_byte ==:. 0xd5)
                [ in_frame <-- vdd
                ; held <-- gnd
                ; crc <--. Crc32.init
                ; len <--. 0
                ; er <-- byte_error
                ; emitted_any <-- gnd
                ]
            ]
            ]
        ]
        [ (* RX_DV low: end of frame; release its last byte *)
          when_
            in_frame.value
            [ in_frame <-- gnd
            ; when_
                held.value
                [ out.valid <-- vdd
                ; out.data <-- d.value
                ; out.first <-- ~:(emitted_any.value)
                ; out.last <-- vdd
                ; out.err <-- bad_now
                ; when_ bad_now [ crc_errors <-- crc_errors.value +:. 1 ]
                ]
            ]
        ]
    ]);
  { O.rx = Stream.Mac_rx.Of_always.value out; crc_errors = crc_errors.value }
;;

let hierarchical ?(mii_mode = false) scope =
  let module H = Hierarchy.In_scope (I) (O) in
  H.hierarchical ~scope ~name:(if mii_mode then "mii_rx" else "gmii_rx") (create ~mii_mode)
;;
