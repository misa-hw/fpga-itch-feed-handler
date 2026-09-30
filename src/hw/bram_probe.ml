(* On-board block RAM check (bring-up tool, not part of the feed handler).

   Memories of exactly the order-table and level-table bank shapes are
   written with an address-dependent pattern, then read back the way the
   order book reads them (read enable for one cycle, data compared from a
   register two cycles later, while the read address returns to 0). Error
   counts and the first failing address are printed over the UART once a
   second:

     B<n> n=<words checked> err=<count> addr=<first bad> got=<low 32 bits> want=<low 32 bits>

   Used to separate "the design is wrong" from "this toolchain configures
   these RAMs wrongly" on real silicon. *)

open! Core
open! Hardcaml
open Signal

module I = struct
  type 'a t =
    { clk50 : 'a
    ; reset_n : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t = { uart_tx : 'a } [@@deriving hardcaml]
end

(* pattern(addr): chunks of (addr XOR constant_i), so every bit depends on
   the address and no two chunks are equal *)
let pattern ~width addr =
  let aw = Signal.width addr in
  let chunks = (width + aw - 1) / aw in
  List.init chunks ~f:(fun i -> addr ^: of_unsigned_int ~width:aw ((i * 0x9e5) land ((1 lsl aw) - 1)))
  |> concat_lsb
  |> sel_bottom ~width
;;

type result =
  { checked : Signal.t
  ; errors : Signal.t
  ; first_addr : Signal.t
  ; got : Signal.t
  ; want : Signal.t
  }

let probe ~spec ~clock ~depth ~width =
  let open Always in
  let ab = Int.ceil_log2 depth in
  (* phase: 0 write, 1 read issue, 2 wait, 3 compare, 4 done *)
  let phase = Variable.reg spec ~width:3 in
  let addr = Variable.reg spec ~width:ab in
  let we = Variable.wire ~default:gnd () in
  let re = Variable.wire ~default:gnd () in
  let raddr = Variable.wire ~default:(zero ab) () in
  let q =
    ram_rbw
      ~write_port:
        { write_clock = clock
        ; write_address = addr.value
        ; write_enable = we.value
        ; write_data = pattern ~width addr.value
        }
      ~read_port:{ read_clock = clock; read_address = raddr.value; read_enable = re.value }
      depth
  in
  let q_r = reg spec q in
  let errors = Variable.reg spec ~width:32 in
  let checked = Variable.reg spec ~width:32 in
  let first_addr = Variable.reg spec ~width:16 in
  let got = Variable.reg spec ~width:32 in
  let want = Variable.reg spec ~width:32 in
  let expected = pattern ~width addr.value in
  let last = addr.value ==:. depth - 1 in
  compile
    [ switch
        phase.value
        [ ( of_unsigned_int ~width:3 0
          , [ we <-- vdd
            ; addr <-- addr.value +:. 1
            ; when_ last [ phase <--. 1; addr <--. 0 ]
            ] )
        ; of_unsigned_int ~width:3 1, [ re <-- vdd; raddr <-- addr.value; phase <--. 2 ]
        ; of_unsigned_int ~width:3 2, [ phase <--. 3 ]
        ; ( of_unsigned_int ~width:3 3
          , [ checked <-- checked.value +:. 1
            ; when_
                (q_r <>: expected)
                [ errors <-- errors.value +:. 1
                ; when_
                    (errors.value ==:. 0)
                    [ first_addr <-- uresize addr.value ~width:16
                    ; got <-- sel_bottom q_r ~width:32
                    ; want <-- sel_bottom expected ~width:32
                    ]
                ]
            ; addr <-- addr.value +:. 1
            ; if_ last [ phase <--. 4 ] [ phase <--. 1 ]
            ] )
        ; of_unsigned_int ~width:3 4, []
        ]
    ];
  { checked = checked.value; errors = errors.value; first_addr = first_addr.value; got = got.value; want = want.value }
;;

let shapes = [ "order_bank", 4096, 284; "level_bank", 2048, 276 ]

let create ?(bit_cycles = 434) ?(second = 50_000_000) _scope (i : _ I.t) : _ O.t =
  let clock = i.clk50 in
  let clear = Board_top.domain_clear ~clock ~reset_n:i.reset_n in
  let spec = Reg_spec.create ~clock ~clear () in
  let results = List.map shapes ~f:(fun (_, depth, width) -> probe ~spec ~clock ~depth ~width) in
  let line =
    List.concat_mapi results ~f:(fun k r ->
      Line_printer.
        [ Lit (sprintf "B%d n=" k)
        ; Hex r.checked
        ; Lit " err="
        ; Hex r.errors
        ; Lit " addr="
        ; Hex r.first_addr
        ; Lit " got="
        ; Hex r.got
        ; Lit " want="
        ; Hex r.want
        ; Lit (if k = List.length results - 1 then "\r\n" else "  ")
        ])
  in
  let tick = reg_fb spec ~width:(num_bits_to_represent second) ~f:(fun t -> mux2 (t ==:. second - 1) (zero (Signal.width t)) (t +:. 1)) in
  let uart_ready = wire 1 in
  let _busy, send, char =
    Line_printer.create ~clock ~clear ~lines:[| line |] ~which:gnd ~start:(tick ==:. second - 1) ~uart_ready
  in
  let ready, tx = Uart_tx.create ~clock ~clear ~bit_cycles ~valid:send ~data:char in
  assign uart_ready ready;
  { O.uart_tx = tx }
;;
