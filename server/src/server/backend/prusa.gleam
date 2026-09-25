import gleam/bit_array
import gleam/crypto
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response as ResponseC}
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import server/backend/common
import server/printer.{
  type BackendConfig, type CommandError, type Fault, type PrintState,
  type StatusPatch, Cancelled, Complete, Connected, Connection, Critical,
  Errored, Fault, Faults, Idle, NeedsAttention, Paused, Print, Printing,
  Progress, ProgressInfo, PrusaLink, RejectedByPrinter, Temperature,
  Temperatures, TransportError, Warning,
}

pub type Client {
  Client(
    host: String,
    username: String,
    password: String,
    job_id: Option(Int),
    realm: String,
    nonce: Option(String),
    opaque_value: String,
    algorithm: String,
    qop: Option(String),
  )
}

pub fn new(config: BackendConfig) -> Result(Client, String) {
  case config {
    PrusaLink(host:, username:, password:) ->
      Ok(Client(
        host:,
        username:,
        password:,
        job_id: None,
        realm: "PrusaLink",
        nonce: None,
        opaque_value: "",
        algorithm: "MD5",
        qop: None,
      ))
    _ -> Error("not a PrusaLink backend")
  }
}

pub fn poll_interval_ms(printing: Bool) -> Int {
  case printing {
    True -> 2000
    False -> 8000
  }
}

pub fn fetch_status(
  client: Client,
) -> Result(#(Client, List(StatusPatch)), CommandError) {
  use #(client, resp) <- result.try(request_string(
    client,
    http.Get,
    "/api/v1/status",
    None,
  ))
  use body <- result.try(expect_status(resp, 200))
  use updates <- result.try(parse_status(body))
  let client = absorb_job(client, body)
  Ok(#(client, updates))
}

pub fn pause(client: Client) -> Result(#(Client, Nil), CommandError) {
  job_action(client, "pause")
}

pub fn resume(client: Client) -> Result(#(Client, Nil), CommandError) {
  job_action(client, "resume")
}

pub fn cancel(client: Client) -> Result(#(Client, Nil), CommandError) {
  use job_id <- result.try(require_job(client))
  use #(client, resp) <- result.try(request_string(
    client,
    http.Delete,
    "/api/v1/job/" <> int.to_string(job_id),
    None,
  ))
  use _ <- result.try(common.expect_accepted(resp))
  Ok(#(client, Nil))
}

pub fn upload_and_start(
  client: Client,
  file_id: Int,
  bytes: BitArray,
) -> Result(#(Client, Nil), CommandError) {
  let path = "/api/v1/files/local/" <> common.gcode_filename(file_id)
  use #(client, resp) <- result.try(request_bits(
    client,
    http.Put,
    path,
    [
      #("content-type", "application/octet-stream"),
      #("print-after-upload", "?1"),
      #("overwrite", "?1"),
    ],
    bytes,
  ))
  use _ <- result.try(common.expect_accepted(resp))
  Ok(#(client, Nil))
}

fn job_action(
  client: Client,
  action: String,
) -> Result(#(Client, Nil), CommandError) {
  use job_id <- result.try(require_job(client))
  use #(client, resp) <- result.try(request_string(
    client,
    http.Put,
    "/api/v1/job/" <> int.to_string(job_id) <> "/" <> action,
    None,
  ))
  use _ <- result.try(common.expect_accepted(resp))
  Ok(#(client, Nil))
}

fn require_job(client: Client) -> Result(Int, CommandError) {
  case client.job_id {
    Some(id) -> Ok(id)
    None -> Error(RejectedByPrinter("no active job"))
  }
}

fn absorb_job(client: Client, body: String) -> Client {
  case json.parse(body, job_id_decoder()) {
    Ok(job_id) -> Client(..client, job_id:)
    Error(_) -> client
  }
}

/// `job` is null/absent (or has no id) when nothing is running; only then is
/// there truly no job. Never defaults to 0 — `/api/v1/job/0` is not a thing.
fn job_id_decoder() -> decode.Decoder(Option(Int)) {
  use job <- decode.optional_field("job", dynamic.nil(), decode.dynamic)
  case
    decode.run(job, {
      use id <- decode.field("id", decode.int)
      decode.success(id)
    })
  {
    Ok(id) -> decode.success(Some(id))
    Error(_) -> decode.success(None)
  }
}

