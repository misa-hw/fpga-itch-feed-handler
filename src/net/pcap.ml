(* Classic libpcap files, Ethernet link type, nanosecond timestamps
   (magic 0xa1b23c4d). The reader also accepts microsecond files, in either
   byte order, so captures from tcpdump can be replayed through the tests. *)

open! Core

let magic_ns = 0xa1b23c4d
let magic_us = 0xa1b2c3d4
let linktype_ethernet = 1

let put_le b ~pos ~len v =
  for i = 0 to len - 1 do
    Bytes.set b (pos + i) (Char.of_int_exn ((v lsr (8 * i)) land 0xff))
  done
;;

module Writer = struct
  type t = Out_channel.t

  let create file =
    let oc = Out_channel.create ~binary:true file in
    let h = Bytes.create 24 in
    put_le h ~pos:0 ~len:4 magic_ns;
    put_le h ~pos:4 ~len:2 2;
    put_le h ~pos:6 ~len:2 4;
    put_le h ~pos:8 ~len:4 0 (* thiszone *);
    put_le h ~pos:12 ~len:4 0 (* sigfigs *);
    put_le h ~pos:16 ~len:4 65535 (* snaplen *);
    put_le h ~pos:20 ~len:4 linktype_ethernet;
    Out_channel.output_bytes oc h;
    oc
  ;;

  let write t ~ts_ns frame =
    let h = Bytes.create 16 in
    put_le h ~pos:0 ~len:4 (ts_ns / 1_000_000_000);
    put_le h ~pos:4 ~len:4 (ts_ns mod 1_000_000_000);
    put_le h ~pos:8 ~len:4 (String.length frame);
    put_le h ~pos:12 ~len:4 (String.length frame);
    Out_channel.output_bytes t h;
    Out_channel.output_string t frame
  ;;

  let close = Out_channel.close
end

(* Calls [f ~ts_ns frame] for every packet; returns the packet count. *)
let iter ?(max_packets = Int.max_value) file ~f =
  In_channel.with_file ~binary:true file ~f:(fun ic ->
    let gh = Bytes.create 24 in
    (match In_channel.really_input ic ~buf:gh ~pos:0 ~len:24 with
     | Some () -> ()
     | None -> failwith "pcap: truncated global header");
    let raw = Bytes.to_string gh in
    let le pos len =
      let v = ref 0 in
      for i = len - 1 downto 0 do
        v := (!v lsl 8) lor Char.to_int raw.[pos + i]
      done;
      !v
    in
    let magic = le 0 4 in
    let swapped_ns = 0x4d3cb2a1 and swapped_us = 0xd4c3b2a1 in
    let big_endian = magic = swapped_ns || magic = swapped_us in
    let ns_res = magic = magic_ns || magic = swapped_ns in
    if not (List.mem [ magic_ns; magic_us; swapped_ns; swapped_us ] magic ~equal:Int.equal)
    then failwithf "pcap: bad magic 0x%x" magic ();
    let rd (b : Bytes.t) pos =
      let v = ref 0 in
      for i = 0 to 3 do
        let byte = Char.to_int (Bytes.get b (pos + if big_endian then i else 3 - i)) in
        v := (!v lsl 8) lor byte
      done;
      !v
    in
    let ph = Bytes.create 16 in
    let n = ref 0 in
    let rec loop () =
      if !n < max_packets
      then (
        match In_channel.really_input ic ~buf:ph ~pos:0 ~len:16 with
        | None -> ()
        | Some () ->
          let sec = rd ph 0 and frac = rd ph 4 and caplen = rd ph 8 in
          let buf = Bytes.create caplen in
          (match In_channel.really_input ic ~buf ~pos:0 ~len:caplen with
           | None -> failwith "pcap: truncated packet"
           | Some () -> ());
          let ts_ns = (sec * 1_000_000_000) + if ns_res then frac else frac * 1000 in
          f ~ts_ns (Bytes.to_string buf);
          incr n;
          loop ())
    in
    loop ();
    !n)
;;
