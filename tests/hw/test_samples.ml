(* One message of each type (same as tests/model/test_itch.ml). *)
open! Core
open Itch_model

let hdr = { Itch.locate = 7; tracking = 2; timestamp = 34_200_000_000_123 }
let stock = Itch.pad_stock "QQQ"

let all : Itch.t list =
  [ { header = hdr
    ; body =
        Stock_directory { stock; rest = "QNZ 100N  0000000000" |> String.sub ~pos:0 ~len:20 }
    }
  ; { header = hdr
    ; body =
        Add_order
          { order_ref = 123456789; side = Buy; shares = 100; stock; price = 1_912_300; mpid = None }
    }
  ; { header = hdr
    ; body =
        Add_order
          { order_ref = 42; side = Sell; shares = 5; stock; price = 1_912_400; mpid = Some "GSCO" }
    }
  ; { header = hdr; body = Order_executed { order_ref = 42; shares = 3; match_number = 99 } }
  ; { header = hdr
    ; body =
        Order_executed_with_price
          { order_ref = 42; shares = 1; match_number = 100; printable = true; price = 1_912_350 }
    }
  ; { header = hdr; body = Order_cancel { order_ref = 42; shares = 1 } }
  ; { header = hdr; body = Order_delete { order_ref = 42 } }
  ; { header = hdr
    ; body = Order_replace { orig_ref = 42; new_ref = 43; shares = 200; price = 1_912_200 }
    }
  ; { header = hdr; body = Other { typ = 'S'; payload = "O" } }
  ]
;;