fn parse_status(body: String) -> Result(List(StatusPatch), CommandError) {
  json.parse(body, updates_decoder())
  |> result.map_error(fn(e) {
    TransportError("status decode failed: " <> string.inspect(e))
  })
}

fn updates_decoder() -> decode.Decoder(List(StatusPatch)) {
  use printer <- decode.optional_field("printer", dynamic.nil(), decode.dynamic)
  use job <- decode.optional_field("job", dynamic.nil(), decode.dynamic)
  decode.success([
    Connection(Connected),
    ..list.append(printer_job_updates(printer, job), status_faults(printer))
  ])
}

/// Prusa's per-poll status is authoritative: every successful poll emits a
/// full fault list (possibly empty), so cleared faults clear here too.
fn status_faults(printer: Dynamic) -> List(StatusPatch) {
  let faults =
    list.flatten([
      status_block_fault(printer, "status_printer", "printer"),
      status_block_fault(printer, "status_connect", "connect"),
    ])
  [Faults(Some(faults))]
}

fn status_block_fault(
  printer: Dynamic,
  key: String,
  code: String,
) -> List(Fault) {
  case field(printer, key, decode.dynamic) {
    Error(_) -> []
    Ok(block) -> {
      let ok = field(block, "ok", decode.bool) |> result.unwrap(True)
      let message = field(block, "message", decode.string) |> result.unwrap("")
      case ok, message {
        True, "OK" -> []
        True, "" -> []
        False, "" -> [
          Fault(code:, message: "reported not ok", severity: Critical),
        ]
        False, m -> [
          Fault(code:, message: m, severity: Critical),
        ]
        True, m -> [Fault(code:, message: m, severity: Warning)]
      }
    }
  }
}

fn printer_job_updates(printer: Dynamic, job: Dynamic) -> List(StatusPatch) {
  let state =
    field(printer, "state", decode.string)
    |> result.map(to_print_state)
    |> result.map(Print)

  let progress =
    field(job, "progress", number())
    |> result.try(fn(p) {
      let rem = field(job, "time_remaining", decode.int)
      Ok(Progress(Some(ProgressInfo(p, option.from_result(rem)))))
    })

  let nozzle =
    field(printer, "temp_nozzle", number())
    |> result.try(fn(n) {
      let t = field(printer, "target_nozzle", number()) |> result.unwrap(0.0)
      Ok([Temperature("nozzle", n, t)])
    })

  let bed =
    field(printer, "temp_bed", number())
    |> result.try(fn(b) {
      let t = field(printer, "target_bed", number()) |> result.unwrap(0.0)
      Ok([Temperature("bed", b, t)])
    })

  let temps = list.append(result.unwrap(nozzle, []), result.unwrap(bed, []))

  let optional_updates: List(Option(StatusPatch)) = [
    Some(result.unwrap(state, Print(Idle))),
    Some(result.unwrap(progress, Progress(None))),
    case temps {
      [] -> None
      _ -> Some(Temperatures(temps))
    },
  ]
  list.filter_map(optional_updates, fn(u) { option.to_result(u, Nil) })
}

/// PrusaLink marks numeric fields as plain `number`; JSON may encode them as
/// integers or floats.
fn number() -> decode.Decoder(Float) {
  decode.one_of(decode.float, or: [
    decode.map(decode.int, int.to_float),
  ])
}

fn field(
  data: Dynamic,
  name: String,
  dec: decode.Decoder(a),
) -> Result(a, Nil) {
  decode.run(data, {
    use v <- decode.field(name, dec)
    decode.success(v)
  })
  |> result.replace_error(Nil)
}

fn to_print_state(s: String) -> PrintState {
  case s {
    "IDLE" | "READY" -> Idle
    "PRINTING" | "BUSY" -> Printing
    "PAUSED" -> Paused
    "ATTENTION" -> NeedsAttention
    "FINISHED" -> Complete
    "STOPPED" -> Cancelled
    "ERROR" -> Errored
    _ -> Idle
  }
}

fn request_string(
  client: Client,
  method: http.Method,
  path: String,
  body: Option(String),
) -> Result(#(Client, Response(String)), CommandError) {
  use req <- result.try(build_request(client, method, path, []))
  let req = case body {
    Some(b) -> request.set_body(req, b)
    None -> req
  }
  dispatch_string(req, client)
}

