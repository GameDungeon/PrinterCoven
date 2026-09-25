import gleam/bit_array
import gleam/crypto
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/http
import gleam/http/request.{type Request}
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import server/backend/common
import server/printer.{
  type BackendConfig, type CommandError, type PrinterMessage, type StatusPatch,
  Cancelled, Complete, Connected, Connecting, Connection, Critical, Disconnected,
  Errored, Fault, Faults, Idle, Moonraker, Paused, Print, Printing, Progress,
  ProgressInfo, Temperature, Temperatures, TransportError, Warning,
}
import stratus

pub type Config {
  Config(host: String, port: Int, api_key: Option(String))
}

pub fn new(config: BackendConfig) -> Result(Config, String) {
  case config {
    Moonraker(host:, port:, api_key:) -> Ok(Config(host:, port:, api_key:))
    _ -> Error("not a Moonraker backend")
  }
}

pub type Event {
  TextFrame(String)
  Closed(String)
}

pub type WsMsg {
  SendJson(String)
}

pub type Client {
  Client(
    subject: Subject(stratus.InternalMessage(WsMsg)),
    pid: process.Pid,
    monitor: process.Monitor,
  )
}

/// Correlation for an in-flight JSON-RPC request on the WebSocket.
pub type Pending {
  ServerInfo
  Subscribe
  CommandPending(PrinterMessage)
}

pub fn start_client(
  config: Config,
  deliver: fn(Event) -> Nil,
) -> Result(Client, String) {
  use req <- result.try(ws_request(config))
  let builder =
    stratus.new(req, Nil)
    |> stratus.on_message(fn(_, msg, conn) {
      case msg {
        stratus.Text(text) -> {
          deliver(TextFrame(text))
          stratus.continue(Nil)
        }
        stratus.Binary(_) -> stratus.continue(Nil)
        stratus.User(SendJson(text)) -> {
          let _ = stratus.send_text_message(conn, text)
          stratus.continue(Nil)
        }
      }
    })
    |> stratus.on_close(fn(_, reason) {
      deliver(Closed(close_reason_string(reason)))
    })
  case stratus.start(builder) {
    Error(e) -> Error(string.inspect(e))
    Ok(started) -> {
      let monitor = process.monitor(started.pid)
      Ok(Client(subject: started.data, pid: started.pid, monitor:))
    }
  }
}

pub fn send_json(client: Client, text: String) -> Nil {
  process.send(client.subject, stratus.to_user_message(SendJson(text)))
}

fn ws_request(config: Config) -> Result(Request(String), String) {
  request.to(ws_url(config))
  |> result.map_error(fn(_) { "bad websocket url" })
}

fn ws_url(config: Config) -> String {
  "http://" <> config.host <> ":" <> int.to_string(config.port) <> "/websocket"
}

fn close_reason_string(reason: stratus.CloseReason) -> String {
  case reason {
    stratus.NotProvided -> "closed"
    stratus.Normal(_) -> "normal close"
    stratus.GoingAway(_) -> "server going away"
    stratus.ProtocolError(_) -> "protocol error"
    stratus.UnexpectedDataType(_) -> "unexpected data type"
    stratus.InconsistentDataType(_) -> "inconsistent data type"
    stratus.PolicyViolation(_) -> "policy violation"
    stratus.MessageTooBig(_) -> "message too big"
    stratus.MissingExtensions(_) -> "missing extensions"
    stratus.UnexpectedCondition(_) -> "unexpected condition"
    stratus.Custom(_) -> "custom close"
  }
}

