import gftp
import gftp/file_type
import gftp/result as ftp_result
import gftp/stream
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kafein
import server/backend/bambu_transport
import server/printer.{
  type BackendConfig, type CommandError, type Fault, type PrintState, type Slot,
  type StatusPatch, type Tray, Bambu, Cancelled, Complete, Connected, Connection,
  Errored, Fault, Faults, Idle, Paused, Print, Printing, Progress, ProgressInfo,
  Slot, Temperature, Temperatures, TransportError, Tray, Trays, Warning,
}
import spoke/mqtt
import spoke/mqtt_actor.{type Client}

pub type Config {
  Config(host: String, serial: String, access_code: String)
}

pub fn new(config: BackendConfig) -> Result(Config, String) {
  case config {
    Bambu(host:, serial:, access_code:) ->
      Ok(Config(host:, serial:, access_code:))
    _ -> Error("not a Bambu backend")
  }
}

pub fn report_topic(serial: String) -> String {
  "device/" <> serial <> "/report"
}

pub fn request_topic(serial: String) -> String {
  "device/" <> serial <> "/request"
}

const mqtt_username = "bblp"

const mqtt_port = 8883

/// Start a TLS MQTT client for this printer (does not connect yet).
pub fn start_mqtt(config: Config) -> Result(#(Client, process.Pid), String) {
  let connector = bambu_transport.connector(config.host, mqtt_port, 5000)
  let options =
    mqtt.connect_with_id(connector, config.serial)
    |> mqtt.using_auth(
      mqtt_username,
      Some(bit_array.from_string(config.access_code)),
    )
    |> mqtt.keep_alive_seconds(30)
    |> mqtt.server_timeout_ms(5000)
  case mqtt_actor.start(mqtt_actor.build(options), 5000) {
    Ok(started) -> Ok(#(started.data, started.pid))
    Error(_) -> Error("mqtt actor start failed")
  }
}

pub fn subscribe_report(config: Config, client: Client) -> Result(Nil, Nil) {
  mqtt_actor.subscribe(client, [
    mqtt.SubscribeRequest(
      filter: report_topic(config.serial),
      qos: mqtt.AtLeastOnce,
    ),
  ])
  |> result.replace(Nil)
  |> result.replace_error(Nil)
}

pub fn publish_request(
  config: Config,
  client: Client,
  payload: BitArray,
) -> Nil {
  mqtt_actor.publish(
    client,
    mqtt.PublishData(
      topic: request_topic(config.serial),
      payload: payload,
      qos: mqtt.AtLeastOnce,
      retain: False,
    ),
  )
}

/// Upload gcode over implicit FTPS (port 990), falling back to explicit (21).
///
/// Note: gftp does not reuse the control-channel TLS session on the PASV data
/// channel. Some Bambu firmware (vsFTPd session-reuse) rejects that — failures
/// surface as `TransportError`.
pub fn upload_gcode(
  config: Config,
  filename: String,
  bytes: BitArray,
) -> Result(Nil, CommandError) {
  let ssl_options = kafein.default_options |> kafein.verify(kafein.VerifyNone)
  case implicit_upload(config, ssl_options, filename, bytes) {
    Ok(Nil) -> Ok(Nil)
    Error(implicit_err) ->
      case explicit_upload(config, ssl_options, filename, bytes) {
        Ok(Nil) -> Ok(Nil)
        Error(explicit_err) ->
          Error(TransportError(
            "ftps implicit: "
            <> ftp_result.describe_error(implicit_err)
            <> "; explicit: "
            <> ftp_result.describe_error(explicit_err),
          ))
      }
  }
}

fn implicit_upload(
  config: Config,
  ssl_options: kafein.WrapOptions,
  filename: String,
  bytes: BitArray,
) -> Result(Nil, ftp_result.FtpError) {
  use client <- result.try(gftp.connect_secure_implicit(
    config.host,
    990,
    ssl_options,
    10_000,
  ))
  with_session(client, config, filename, bytes)
}

fn explicit_upload(
  config: Config,
  ssl_options: kafein.WrapOptions,
  filename: String,
  bytes: BitArray,
) -> Result(Nil, ftp_result.FtpError) {
  use client <- result.try(gftp.connect_timeout(config.host, 21, 10_000))
  use secure <- result.try(gftp.into_secure(client, ssl_options))
  with_session(secure, config, filename, bytes)
}

fn with_session(
  client: gftp.FtpClient,
  config: Config,
  filename: String,
  bytes: BitArray,
) -> Result(Nil, ftp_result.FtpError) {
  let out = upload_via(client, config, filename, bytes)
  let _ = gftp.quit(client)
  let _ = gftp.shutdown(client)
  out
}

fn upload_via(
  client: gftp.FtpClient,
  config: Config,
  filename: String,
  bytes: BitArray,
) -> Result(Nil, ftp_result.FtpError) {
  use _ <- result.try(gftp.login(client, mqtt_username, config.access_code))
  use _ <- result.try(gftp.transfer_type(client, file_type.Binary))
  let _ = gftp.cwd(client, "/")
  gftp.stor(client, filename, fn(data_stream) {
    stream.send(data_stream, bytes)
    |> result.map_error(ftp_result.Socket)
  })
}

pub fn parse_report(payload: BitArray) -> List(StatusPatch) {
  case bit_array.to_string(payload) {
    Error(_) -> []
    Ok(text) ->
      case json.parse(text, decode.dynamic) {
        Error(_) -> []
        Ok(obj) -> updates_from_report(obj)
      }
  }
}

pub type CommandReport {
  CommandReport(
    sequence_id: Int,
    result: String,
    reason: String,
    command: String,
  )
}

/// Extract a command ack/reject from a report: `{TYPE: {sequence_id, command,
/// result, reason}}`. `result` is case-insensitive per the Bambu docs.
pub fn parse_command_report(payload: BitArray) -> Option(CommandReport) {
  case bit_array.to_string(payload) {
    Error(_) -> None
    Ok(text) ->
      case json.parse(text, decode.dynamic) {
        Error(_) -> None
        Ok(obj) -> command_report_from(obj)
      }
  }
}

fn command_report_from(obj: Dynamic) -> Option(CommandReport) {
  let types = ["print", "pushing", "info", "system", "upgrade"]
  list.find_map(types, fn(kind) {
    use raw <- result.try(field(obj, kind, decode.dynamic))
    use sequence_id <- result.try(field(raw, "sequence_id", sequence_id()))
    use command <- result.try(field(raw, "command", decode.string))
    use result_str <- result.try(field(raw, "result", decode.string))
    let reason = field(raw, "reason", decode.string) |> result.unwrap("")
    Ok(CommandReport(sequence_id:, result: result_str, reason:, command:))
  })
  |> option.from_result
}

/// sequence_id is a string in most reports but sometimes an int.
fn sequence_id() -> decode.Decoder(Int) {
  decode.one_of(decode.int, or: [
    decode.string |> decode.map(fn(s) { result.unwrap(int.parse(s), -1) }),
  ])
}

fn updates_from_report(obj: Dynamic) -> List(StatusPatch) {
  let print_obj =
    field(obj, "print", decode.dynamic)
    |> result.unwrap(dynamic.nil())

  let gcode_state = field(print_obj, "gcode_state", decode.string)
  let mc_err = field(print_obj, "mc_print_error_code", decode.string)
  let progress_pct = field(print_obj, "mc_percent", decode.float)
  let remaining = field(print_obj, "mc_remaining_time", decode.int)
  let nozzle = field(print_obj, "nozzle_temper", decode.float)
  let nozzle_t = field(print_obj, "nozzle_target_temper", decode.float)
  let bed = field(print_obj, "bed_temper", decode.float)
  let bed_t = field(print_obj, "bed_target_temper", decode.float)
  let hms = field(print_obj, "hms", decode.list(decode.dynamic))
  let ams = field(print_obj, "ams", decode.dynamic)
  let vt = field(print_obj, "vt_tray", decode.dynamic)

  let optional_updates: List(Option(StatusPatch)) = [
    Some(Connection(Connected)),
    case gcode_state {
      Ok(s) -> Some(Print(to_print_state(s, mc_err)))
      Error(_) -> None
    },
    case progress_pct {
      Ok(p) ->
        Some(Progress(Some(ProgressInfo(p, option.from_result(remaining)))))
      Error(_) -> None
    },
    case nozzle, bed {
      Ok(n), Ok(b) ->
        Some(
          Temperatures([
            Temperature("nozzle", n, result.unwrap(nozzle_t, 0.0)),
            Temperature("bed", b, result.unwrap(bed_t, 0.0)),
          ]),
        )
      Ok(n), _ ->
        Some(
          Temperatures([
            Temperature("nozzle", n, result.unwrap(nozzle_t, 0.0)),
          ]),
        )
      _, Ok(b) ->
        Some(Temperatures([Temperature("bed", b, result.unwrap(bed_t, 0.0))]))
      _, _ -> None
    },
    case hms {
      Ok(list) -> Some(Faults(Some(list.filter_map(list, hms_fault))))
      Error(_) -> None
    },
    case
      decode_trays(
        result.unwrap(ams, dynamic.nil()),
        result.unwrap(vt, dynamic.nil()),
      )
    {
      Ok(trays) -> Some(Trays(trays))
      Error(_) -> None
    },
  ]

  list.filter_map(optional_updates, fn(u) { option.to_result(u, Nil) })
}

fn to_print_state(
  gcode_state: String,
  mc_err: Result(String, Nil),
) -> PrintState {
  let errored = case mc_err {
    Ok(code) -> code != "0"
    Error(_) -> False
  }
  case errored {
    True -> Errored
    False ->
      case gcode_state {
        "IDLE" -> Idle
        "RUNNING" | "PREPARE" -> Printing
        "PAUSE" -> Paused
        "FINISH" -> Complete
        "STOP" -> Cancelled
        "FAILED" -> Errored
        _ -> Idle
      }
  }
}

fn hms_fault(raw: Dynamic) -> Result(Fault, Nil) {
  case field(raw, "index", decode.string) {
    Error(_) -> Error(Nil)
    Ok(index) -> {
      let message =
        field(raw, "message", decode.string)
        |> result.unwrap("HMS fault")
      Ok(Fault(
        code: string.lowercase(index),
        message: message,
        severity: Warning,
      ))
    }
  }
}

fn decode_trays(ams: Dynamic, vt: Dynamic) -> Result(List(Tray), Nil) {
  // External spool is always tray index 0.
  let vt_slots = tray_slots(vt) |> result.unwrap([empty_slot(0)])
  let spool = Tray(index: 0, slots: vt_slots)

  let ams_units =
    field(ams, "ams", decode.list(decode.dynamic))
    |> result.unwrap([])

  let ams_trays =
    list.map(ams_units, fn(unit) {
      let slots =
        field(unit, "tray", decode.list(decode.dynamic))
        |> result.unwrap([])
        |> list.map(tray_slot)
      // AMS unit id, not list position: report order is not guaranteed and
      // spec §3 requires tray index = ams_id + 1 (0 is the external spool).
      let ams_id =
        field(unit, "id", decode.string)
        |> result.try(int.parse)
        |> result.unwrap(0)
      Tray(index: ams_id + 1, slots: slots)
    })

  Ok([spool, ..ams_trays])
}

fn tray_slots(unit: Dynamic) -> Result(List(Slot), Nil) {
  field(unit, "tray", decode.list(decode.dynamic))
  |> result.map(list.map(_, tray_slot))
}

fn tray_slot(raw: Dynamic) -> Slot {
  let index =
    field(raw, "id", decode.string)
    |> result.try(int.parse)
    |> result.unwrap(0)
  let material = case field(raw, "tray_type", decode.string) {
    Ok("") | Error(_) -> None
    Ok(s) -> Some(s)
  }
  let color = case field(raw, "tray_color", decode.string) {
    Ok(c) -> Some(normalize_hex(c))
    Error(_) -> None
  }
  let remain = case field(raw, "remain", decode.float) {
    Ok(r) -> Some(r)
    Error(_) -> None
  }
  Slot(index:, material: material, color: color, remaining_percent: remain)
}

fn empty_slot(index: Int) -> Slot {
  Slot(index:, material: None, color: None, remaining_percent: None)
}

fn normalize_hex(c: String) -> String {
  case string.starts_with(c, "#") {
    True -> c
    False -> "#" <> c
  }
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

pub fn pause_payload(sequence_id: Int) -> BitArray {
  json_request("print", sequence_id, "pause", "")
}

pub fn resume_payload(sequence_id: Int) -> BitArray {
  json_request("print", sequence_id, "resume", "")
}

pub fn cancel_payload(sequence_id: Int) -> BitArray {
  json_request("print", sequence_id, "stop", "")
}

pub fn start_print_payload(sequence_id: Int, filename: String) -> BitArray {
  // gcode_file takes a filename on the printer's filesystem, not a path.
  json_request("print", sequence_id, "gcode_file", filename)
}

pub fn pushall_payload(sequence_id: Int) -> BitArray {
  let body =
    json.object([
      #(
        "pushing",
        json.object([
          #("sequence_id", json.string(int.to_string(sequence_id))),
          #("command", json.string("pushall")),
          #("version", json.int(1)),
          #("push_target", json.int(1)),
        ]),
      ),
    ])
  bit_array.from_string(json.to_string(body))
}

fn json_request(
  kind: String,
  sequence_id: Int,
  command: String,
  param: String,
) -> BitArray {
  let body =
    json.object([
      #(
        kind,
        json.object([
          #("sequence_id", json.string(int.to_string(sequence_id))),
          #("command", json.string(command)),
          #("param", json.string(param)),
        ]),
      ),
    ])
  bit_array.from_string(json.to_string(body))
}
