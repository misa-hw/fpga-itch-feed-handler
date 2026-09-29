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
  | _ -> eprintf "usage: gen_verilog (feed_handler|timing_top|board_top|board_top_mii) OUT.v\n"
;;
