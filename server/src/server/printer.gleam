//// Printer domain: persisted configuration, runtime status, the status
//// patches backends produce, and the commands/events exchanged with printer
//// actors. Presentation (JSON encoders for the API) lives in `web_server`.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

// ---------------------------------------------------------------------------
// Configuration (persisted in the `printers` table)
// ---------------------------------------------------------------------------

pub type PrinterConfig {
  PrinterConfig(
    id: String,
    display_name: String,
    backend: BackendConfig,
    static_trays: List(TrayConfig),
  )
}

pub type TrayConfig {
  TrayConfig(index: Int, slot_count: Int)
}

pub type BackendConfig {
  Bambu(host: String, serial: String, access_code: String)
  PrusaLink(host: String, username: String, password: String)
  Moonraker(host: String, port: Int, api_key: Option(String))
}

pub fn tray_config_encoder(config: TrayConfig) -> json.Json {
  json.object([
    #("index", json.int(config.index)),
    #("slot_count", json.int(config.slot_count)),
  ])
}

pub fn tray_config_decoder() -> decode.Decoder(TrayConfig) {
  use index <- decode.field("index", decode.int)
  use slot_count <- decode.field("slot_count", decode.int)
  decode.success(TrayConfig(index:, slot_count:))
}

pub fn trays_encoder(trays: List(TrayConfig)) -> json.Json {
  json.array(trays, tray_config_encoder)
}

pub fn trays_decoder() -> decode.Decoder(List(TrayConfig)) {
  decode.list(of: tray_config_decoder())
}

pub fn backend_encoder(backend: BackendConfig) -> json.Json {
  case backend {
    Bambu(host:, serial:, access_code:) ->
      json.object([
        #(
          "Bambu",
          json.object([
            #("host", json.string(host)),
            #("serial", json.string(serial)),
            #("access_code", json.string(access_code)),
          ]),
        ),
      ])
    PrusaLink(host:, username:, password:) ->
      json.object([
        #(
          "PrusaLink",
          json.object([
            #("host", json.string(host)),
            #("username", json.string(username)),
            #("password", json.string(password)),
          ]),
        ),
      ])
    Moonraker(host:, port:, api_key:) ->
      json.object([
        #(
          "Moonraker",
          json.object([
            #("host", json.string(host)),
            #("port", json.int(port)),
            #("api_key", json.nullable(api_key, json.string)),
          ]),
        ),
      ])
  }
}

pub fn backend_decoder() -> decode.Decoder(BackendConfig) {
  decode.one_of(bambu_decoder(), or: [
    prusalink_decoder(),
    moonraker_decoder(),
  ])
}

fn bambu_decoder() -> decode.Decoder(BackendConfig) {
  use inner <- decode.field("Bambu", {
    use host <- decode.field("host", decode.string)
    use serial <- decode.field("serial", decode.string)
    use access_code <- decode.field("access_code", decode.string)
    decode.success(Bambu(host:, serial:, access_code:))
  })
  decode.success(inner)
}

fn prusalink_decoder() -> decode.Decoder(BackendConfig) {
  use inner <- decode.field("PrusaLink", {
    use host <- decode.field("host", decode.string)
    use username <- decode.field("username", decode.string)
    use password <- decode.field("password", decode.string)
    decode.success(PrusaLink(host:, username:, password:))
  })
  decode.success(inner)
}

fn moonraker_decoder() -> decode.Decoder(BackendConfig) {
  use inner <- decode.field("Moonraker", {
    use host <- decode.field("host", decode.string)
    use port <- decode.field("port", decode.int)
    use api_key <- decode.field("api_key", decode.optional(decode.string))
    decode.success(Moonraker(host:, port:, api_key:))
  })
  decode.success(inner)
}

pub fn config_encoder(config: PrinterConfig) -> json.Json {
  json.object([
    #("id", json.string(config.id)),
    #("display_name", json.string(config.display_name)),
    #("backend", backend_encoder(config.backend)),
    #("static_trays", trays_encoder(config.static_trays)),
  ])
}

