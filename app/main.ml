let () = Printexc.record_backtrace true
let anchor = Mtime_clock.now ()

let reporter ppf =
  let report src level ~over k msgf =
    let k _ = over (); k () in
    let with_metadata header _tags k ppf fmt =
      let timestamp = Mtime.span (Mtime_clock.now ()) anchor in
      Format.kfprintf k ppf
        ("[+%a]%a[%a][%a]: " ^^ fmt ^^ "\n%!")
        Fmt.(
          styled `Magenta
            (using (fun ns -> Mtime.Span.to_float_ns ns /. 1e9) (fmt "%06.04f")))
        timestamp Logs_fmt.pp_header (level, header)
        Fmt.(styled `Blue int)
        (Stdlib.Domain.self () :> int)
        Fmt.(styled `Magenta string)
        (Logs.Src.name src)
    in
    msgf @@ fun ?header ?tags fmt -> with_metadata header tags k ppf fmt
  in
  { Logs.report }

let () = Fmt_tty.setup_std_outputs ~style_renderer:`Ansi_tty ~utf_8:true ()
let () = Logs.set_reporter (reporter Fmt.stderr)
let () = Logs.set_level ~all:true (Some Logs.Debug)
let () = Logs_threaded.enable ()
let () = Mirage_crypto_rng_unix.initialize (module Mirage_crypto_rng.Fortuna)

let getaddrinfo dns : Happy_eyeballs_miou_unix.getaddrinfo =
  fun record host ->
    let open Ipaddr in
    match record with
    | `A -> (
      match Dns_client_miou_unix.getaddrinfo dns A host with
      | Error _ as e -> e
      | Ok (_, addr) -> V4.Set.to_seq addr |> Seq.map (fun addr -> V4 addr) |> Set.of_seq |> Result.ok
    )
    | `AAAA -> (
      match Dns_client_miou_unix.getaddrinfo dns Aaaa host with
      | Error _ as e -> e
      | Ok (_, addr) -> V6.Set.to_seq addr |> Seq.map (fun addr -> V6 addr) |> Set.of_seq |> Result.ok
    )

let google = `Plaintext (Ipaddr.of_string_exn "8.8.8.8", 53)

let unicast_censurfridns_dk =
  let unicast_censurfridns_dk = Ipaddr.of_string_exn "89.233.43.71" in
  let time () = Some (Ptime.v (Ptime_clock.now_d_ps ())) in
  let authenticator =
    X509.Authenticator.of_string
      "key-fp:sha256:INSZEZpDoWKiavosV2/xVT8O83vk/RRwS+LTiL+IpHs="
    |> Result.get_ok
  in
  let cfg = Tls.Config.client ~authenticator:(authenticator time) () in
  `Tls (cfg, unicast_censurfridns_dk, 853)

let () =
  Miou_unix.run @@ fun () ->
  let daemon, resolver = Happy_eyeballs_miou_unix.create () in
  let dns =
    Dns_client_miou_unix.create ~nameservers:(`Tcp, [ google ]) resolver
  in
  Happy_eyeballs_miou_unix.inject resolver (getaddrinfo dns);
  let f _resp buf str = Buffer.add_string buf str; buf in
  match
    Httpcats.request ~resolver ~f ~uri:Sys.argv.(1) (Buffer.create 0x100)
  with
  | Ok (_, body) ->
      Happy_eyeballs_miou_unix.kill daemon;
      Format.printf "@[<hov>%a@]\n%!"
        (Hxd_string.pp Hxd.default)
        (Buffer.contents body)
  | Error err ->
      Happy_eyeballs_miou_unix.kill daemon;
      Format.eprintf "%a\n%!" Httpcats.pp_error err;
      exit 1
