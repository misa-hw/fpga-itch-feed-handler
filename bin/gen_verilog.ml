(* Write Verilog for synthesis.

     gen_verilog feed_handler OUT.v   the core pipeline (for resource/Fmax reports)
*)
open! Core
open! Hardcaml
open Feed_hw

let write ~name create file =
  let scope = Scope.create ~flatten_design:false () in
  let circuit = create scope in
  let db = Scope.circuit_database scope in
  Out_channel.write_all
    file
    ~data:(Rtl.create ~database:db Verilog [ circuit ] |> Rtl.full_hierarchy |> Rope.to_string);
  printf "wrote %s (%s)\n" file name
;;

let () =
  match Sys.get_argv () |> Array.to_list with
  | [ _; "feed_handler"; file ] ->
    let module C = Circuit.With_interface (Feed_handler.I) (Feed_handler.O) in
    write ~name:"feed_handler" (fun scope -> C.create_exn ~name:"feed_handler" (Feed_handler.create scope)) file
  | [ _; "timing_top"; file ] ->
    let module C = Circuit.With_interface (Timing_top.I) (Timing_top.O) in
    write ~name:"timing_top" (fun scope -> C.create_exn ~name:"timing_top" (Timing_top.create scope)) file
  | [ _; "board_top"; file ] ->
    let module C = Circuit.With_interface (Board_top.I) (Board_top.O) in
    write ~name:"board_top" (fun scope -> C.create_exn ~name:"board_top" (Board_top.create scope)) file
  | [ _; "board_top_mii"; file ] ->
    let module C = Circuit.With_interface (Board_top.I) (Board_top.O) in
    write ~name:"board_top" (fun scope -> C.create_exn ~name:"board_top" (Board_top.create ~mii_mode:true scope)) file
  | [ _; "board_top_mii_sim"; file ] ->
    (* for gate-level simulation (fpga/netlist_sim): same logic, but 4-cycle
       UART bits, a 20k-cycle "second" and a short PHY reset *)
    let module C = Circuit.With_interface (Board_top.I) (Board_top.O) in
    write
      ~name:"board_top"
      (fun scope ->
        C.create_exn
          ~name:"board_top"
          (Board_top.create ~mii_mode:true ~bit_cycles:4 ~second:20_000 ~phy_reset_cycles:8 scope))
      file
  | [ _; ("board_top_selftest" | "board_top_selftest50" | "board_top_selftest_sim" as kind); pcap; file ] ->
    (* frames played from a ROM instead of the PHY; see Board_top.selftest_player *)
    let frames = ref [] in
    ignore (Net.Pcap.iter pcap ~f:(fun ~ts_ns:_ f -> frames := f :: !frames) : int);
    let frames = List.rev !frames in
    let sim = String.equal kind "board_top_selftest_sim" in
    let module C = Circuit.With_interface (Board_top.I) (Board_top.O) in
    write
      ~name:"board_top"
      (fun scope ->
        C.create_exn
          ~name:"board_top"
          (if sim
           then
             Board_top.create
               ~mii_mode:true
               ~bit_cycles:4
               ~second:20_000
               ~phy_reset_cycles:8
               ~selftest:frames
               ~selftest_delay:8000
               scope
           else
             Board_top.create
               ~mii_mode:true
               ~selftest:frames
               ~selftest_on_clk50:(String.equal kind "board_top_selftest50")
               scope))
      file
  | [ _; "bram_probe_x9"; file ] ->
    (* one 4096 x 9 memory: a single RAMB36E1 in 4K x 9 mode *)
    let module C = Circuit.With_interface (Bram_probe.I) (Bram_probe.O) in
    write
      ~name:"bram_probe"
      (fun scope ->
        C.create_exn ~name:"bram_probe" (Bram_probe.create ~shapes:[ "x9", 4096, 9 ] scope))
      file
  | [ _; "bram_probe"; file ] ->
    let module C = Circuit.With_interface (Bram_probe.I) (Bram_probe.O) in
    write ~name:"bram_probe" (fun scope -> C.create_exn ~name:"bram_probe" (Bram_probe.create scope)) file
  | _ ->
    eprintf "usage: gen_verilog (feed_handler|timing_top|board_top|board_top_mii|board_top_mii_sim) OUT.v\n       gen_verilog (board_top_selftest|board_top_selftest_sim) PCAP OUT.v\n"
;;
