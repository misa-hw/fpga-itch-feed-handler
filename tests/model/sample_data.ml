(* Locate the ITCH sample (data/*.raw, see scripts/fetch_itch.sh) from the test
   sandbox by walking up the directory tree. Tests that need it are skipped,
   printing the same output, when it is absent, so that the suite still
   passes on a fresh clone. *)
open! Core

let file =
  lazy
    (match Sys.getenv "ITCH_FILE" with
     | Some f -> Some f
     | None ->
       let rec up dir n =
         if n = 0
         then None
         else (
           let f = Filename.concat dir "data/07302019.prefix.raw" in
           if Sys_unix.file_exists_exn f then Some f else up (Filename.dirname dir) (n - 1))
       in
       up (Sys_unix.getcwd ()) 8)
;;
