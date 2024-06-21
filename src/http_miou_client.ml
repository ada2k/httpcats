let src = Logs.Src.create "http-miou-client"

module Log = (val Logs.src_log src : Logs.LOG)
open Http_miou_unix

module Httpaf_Client_connection = struct
  include Httpaf.Client_connection

  let yield_reader _ = assert false

  let next_read_operation t =
    (next_read_operation t :> [ `Close | `Read | `Yield ])
end

module A = Runtime.Make (Tls_miou_unix) (Httpaf_Client_connection)
module B = Runtime.Make (TCP) (Httpaf_Client_connection)
module C = Runtime.Make (Tls_miou_unix) (H2.Client_connection)
module D = Runtime.Make (TCP) (H2.Client_connection)

type config = [ `V1 of Httpaf.Config.t | `V2 of H2.Config.t ]
type flow = [ `Tls of Tls_miou_unix.t | `Tcp of Miou_unix.file_descr ]
type request = [ `V1 of Httpaf.Request.t | `V2 of H2.Request.t ]
type response = [ `V1 of Httpaf.Response.t | `V2 of H2.Response.t ]

type error =
  [ `V1 of Httpaf.Client_connection.error
  | `V2 of H2.Client_connection.error
  | `Protocol of string ]

let pp_error ppf = function
  | `V1 (`Malformed_response msg) ->
      Fmt.pf ppf "Malformed HTTP/1.1 response: %s" msg
  | `V1 (`Invalid_response_body_length _resp) ->
      Fmt.pf ppf "Invalid response body length"
  | `V1 (`Exn exn) | `V2 (`Exn exn) ->
      Fmt.pf ppf "Got an unexpected exception: %S" (Printexc.to_string exn)
  | `V2 (`Malformed_response msg) -> Fmt.pf ppf "Malformed H2 response: %s" msg
  | `V2 (`Invalid_response_body_length _resp) ->
      Fmt.pf ppf "Invalid response body length"
  | `V2 (`Protocol_error (err, msg)) ->
      Fmt.pf ppf "Protocol error %a: %s" H2.Error_code.pp_hum err msg
  | `Protocol msg -> Fmt.string ppf msg

type ('resp, 'body) version =
  | V1 : (Httpaf.Response.t, Httpaf.Body.Writer.t) version
  | V2 : (H2.Response.t, H2.Body.Writer.t) version

type 'resp await = unit -> ('resp, error) result

type 'acc process =
  | Process :
      ('resp, 'body) version * ('resp * 'acc) await * 'body
      -> 'acc process

let http_1_1_response_handler ~f acc =
  let acc = ref acc in
  let response = ref None in
  let go resp body orphans =
    let rec on_eof () = Httpaf.Body.Reader.close body
    and on_read bstr ~off ~len =
      let str = Bigstringaf.substring bstr ~off ~len in
      acc := f (`V1 resp) !acc str;
      Httpaf.Body.Reader.schedule_read body ~on_read ~on_eof
    in
    response := Some (`V1 resp);
    Httpaf.Body.Reader.schedule_read body ~on_read ~on_eof;
    Runtime.terminate orphans
  in
  let response_handler resp body = Runtime.flat_tasks (go resp body) in
  (response_handler, response, acc)

let http_1_1_error_handler () =
  let error = ref None in
  let error_handler = function
    | `Exn (Runtime.Flow msg) -> error := Some (`Protocol msg)
    | err -> error := Some (`V1 err)
  in
  (error_handler, error)

let h2_response_handler conn ~f acc =
  let acc = ref acc in
  let response = ref None in
  let go resp body orphans =
    let rec on_eof () =
      H2.Body.Reader.close body;
      H2.Client_connection.shutdown conn
    and on_read bstr ~off ~len =
      let str = Bigstringaf.substring bstr ~off ~len in
      acc := f (`V2 resp) !acc str;
      H2.Body.Reader.schedule_read body ~on_read ~on_eof
    in
    response := Some (`V1 resp);
    H2.Body.Reader.schedule_read body ~on_read ~on_eof;
    Log.debug (fun m -> m "reader terminates");
    Runtime.terminate orphans
  in
  let response_handler resp body = Runtime.flat_tasks (go resp body) in
  (response_handler, response, acc)

let h2_error_handler () =
  let error = ref None in
  let error_handler = function
    | `Exn (Runtime.Flow msg) -> error := Some (`Protocol msg)
    | err -> error := Some (`V2 err)
  in
  (error_handler, error)

let pp_request ppf (flow, request) =
  match (flow, request) with
  | `Tls _, `V1 _ -> Fmt.string ppf "http/1.1 + tls"
  | `Tcp _, `V1 _ -> Fmt.string ppf "http/1.1"
  | `Tls _, `V2 _ -> Fmt.string ppf "h2 + tls"
  | `Tcp _, `V2 _ -> Fmt.string ppf "h2"

let run ~f acc config flow request =
  Log.debug (fun m -> m "Start a new %a request" pp_request (flow, request));
  match (flow, config, request) with
  | `Tls flow, `V1 config, `V1 request ->
      let read_buffer_size = config.Httpaf.Config.read_buffer_size in
      let response_handler, response, acc = http_1_1_response_handler ~f acc in
      let error_handler, error = http_1_1_error_handler () in
      let body, conn =
        Httpaf.Client_connection.request ~config request ~error_handler
          ~response_handler
      in
      let prm = A.run conn ~read_buffer_size flow in
      let await () =
        match (Miou.await prm, !error, !response) with
        | _, Some error, _ -> Error error
        | Error exn, _, _ -> Error (`V1 (`Exn exn))
        | Ok (), None, Some (`V1 resp) -> Ok (resp, !acc)
        | Ok (), None, (Some (`V2 _) | None) -> assert false
      in
      Process (V1, await, body)
  | `Tcp flow, `V1 config, `V1 request ->
      let read_buffer_size = config.Httpaf.Config.read_buffer_size in
      let response_handler, response, acc = http_1_1_response_handler ~f acc in
      let error_handler, error = http_1_1_error_handler () in
      let body, conn =
        Httpaf.Client_connection.request ~config request ~error_handler
          ~response_handler
      in
      let prm = B.run conn ~read_buffer_size flow in
      let await () =
        match (Miou.await prm, !error, !response) with
        | _, Some error, _ -> Error error
        | Error exn, _, _ -> Error (`V1 (`Exn exn))
        | Ok (), None, Some (`V1 resp) -> Ok (resp, !acc)
        | Ok (), None, (Some (`V2 _) | None) -> assert false
      in
      Process (V1, await, body)
  | `Tls flow, `V2 config, `V2 request ->
      let read_buffer_size = config.H2.Config.read_buffer_size in
      let error_handler, error = h2_error_handler () in
      let conn = H2.Client_connection.create ~config ~error_handler () in
      let response_handler, response, acc = h2_response_handler conn ~f acc in
      let body =
        H2.Client_connection.request conn ~error_handler ~response_handler
          request
      in
      let prm = C.run conn ~read_buffer_size flow in
      let await () =
        match (Miou.await prm, !error, !response) with
        | _, Some error, _ -> Error error
        | Error exn, _, _ -> Error (`V1 (`Exn exn))
        | Ok (), None, Some (`V1 resp) -> Ok (resp, !acc)
        | Ok (), None, (Some (`V2 _) | None) -> assert false
      in
      Process (V2, await, body)
  | `Tcp flow, `V2 config, `V2 request ->
      let read_buffer_size = config.H2.Config.read_buffer_size in
      let error_handler, error = h2_error_handler () in
      let conn = H2.Client_connection.create ~config ~error_handler () in
      let response_handler, response, acc = h2_response_handler conn ~f acc in
      let body =
        H2.Client_connection.request conn ~error_handler ~response_handler
          request
      in
      let prm = D.run conn ~read_buffer_size flow in
      let await () =
        match (Miou.await prm, !error, !response) with
        | _, Some error, _ -> Error error
        | Error exn, _, _ -> Error (`V1 (`Exn exn))
        | Ok (), None, Some (`V1 resp) -> Ok (resp, !acc)
        | Ok (), None, (Some (`V2 _) | None) -> assert false
      in
      Process (V2, await, body)
  | _ -> invalid_arg "Http_miou_client.run"
