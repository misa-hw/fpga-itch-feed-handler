open! Core
open! Hardcaml
open! Hardcaml_waveterm
open Feed_hw
open Itch_model
module Kind = Itch_decoder.Kind

(* decoder -> symbol filter, as in the full pipeline *)
module Chain = struct
  module I = struct
    type 'a t =
      { clock : 'a
      ; clear : 'a
      ; symbols : 'a array [@length Symbol_filter.num_slots] [@bits 64]
      ; symbol_enable : 'a [@bits Symbol_filter.num_slots]
      ; msg : 'a Stream.Message.t [@rtlmangle "_"]
      }
    [@@deriving hardcaml]
  end

  module O = struct
    type 'a t =
      { decoded : 'a Itch_decoder.Decoded.t [@rtlmangle "_"]
      ; bad_length : 'a [@bits 32]
      ; cmd : 'a Symbol_filter.Command.t [@rtlmangle "_"]
      ; mapped : 'a [@bits Symbol_filter.num_slots]
      }
    [@@deriving hardcaml]
  end

  let create scope (i : _ I.t) : _ O.t =
    let dec = Itch_decoder.hierarchical scope { clock = i.clock; clear = i.clear; msg = i.msg } in
    let f =
      Symbol_filter.hierarchical
        scope
        { clock = i.clock
        ; clear = i.clear
        ; symbols = i.symbols
        ; symbol_enable = i.symbol_enable
        ; decoded = dec.decoded
        }
    in
    { O.decoded = dec.decoded; bad_length = dec.bad_length; cmd = f.cmd; mapped = f.mapped }
  ;;
end

module Sim = Cyclesim.With_interface (Chain.I) (Chain.O)

(* built byte by byte: a 64-bit value does not fit an OCaml int *)
let symbol_bits s =
  String.to_list (Itch.pad_stock s)
  |> List.map ~f:(fun c -> Bits.of_int_trunc ~width:8 (Char.to_int c))
  |> Bits.concat_msb
;;

(* ASCII keeps bit 63 clear, so a 64-bit stock field survives [to_int_trunc] *)
let stock_text v = String.init 8 ~f:(fun k -> Char.of_int_exn ((v lsr (8 * (7 - k))) land 0xff)) |> String.rstrip

let make_sim ?(symbols = [ "QQQ"; "SPY" ]) () =
  let sim = Sim.create (Chain.create (Scope.create ~flatten_design:true ())) in
  let i = Cyclesim.inputs sim in
  List.iteri symbols ~f:(fun k s -> i.symbols.(k) := symbol_bits s);
  i.symbol_enable := Bits.of_int_trunc ~width:8 ((1 lsl List.length symbols) - 1);
  i.clear := Bits.vdd;
  Cyclesim.cycle sim;
  i.clear := Bits.gnd;
  sim
;;

type out =
  { decoded : (Kind.t * int list) option (* kind, field values *)
  ; cmd : (Kind.t * int) option (* kind, slot *)
  }

(* Send one message, then return what came out of the decoder and the
   filter (the filter output is one cycle later). *)
let send ?(seq = 0) ?(gap = 0) sim raw =
  let (i : _ Chain.I.t) = Cyclesim.inputs sim and (o : _ Chain.O.t) = Cyclesim.outputs sim in
  let n = String.length raw in
  let decoded = ref None and cmd = ref None in
  let observe () =
    let d = o.Chain.O.decoded in
    let g r = Bits.to_int_trunc !r in
    if Bits.to_bool !(d.valid)
    then
      decoded
      := Some
           ( Kind.of_int (g d.kind)
           , [ g d.locate; g d.order_ref; g d.new_ref; g d.sell; g d.shares; g d.price; g d.stock; g d.seq ] );
    if Bits.to_bool !(o.Chain.O.cmd.valid) then cmd := Some (Kind.of_int (g o.cmd.kind), g o.cmd.slot)
  in
  String.iteri raw ~f:(fun k c ->
    i.msg.valid := Bits.vdd;
    i.msg.data := Bits.of_int_trunc ~width:8 (Char.to_int c);
    i.msg.first := Bits.of_bool (k = 0);
    i.msg.last := Bits.of_bool (k = n - 1);
    i.msg.seq := Bits.of_int_trunc ~width:64 seq;
    Cyclesim.cycle sim;
    observe ();
    i.msg.valid := Bits.gnd;
    for _ = 1 to gap do
      Cyclesim.cycle sim;
      observe ()
    done);
  i.msg.valid := Bits.gnd;
  for _ = 1 to 2 do
    Cyclesim.cycle sim;
    observe ()
  done;
  { decoded = !decoded; cmd = !cmd }