pub fn rpc_request(
  id: Int,
  method: String,
  params: Option(json.Json),
) -> String {
  let base = [
    #("jsonrpc", json.string("2.0")),
    #("method", json.string(method)),
    #("id", json.int(id)),
  ]
  let entries = case params {
    Some(p) -> list.append(base, [#("params", p)])
    None -> base
  }
  json.to_string(json.object(entries))
}

pub fn subscribe_params() -> json.Json {
  json.object([
    #(
      "objects",
      json.object([
        #("webhooks", json.null()),
        #("print_stats", json.null()),
        #("virtual_sdcard", json.null()),
        #("extruder", json.null()),
        #("heater_bed", json.null()),
        #("pause_resume", json.null()),
        #("display_status", json.null()),
      ]),
    ),
  ])
}

pub fn start_print_params(filename: String) -> json.Json {
  json.object([#("filename", json.string(filename))])
}

pub type Inbound {
  Response(id: Int, outcome: Result(Dynamic, #(Int, String)))
  StatusDelta(Dynamic)
  KlippyDisconnected
  KlippyReady
  KlippyShutdown
  OtherNotification(String)
  Invalid
}

pub fn parse_inbound(text: String) -> Inbound {
  case json.parse(text, decode.dynamic) {
    Error(_) -> Invalid
    Ok(obj) -> classify(obj)
  }
}

fn classify(obj: Dynamic) -> Inbound {
  let method = field(obj, "method", decode.string)
  let id = field(obj, "id", decode.int)
  case method, id {
    Ok("notify_status_update"), _ ->
      case status_params(obj) {
        Some(delta) -> StatusDelta(delta)
        None -> Invalid
      }
    Ok("notify_klippy_disconnected"), _ -> KlippyDisconnected
    Ok("notify_klippy_ready"), _ -> KlippyReady
    Ok("notify_klippy_shutdown"), _ -> KlippyShutdown
    Ok(name), _ -> OtherNotification(name)
    Error(_), Ok(id) -> Response(id, response_outcome(obj))
    _, _ -> Invalid
  }
}

fn status_params(obj: Dynamic) -> Option(Dynamic) {
  case field(obj, "params", decode.list(decode.dynamic)) {
    Ok([first, ..]) -> Some(first)
    _ -> None
  }
}

fn response_outcome(obj: Dynamic) -> Result(Dynamic, #(Int, String)) {
  case field(obj, "error", decode.dynamic) {
    Ok(err) -> {
      let code = field(err, "code", decode.int) |> result.unwrap(0)
      let message =
        field(err, "message", decode.string) |> result.unwrap("error")
      Error(#(code, message))
    }
    Error(_) ->
      Ok(field(obj, "result", decode.dynamic) |> result.unwrap(dynamic.nil()))
  }
}

pub type KlippyState {
  StateReady
  StateStarting
  StateDown(reason: String)
}

/// Decode `server.info` result into the klippy state machine input.
pub fn parse_server_info(result: Dynamic) -> Result(KlippyState, String) {
  use state <- result.try(
    field(result, "klippy_state", decode.string)
    |> result.replace_error("missing klippy_state"),
  )
  case state {
    "ready" -> Ok(StateReady)
    "startup" -> Ok(StateStarting)
    "error" | "shutdown" -> Ok(StateDown("klippy " <> state))
    "disconnected" -> Ok(StateDown("klippy disconnected"))
    other -> Ok(StateDown("klippy " <> other))
  }
}

/// Extract `result.status` from a `printer.objects.subscribe` response.
pub fn subscribe_status(result: Dynamic) -> Option(Dynamic) {
  field(result, "status", decode.dynamic)
  |> option.from_result
}

/// Translate a Moonraker status object (delta or full) into status patches.
pub fn status_updates(status: Dynamic) -> List(StatusPatch) {
  let webhooks = field(status, "webhooks", decode.dynamic)
  let print_stats = field(status, "print_stats", decode.dynamic)
  let virtual_sdcard = field(status, "virtual_sdcard", decode.dynamic)
  let extruder = field(status, "extruder", decode.dynamic)
  let heater_bed = field(status, "heater_bed", decode.dynamic)

  let optional: List(Option(StatusPatch)) = [
    option.from_result(webhooks) |> option.map(webhooks_patch),
    option.from_result(print_stats)
      |> option.then(fn(obj) { Some(print_stats_patch(obj)) }),
    option.from_result(print_stats)
      |> option.map(print_stats_faults),
    option.from_result(virtual_sdcard)
      |> option.then(fn(vsd) {
        option.from_result(print_stats)
        |> option.map(fn(ps) { progress_patch(vsd, ps) })
      }),
    temperature_patch(
      option.from_result(extruder),
      option.from_result(heater_bed),
    ),
  ]
  list.filter_map(optional, fn(u) { option.to_result(u, Nil) })
}

fn webhooks_patch(obj: Dynamic) -> StatusPatch {
  let state = field(obj, "state", decode.string) |> result.unwrap("startup")
  let message = field(obj, "state_message", decode.string) |> result.unwrap("")
  let connection = case state {
    "ready" -> Connected
    "startup" -> Connecting
    _ ->
      Disconnected(case message {
        "" -> "klippy " <> state
        m -> m
      })
  }
  Connection(connection)
}

fn print_stats_patch(obj: Dynamic) -> StatusPatch {
  let state = field(obj, "state", decode.string) |> result.unwrap("standby")
  let print = case state {
    "standby" -> Idle
    "printing" -> Printing
    "paused" -> Paused
    "complete" -> Complete
    "cancelled" -> Cancelled
    "error" -> Errored
    _ -> Idle
  }
  Print(print)
}

/// When print_stats is present, also emit an authoritative fault list.
pub fn print_stats_faults(obj: Dynamic) -> StatusPatch {
  let state = field(obj, "state", decode.string) |> result.unwrap("standby")
  let message = field(obj, "message", decode.string) |> result.unwrap("")
  let severity = case state == "error" {
    True -> Critical
    False -> Warning
  }
  let faults = case message {
    "" | "-" -> []
    m -> [Fault(code: "print_stats", message: m, severity:)]
  }
  Faults(Some(faults))
}

fn progress_patch(vsd: Dynamic, print_stats: Dynamic) -> StatusPatch {
  let progress = field(vsd, "progress", number()) |> result.unwrap(0.0)
  let percent = progress *. 100.0
  let remaining = case
    field(print_stats, "print_duration", number()),
    progress >. 0.0
  {
    Ok(duration), True -> {
      let left = duration /. progress -. duration
      Some(float.truncate(left))
    }
    _, _ -> None
  }
  Progress(Some(ProgressInfo(percent, remaining)))
}

fn temperature_patch(
  extruder: Option(Dynamic),
  heater_bed: Option(Dynamic),
) -> Option(StatusPatch) {
  let nozzle =
    option.then(extruder, fn(obj) {
      option.from_result(field(obj, "temperature", number()))
      |> option.then(fn(current) {
        let target = field(obj, "target", number()) |> result.unwrap(0.0)
        Some(Temperature("nozzle", current, target))
      })
    })
  let bed =
    option.then(heater_bed, fn(obj) {
      option.from_result(field(obj, "temperature", number()))
      |> option.then(fn(current) {
        let target = field(obj, "target", number()) |> result.unwrap(0.0)
        Some(Temperature("bed", current, target))
      })
    })
  let temps = list.filter_map([nozzle, bed], fn(t) { option.to_result(t, Nil) })
  case temps {
    [] -> None
    _ -> Some(Temperatures(temps))
  }
}

/// PrusaLink/Moonraker numeric fields may be int or float in JSON.
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

// ---------------------------------------------------------------------------
// HTTP file upload (multipart/form-data) — exclusive to HTTP, not JSON-RPC.
// ---------------------------------------------------------------------------

pub fn upload_gcode(
  config: Config,
  filename: String,
  bytes: BitArray,
) -> Result(Nil, CommandError) {
  let boundary =
    "PrinterCoven" <> bit_array.base16_encode(crypto.strong_random_bytes(8))
  let body = multipart_body(boundary, filename, bytes)
  use req <- result.try(
    request.to(upload_url(config))
    |> result.map_error(fn(_) { TransportError("bad upload url") }),
  )
  let req: Request(BitArray) =
    req
    |> request.set_method(http.Post)
    |> request.set_header(
      "content-type",
      "multipart/form-data; boundary=" <> boundary,
    )
    |> with_api_key(config)
    |> request.map(fn(_) { body })
  let conf = httpc.configure() |> httpc.timeout(30_000)
  use resp <- result.try(
    httpc.dispatch_bits(conf, req)
    |> result.map_error(fn(e) { TransportError(string.inspect(e)) }),
  )
  common.expect_accepted(resp)
}

fn upload_url(config: Config) -> String {
  "http://"
  <> config.host
  <> ":"
  <> int.to_string(config.port)
  <> "/server/files/upload"
}

fn with_api_key(req: Request(body), config: Config) -> Request(body) {
  case config.api_key {
    None -> req
    Some(key) -> request.set_header(req, "x-api-key", key)
  }
}

fn multipart_body(
  boundary: String,
  filename: String,
  bytes: BitArray,
) -> BitArray {
  let header =
    bit_array.from_string(
      "--"
      <> boundary
      <> "\r\n"
      <> "Content-Disposition: form-data; name=\"file\"; filename=\""
      <> filename
      <> "\"\r\n"
      <> "Content-Type: application/octet-stream\r\n"
      <> "\r\n",
    )
  let footer = bit_array.from_string("\r\n--" <> boundary <> "--\r\n")
  bit_array.append(bit_array.append(header, bytes), footer)
}

// ---------------------------------------------------------------------------
// Outbound command helpers (JSON-RPC method names only; actor owns ids).
// ---------------------------------------------------------------------------

pub fn pause_method() -> String {
  "printer.print.pause"
}

pub fn resume_method() -> String {
  "printer.print.resume"
}

pub fn cancel_method() -> String {
  "printer.print.cancel"
}

pub fn start_print_method() -> String {
  "printer.print.start"
}

pub fn server_info_method() -> String {
  "server.info"
}

pub fn subscribe_method() -> String {
  "printer.objects.subscribe"
}