fn request_bits(
  client: Client,
  method: http.Method,
  path: String,
  headers: List(#(String, String)),
  body: BitArray,
) -> Result(#(Client, Response(String)), CommandError) {
  use req <- result.try(build_request(client, method, path, headers))
  let req = request.map(req, fn(_) { body })
  dispatch_bits(req, client)
}

fn build_request(
  client: Client,
  method: http.Method,
  path: String,
  headers: List(#(String, String)),
) -> Result(Request(String), CommandError) {
  use base <- result.try(
    request.to("http://" <> client.host <> path)
    |> result.map_error(fn(_) { TransportError("bad host") }),
  )
  let req =
    base
    |> request.set_method(method)
    |> with_headers(headers)
    |> with_auth(client, method, path)
  Ok(req)
}

fn with_headers(
  req: Request(String),
  headers: List(#(String, String)),
) -> Request(String) {
  case headers {
    [] -> req
    [#(k, v), ..rest] -> with_headers(request.set_header(req, k, v), rest)
  }
}

fn with_auth(
  req: Request(String),
  client: Client,
  method: http.Method,
  path: String,
) -> Request(String) {
  case client.nonce {
    None -> req
    Some(nonce) ->
      request.set_header(
        req,
        "authorization",
        digest_header(client, method, path, nonce),
      )
  }
}

/// Dispatch and, on a digest challenge, retry with the learned nonce. The
/// (possibly updated) client is always returned on success so callers persist
/// the nonce — without this every request would pay a 401 round-trip.
fn dispatch_string(
  req: Request(String),
  client: Client,
) -> Result(#(Client, Response(String)), CommandError) {
  let config = httpc.configure() |> httpc.timeout(15_000)
  use resp <- result.try(
    httpc.dispatch(config, req) |> result.map_error(httpc_error),
  )
  case resp.status == 401 {
    False -> Ok(#(client, resp))
    True ->
      case parse_challenge(resp) {
        Error(_) -> Error(RejectedByPrinter("digest challenge parse failed"))
        Ok(challenge) -> {
          let client = absorb_challenge(client, challenge)
          use req2 <- result.try(build_request(
            client,
            req.method,
            req.path,
            req.headers,
          ))
          let req2 = request.set_body(req2, req.body)
          use resp2 <- result.try(
            httpc.dispatch(config, req2) |> result.map_error(httpc_error),
          )
          Ok(#(client, resp2))
        }
      }
  }
}

fn dispatch_bits(
  req: Request(BitArray),
  client: Client,
) -> Result(#(Client, Response(String)), CommandError) {
  let config = httpc.configure() |> httpc.timeout(30_000)
  use resp <- result.try(
    httpc.dispatch_bits(config, req) |> result.map_error(httpc_error),
  )
  case resp.status == 401 {
    False -> Ok(#(client, response_map_string(resp)))
    True ->
      case parse_challenge(response_map_string(resp)) {
        Error(_) -> Error(RejectedByPrinter("digest challenge parse failed"))
        Ok(challenge) -> {
          let client = absorb_challenge(client, challenge)
          use req2 <- result.try(build_request_bits(
            client,
            req.method,
            req.path,
            req.headers,
            req.body,
          ))
          use resp2 <- result.try(
            httpc.dispatch_bits(config, req2) |> result.map_error(httpc_error),
          )
          Ok(#(client, response_map_string(resp2)))
        }
      }
  }
}

fn absorb_challenge(client: Client, challenge: Challenge) -> Client {
  Client(
    ..client,
    realm: challenge.realm,
    nonce: Some(challenge.nonce),
    opaque_value: challenge.opaque_value,
    algorithm: challenge.algorithm,
    qop: challenge.qop,
  )
}

fn build_request_bits(
  client: Client,
  method: http.Method,
  path: String,
  headers: List(#(String, String)),
  body: BitArray,
) -> Result(Request(BitArray), CommandError) {
  use req <- result.try(build_request(client, method, path, headers))
  Ok(request.map(req, fn(_) { body }))
}

fn response_map_string(resp: Response(BitArray)) -> Response(String) {
  ResponseC(..resp, body: bit_array.to_string(resp.body) |> result.unwrap(""))
}

type Challenge {
  Challenge(
    realm: String,
    nonce: String,
    opaque_value: String,
    algorithm: String,
    qop: Option(String),
  )
}

fn parse_challenge(resp: Response(String)) -> Result(Challenge, Nil) {
  use header <- result.try(find_header(resp.headers, "www-authenticate"))
  let header = string.trim(header)
  case string.starts_with(string.lowercase(header), "digest ") {
    True -> parse_params(string.drop_start(header, 7))
    False -> Error(Nil)
  }
}

fn find_header(
  headers: List(#(String, String)),
  name: String,
) -> Result(String, Nil) {
  case headers {
    [] -> Error(Nil)
    [#(k, v), ..rest] -> {
      case string.lowercase(k) == name {
        True -> Ok(v)
        False -> find_header(rest, name)
      }
    }
  }
}

fn parse_params(raw: String) -> Result(Challenge, Nil) {
  let parts = string.split(raw, ",")
  let pairs =
    list.flat_map(parts, fn(part) {
      case string.split_once(string.trim(part), "=") {
        Ok(#(k, v)) -> [
          #(string.lowercase(string.trim(k)), unquote(string.trim(v))),
        ]
        Error(_) -> []
      }
    })
  use realm <- result.try(list.key_find(pairs, "realm"))
  use nonce <- result.try(list.key_find(pairs, "nonce"))
  Ok(Challenge(
    realm:,
    nonce:,
    opaque_value: result.unwrap(list.key_find(pairs, "opaque"), ""),
    algorithm: result.unwrap(list.key_find(pairs, "algorithm"), "MD5"),
    qop: option.from_result(result.map(list.key_find(pairs, "qop"), qop_primary)),
  ))
}

fn qop_primary(qop: String) -> String {
  case string.split(qop, ",") {
    [first, ..] -> string.trim(first)
    [] -> "auth"
  }
}

fn unquote(s: String) -> String {
  case string.starts_with(s, "\"") && string.ends_with(s, "\"") {
    True -> string.drop_end(string.drop_start(s, 1), 1)
    False -> s
  }
}

fn digest_header(
  client: Client,
  method: http.Method,
  path: String,
  nonce: String,
) -> String {
  let method_s = http.method_to_string(method)
  let ha1 =
    md5_hex(client.username <> ":" <> client.realm <> ":" <> client.password)
  let ha2 = md5_hex(method_s <> ":" <> path)
  let cnonce = md5_hex(client.username <> ":" <> nonce)
  let nc = "00000001"
  let response = case client.qop {
    Some(_) ->
      md5_hex(
        ha1 <> ":" <> nonce <> ":" <> nc <> ":" <> cnonce <> ":auth:" <> ha2,
      )
    None -> md5_hex(ha1 <> ":" <> nonce <> ":" <> ha2)
  }
  let qop_part = case client.qop {
    Some(q) -> ", qop=" <> q <> ", nc=" <> nc <> ", cnonce=\"" <> cnonce <> "\""
    None -> ""
  }
  let opaque_part = case client.opaque_value {
    "" -> ""
    o -> ", opaque=\"" <> o <> "\""
  }
  "Digest username=\""
  <> client.username
  <> "\", realm=\""
  <> client.realm
  <> "\", nonce=\""
  <> nonce
  <> "\", uri=\""
  <> path
  <> "\", response=\""
  <> response
  <> "\""
  <> qop_part
  <> opaque_part
  <> ", algorithm="
  <> client.algorithm
}

fn md5_hex(s: String) -> String {
  crypto.hash(crypto.Md5, bit_array.from_string(s))
  |> bit_array.base16_encode
  |> string.lowercase
}

fn expect_status(
  resp: Response(String),
  code: Int,
) -> Result(String, CommandError) {
  case resp.status == code {
    True -> Ok(resp.body)
    False ->
      Error(TransportError(
        "expected "
        <> int.to_string(code)
        <> ", got "
        <> int.to_string(resp.status),
      ))
  }
}

fn httpc_error(e: httpc.HttpError) -> CommandError {
  case e {
    httpc.ResponseTimeout -> TransportError("timeout")
    _ -> TransportError(string.inspect(e))
  }
}
