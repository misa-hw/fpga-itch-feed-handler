(* Locate generated inputs (the ITCH sample in data/, pcaps in build/) from
   the test sandbox by walking up the directory tree. Tests that need them
   print nothing and pass when they are absent, so the suite still passes on
   a fresh clone; `make data pcaps` creates them. *)
open! Core

let find name =
  let rec up dir n =
    if n = 0
    then None
    else (
      let f = Filename.concat dir name in
      if Sys_unix.file_exists_exn f then Some f else up (Filename.dirname dir) (n - 1))
  in
  up (Sys_unix.getcwd ()) 8
;;

let itch = lazy (find "data/07302019.prefix.raw")
let tracked_pcap = lazy (find "build/tracked.pcap")
