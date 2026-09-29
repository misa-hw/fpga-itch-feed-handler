(* Where the feed arrives. Must agree with [Net.Packet.default_endpoints],
   which generates the test pcaps (checked by a test). *)

type t =
  { mac : int
  ; ip : int
  ; port : int
  }

(* 233.54.12.111:26477, multicast MAC 01:00:5e:36:0c:6f *)
let endpoints = { mac = 0x01005e360c6f; ip = (233 lsl 24) lor (54 lsl 16) lor (12 lsl 8) lor 111; port = 26477 }