// ---------------------------------------------------------------------------
// Status (the aggregate's observed state)
// ---------------------------------------------------------------------------

pub type ConnectionState {
  Connected
  Connecting
  Disconnected(reason: String)
}

pub type PrintState {
  Idle
  Printing
  Paused
  NeedsAttention
  Complete
  Cancelled
  Errored
}

/// `Critical` is exported as `"error"` on the wire (API compatibility).
pub type FaultSeverity {
  Warning
  Critical
}

pub type Fault {
  Fault(code: String, message: String, severity: FaultSeverity)
}

pub type Temperature {
  Temperature(name: String, current: Float, target: Float)
}

pub type ProgressInfo {
  ProgressInfo(percent: Float, time_remaining_seconds: Option(Int))
}

pub type Slot {
  Slot(
    index: Int,
    material: Option(String),
    color: Option(String),
    remaining_percent: Option(Float),
  )
}

pub type Tray {
  Tray(index: Int, slots: List(Slot))
}

pub type PrinterStatus {
  PrinterStatus(
    connection: ConnectionState,
    print: PrintState,
    progress: Option(ProgressInfo),
    temperatures: List(Temperature),
    trays: List(Tray),
    faults: List(Fault),
  )
}

// ---------------------------------------------------------------------------
// Status patches — partial updates decoded by backends and merged into the
// status above. Each field-scoped variant replaces that field wholesale.
// ---------------------------------------------------------------------------

pub type StatusPatch {
  Connection(ConnectionState)
  Print(PrintState)
  Progress(Option(ProgressInfo))
  Temperatures(List(Temperature))
  Trays(List(Tray))
  /// Authoritative fault list when `Some`; absent (keep prior) when `None`.
  Faults(Option(List(Fault)))
}

pub fn initial(static_trays: List(TrayConfig)) -> PrinterStatus {
  PrinterStatus(
    connection: Connecting,
    print: Idle,
    progress: None,
    temperatures: [],
    trays: list.map(static_trays, fn(tray) {
      Tray(
        index: tray.index,
        slots: int.range(
          from: 0,
          to: tray.slot_count,
          with: [],
          run: fn(acc, index) {
            [
              Slot(index:, material: None, color: None, remaining_percent: None),
              ..acc
            ]
          },
        )
          |> list.reverse,
      )
    }),
    faults: [],
  )
}

pub fn merge(current: PrinterStatus, update: StatusPatch) -> PrinterStatus {
  case update {
    Connection(connection) -> PrinterStatus(..current, connection:)
    Print(print) -> PrinterStatus(..current, print:)
    Progress(progress) -> PrinterStatus(..current, progress:)
    Temperatures(temperatures) -> PrinterStatus(..current, temperatures:)
    // Backends emit the complete tray set (Bambu is the only producer and
    // always reports the full AMS state), so replace wholesale like faults.
    Trays(trays) -> PrinterStatus(..current, trays:)
    Faults(Some(faults)) -> PrinterStatus(..current, faults:)
    Faults(None) -> current
  }
}

pub fn merge_all(
  current: PrinterStatus,
  updates: List(StatusPatch),
) -> PrinterStatus {
  case updates {
    [] -> current
    [update, ..rest] -> merge_all(merge(current, update), rest)
  }
}

// ---------------------------------------------------------------------------
// Commands (client → actor) and events (actor → manager)
// ---------------------------------------------------------------------------

pub type PrinterMessage {
  StartPrint(file_id: Int)
  PausePrint
  ResumePrint
  CancelPrint
}

pub type CommandError {
  NotConnected
  RejectedByPrinter(reason: String)
  TransportError(String)
}

pub type PrinterEvent {
  StatusUpdate(PrinterStatus)
  CommandFailed(command: PrinterMessage, error: CommandError)
}