;;

(* What the decoder should output for [m], from the OCaml model. *)
let expected (m : Itch.t) ~seq =
  let stock s = Itch.be s ~pos:0 ~len:8 in
  let f ?(order_ref = 0) ?(new_ref = 0) ?(sell = 0) ?(shares = 0) ?(price = 0) ?(stk = 0) (kind : Kind.t) =
    Some (kind, [ m.header.locate; order_ref; new_ref; sell; shares; price; stk; seq ])
  in
  match m.body with
  | Stock_directory { stock = s; _ } -> f Kind.Directory ~stk:(stock s)
  | Add_order { order_ref; side; shares; stock = s; price; _ } ->
    f Add ~order_ref ~sell:(if Itch.equal_side side Sell then 1 else 0) ~shares ~price ~stk:(stock s)
  | Order_executed { order_ref; shares; _ } -> f Executed ~order_ref ~shares
  | Order_executed_with_price { order_ref; shares; price; _ } ->
    f Executed_with_price ~order_ref ~shares ~price
  | Order_cancel { order_ref; shares } -> f Cancel ~order_ref ~shares
  | Order_delete { order_ref } -> f Delete ~order_ref
  | Order_replace { orig_ref; new_ref; shares; price } -> f Replace ~order_ref:orig_ref ~new_ref ~shares ~price
  | Other _ -> None
;;

(* Fields that a message type does not define hold stale values; compare
   only the defined ones. *)
let defined kind =
  (* locate order_ref new_ref sell shares price stock seq *)
  match (kind : Kind.t) with
  | Directory -> [ true; false; false; false; false; false; true; true ]
  | Add -> [ true; true; false; true; true; true; true; true ]
  | Executed | Cancel -> [ true; true; false; false; true; false; false; true ]
  | Executed_with_price -> [ true; true; false; false; true; true; false; true ]
  | Delete -> [ true; true; false; false; false; false; false; true ]
  | Replace -> [ true; true; true; false; true; true; false; true ]
  | Other -> List.init 8 ~f:(fun _ -> false)
;;

let same a b =
  match a, b with
  | None, None -> true
  | Some (k, xs), Some (k', ys) ->
    Kind.equal k k'
    && List.for_all (List.zip_exn (defined k) (List.zip_exn xs ys)) ~f:(fun (d, (x, y)) -> (not d) || x = y)
  | _ -> false
;;

let show = function
  | None -> "-"
  | Some (k, fields) ->
    sprintf
      "%s %s"
      (Sexp.to_string (Kind.sexp_of_t k))
      (List.filter_mapi fields ~f:(fun j v ->
         if not (List.nth_exn (defined k) j)
         then None
         else if j = 6
         then Some (stock_text v)
         else Some (Int.to_string v))
       |> String.concat ~sep:" ")
;;

let%expect_test "every book message type decodes to the model's fields" =
  let sim = make_sim () in
  List.iter Test_samples.all ~f:(fun m ->
    let got = (send sim (Itch.to_string m) ~seq:77).decoded in
    let want = expected m ~seq:77 in
    printf "%c %-5b %s\n" (Itch.typ m) (same got want) (show got));
  [%expect {|
    R true  Directory 7 QQQ 77
    A true  Add 7 123456789 0 100 1912300 QQQ 77
    F true  Add 7 42 1 5 1912400 QQQ 77
    E true  Executed 7 42 3 77
    C true  Executed_with_price 7 42 1 1912350 77
    X true  Cancel 7 42 1 77
    D true  Delete 7 42 77
    U true  Replace 7 42 43 200 1912200 77
    S true  -
    |}]
;;

let%expect_test "bad lengths and unknown types are dropped" =
  let sim = make_sim () in
  let d = Itch.to_string (List.nth_exn Test_samples.all 6) in
  let show_r r = print_endline (show r.decoded) in
  show_r (send sim (String.prefix d 18));
  show_r (send sim (d ^ "x"));
  show_r (send sim ("Z" ^ String.drop_prefix d 1));
  show_r (send sim d);
  printf "bad_length=%d\n" (Bits.to_int_trunc !((Cyclesim.outputs sim).bad_length));
  [%expect {|
    -
    -
    -
    Delete 7 42 0
    bad_length=2
    |}]
;;

let%expect_test "symbol filter learns locates from the stock directory" =
  let sim = make_sim ~symbols:[ "QQQ"; "SPY" ] () in
  let hdr locate = { Itch.locate; tracking = 0; timestamp = 0 } in
  let dir locate s =
    Itch.to_string { header = hdr locate; body = Stock_directory { stock = Itch.pad_stock s; rest = String.make 20 ' ' } }
  in
  let del locate = Itch.to_string { header = hdr locate; body = Order_delete { order_ref = 1 } } in
  let show_cmd what r =
    printf
      "%-18s -> %s\n"
      what
      (match r.cmd with
       | None -> "dropped"
       | Some (k, slot) -> sprintf "%s slot %d" (Sexp.to_string (Kind.sexp_of_t k)) slot)
  in
  show_cmd "D locate 9" (send sim (del 9)) (* before any directory *);
  show_cmd "R SPY = 9" (send sim (dir 9 "SPY"));
  show_cmd "R AAPL = 4" (send sim (dir 4 "AAPL"));
  show_cmd "R QQQ = 700" (send sim (dir 700 "QQQ"));
  show_cmd "D locate 9" (send sim (del 9));
  show_cmd "D locate 700" (send sim (del 700));
  show_cmd "D locate 4" (send sim (del 4));
  printf "mapped=%s\n" (Bits.to_bstr !((Cyclesim.outputs sim).mapped));
  [%expect {|
    D locate 9         -> dropped
    R SPY = 9          -> dropped
    R AAPL = 4         -> dropped
    R QQQ = 700        -> dropped
    D locate 9         -> Delete slot 1
    D locate 700       -> Delete slot 0
    D locate 4         -> dropped
    mapped=00000011
    |}]
;;

(* 300k real messages, with random idle cycles between bytes. *)
let%expect_test "real sample: decoder output equals the OCaml decoder" =
  (match Lazy.force Sample_data.itch with
   | None -> ()
   | Some file ->
     let sim = make_sim () in
     let rng = Random.State.make [| 7 |] in
     let bad = ref 0 and n_decoded = ref 0 in
     let _ =
       Itch.File.iter_raw ~max_messages:300_000 file ~f:(fun raw ->
         let seq = Random.State.bits rng in
         let got = (send sim raw ~seq ~gap:(if Random.State.int rng 4 = 0 then 1 else 0)).decoded in
         let want = expected (Itch.of_string raw) ~seq in
         if Option.is_some want then incr n_decoded;
         if not (same got want)
         then (
           incr bad;
           if !bad <= 5 then printf "MISMATCH %c: %s vs %s\n" raw.[0] (show got) (show want)))
     in
     if !bad > 0 || !n_decoded < 50_000 then printf "%d mismatches, %d decoded\n" !bad !n_decoded);
  [%expect {| |}]
;;
