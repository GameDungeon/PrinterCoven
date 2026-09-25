import gleam/dynamic
import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import pog
import server/backend/bambu
import server/backend/common
import server/backend/moonraker
import server/backend/prusa
import server/database
import server/printer.{
  type CommandError, type PrinterConfig, type PrinterEvent, type PrinterMessage,
  type PrinterStatus, type StatusPatch, Bambu, CancelPrint, CommandFailed,
  Connected, Connection, Disconnected, Moonraker, NotConnected, PausePrint,
  Printing, PrusaLink, RejectedByPrinter, ResumePrint, StartPrint, StatusUpdate,
  TransportError, initial, merge, merge_all,
}
import server/sql
import spoke/mqtt
import spoke/mqtt_actor

pub type BackendRuntime {
  PrusaRuntime(client: prusa.Client)
  BambuRuntime(
    config: bambu.Config,
    sequence_id: Int,
    connected: Bool,
    mqtt: Option(mqtt_actor.Client),
    // In-flight commands keyed by sequence_id, newest first, capped at
    // max_pending. When a report acks/rejects a sequence, the command resolves
    // here so the actor can emit CommandFailed on result != success
    // (spec §5, opportunistic — some Bambu commands never report back).
    pending: List(#(Int, PrinterMessage)),
  )
  MoonrakerRuntime(
    config: moonraker.Config,
    client: Option(moonraker.Client),
    next_id: Int,
    pending: List(#(Int, moonraker.Pending)),
    monitor: Option(process.Monitor),
  )
}

pub type State {
  State(
    config: PrinterConfig,
    emit: fn(PrinterEvent) -> Nil,
    self: Subject(Msg),
    status: PrinterStatus,
    runtime: BackendRuntime,
    db: database.Db,
    // Poll heartbeat for Prusa (and later Moonraker if it ever polls).
    poll_timer: Option(process.Timer),
    // Reconnect/backoff timer for push transports (Bambu MQTT, Moonraker WS).
    // Kept separate from poll_timer so a status-driven schedule_poll cannot
    // cancel a pending reconnect (and vice versa).
    reconnect_timer: Option(process.Timer),
    // Recurring klippy retry timer (Moonraker server.info while klippy is
    // starting). Distinct from reconnect_timer: the WS may still be healthy
    // while klippy itself is down/restarting.
    klippy_timer: Option(process.Timer),
  )
}

pub type Msg {
  Public(PrinterMessage)
  BackendStatus(List(StatusPatch))
  PollTick
  MqttStateChanged(mqtt.ConnectionState)
  MqttReport(BitArray)
  ReconnectTick
  KlippyRetry
  MoonrakerEvent(moonraker.Event)
  WsDown(process.Down)
}

pub type Handle {
  Handle(msg: Subject(Msg), name: process.Name(Msg))
}

pub type StartArg {
  StartArg(
    config: PrinterConfig,
    name: process.Name(Msg),
    emit: fn(PrinterEvent) -> Nil,
    db: database.Db,
  )
}

/// Factory-supervisor template: start one printer actor. `name` is created
/// once by the manager when it builds `StartArg`, so restarts re-register
/// under the same atom instead of minting a new one. `emit` delivers domain
/// events back to the manager (wired there so the actor never depends on the
/// manager's message type).
pub fn start(arg: StartArg) -> actor.StartResult(Handle) {
  let StartArg(config:, name:, emit:, db:) = arg
  let subject = process.named_subject(name)

  actor.new_with_initialiser(5000, fn(initial_subject) {
    let poll_timer = case config.backend {
      PrusaLink(..) -> Some(process.send_after(initial_subject, 100, PollTick))
      _ -> None
    }
    let state =
      State(
        config:,
        emit:,
        self: subject,
        status: initial(config.static_trays),
        runtime: init_runtime(config, initial_subject),
        db:,
        poll_timer:,
        reconnect_timer: None,
        klippy_timer: None,
      )
    let selector =
      process.new_selector()
      |> process.select(initial_subject)
      |> process.select_monitors(fn(down) { WsDown(down) })
    Ok(
      actor.initialised(state)
      |> actor.selecting(selector)
      |> actor.returning(Handle(msg: subject, name:)),
    )
  })
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

fn init_runtime(
  config: PrinterConfig,
  initial_subject: Subject(Msg),
) -> BackendRuntime {
  case config.backend {
    PrusaLink(..) ->
      case prusa.new(config.backend) {
        Ok(client) -> PrusaRuntime(client)
        Error(reason) -> {
          io.println(
            "printer " <> config.id <> ": prusa client init failed: " <> reason,
          )
          // PrusaLink(..) above guarantees new() succeeds; keep the actor
          // alive with a blank client so poll reports Disconnected.
          let assert Ok(client) = prusa.new(PrusaLink("", "", ""))
          PrusaRuntime(client)
        }
      }
    Bambu(..) ->
      case bambu.new(config.backend) {
        Error(reason) -> {
          io.println(
            "printer " <> config.id <> ": bambu config init failed: " <> reason,
          )
          BambuRuntime(bambu.Config("", "", ""), 0, False, None, [])
        }
        Ok(c) -> init_bambu_mqtt(config.id, c, initial_subject)
      }
    Moonraker(..) ->
      case moonraker.new(config.backend) {
        Ok(c) -> init_moonraker(config.id, c, initial_subject)
        Error(reason) -> {
          io.println(
            "printer "
            <> config.id
            <> ": moonraker config init failed: "
            <> reason,
          )
          MoonrakerRuntime(
            config: moonraker.Config("", 7125, None),
            client: None,
            next_id: 1,
            pending: [],
            monitor: None,
          )
        }
      }
  }
}

fn init_moonraker(
  printer_id: String,
  config: moonraker.Config,
  initial_subject: Subject(Msg),
) -> BackendRuntime {
  let deliver = fn(event: moonraker.Event) {
    process.send(initial_subject, MoonrakerEvent(event))
  }
  case moonraker.start_client(config, deliver) {
    Error(reason) -> {
      io.println(
        "printer " <> printer_id <> ": moonraker ws start failed: " <> reason,
      )
      let _ = process.send_after(initial_subject, 5000, ReconnectTick)
      MoonrakerRuntime(
        config:,
        client: None,
        next_id: 1,
        pending: [],
        monitor: None,
      )
    }
    Ok(client) -> {
      let next_id = 1
      let payload =
        moonraker.rpc_request(next_id, moonraker.server_info_method(), None)
      moonraker.send_json(client, payload)
      MoonrakerRuntime(
        config:,
        client: Some(client),
        next_id: next_id + 1,
        pending: [#(next_id, moonraker.ServerInfo)],
        monitor: Some(client.monitor),
      )
    }
  }
}

fn init_bambu_mqtt(
  printer_id: String,
  config: bambu.Config,
  initial_subject: Subject(Msg),
) -> BackendRuntime {
  case bambu.start_mqtt(config) {
    Error(reason) -> {
      io.println("printer " <> printer_id <> ": mqtt start failed: " <> reason)
      BambuRuntime(config, 0, False, None, [])
    }
    Ok(#(client, pid)) -> {
      let _ = process.link(pid)
      let _ =
        mqtt_actor.subscribe_to_updates_selecting(
          client,
          initial_subject,
          map_mqtt_update(bambu.report_topic(config.serial)),
        )
      mqtt_actor.connect(client, True, None)
      BambuRuntime(config, 0, False, Some(client), [])
    }
  }
}

fn map_mqtt_update(report_topic: String) -> fn(mqtt.Update) -> Option(Msg) {
  fn(update) {
    case update {
      mqtt.ConnectionStateChanged(state) -> Some(MqttStateChanged(state))
      mqtt.ReceivedMessage(topic:, payload:, retained: _) ->
        case topic == report_topic {
          True -> Some(MqttReport(payload))
          False -> None
        }
    }
  }
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Public(command) -> handle_command(state, command)
    BackendStatus(updates) -> {
      let status = merge_all(state.status, updates)
      state.emit(StatusUpdate(status))
      schedule_poll(State(..state, status:))
    }
    MqttStateChanged(connection) -> handle_mqtt_state(state, connection)
    MqttReport(payload) -> {
      let state = handle_bambu_command_report(state, payload)
      case bambu.parse_report(payload) {
        [] -> actor.continue(state)
        updates -> {
          let status = merge_all(state.status, updates)
          state.emit(StatusUpdate(status))
          actor.continue(State(..state, status:))
        }
      }
    }
    ReconnectTick -> handle_reconnect_tick(state)
    KlippyRetry -> handle_klippy_retry(state)
    MoonrakerEvent(event) -> handle_moonraker_event(state, event)
    WsDown(down) -> handle_moonraker_down(state, down)
    PollTick -> poll(state)
  }
}

fn handle_command(
  state: State,
  command: PrinterMessage,
) -> actor.Next(State, Msg) {
  case state.runtime {
    PrusaRuntime(client) -> handle_prusa_command(state, client, command)
    BambuRuntime(config:, sequence_id:, connected:, mqtt:, pending:) -> {
      case connected, mqtt {
        False, _ -> {
          state.emit(CommandFailed(command, NotConnected))
          actor.continue(state)
        }
        True, None -> {
          state.emit(CommandFailed(
            command,
            TransportError("mqtt client not started"),
          ))
          actor.continue(state)
        }
        True, Some(client) ->
          handle_bambu_command(
            state,
            config,
            sequence_id,
            client,
            pending,
            command,
          )
      }
    }
    MoonrakerRuntime(config:, client:, next_id:, pending:, monitor:) ->
      handle_moonraker_command(
        state,
        config,
        client,
        next_id,
        pending,
        monitor,
        command,
      )
  }
}

/// Cap on in-flight command correlations; older entries are dropped.
const max_pending = 32

fn pending_record(
  pending: List(#(Int, PrinterMessage)),
  sequence_id: Int,
  command: PrinterMessage,
) -> List(#(Int, PrinterMessage)) {
  list.take([#(sequence_id, command), ..pending], max_pending)
}

/// Opportunistic command-report correlation (spec §5): a later
/// result != success for a tracked sequence emits CommandFailed.
fn handle_bambu_command_report(state: State, payload: BitArray) -> State {
  case state.runtime, bambu.parse_command_report(payload) {
    BambuRuntime(config:, sequence_id:, connected:, mqtt:, pending:),
      Some(report)
    -> {
      case list.key_find(pending, report.sequence_id) {
        Error(_) -> state
        Ok(command) -> {
          let pending =
            list.filter(pending, fn(entry) { entry.0 != report.sequence_id })
          let runtime =
            BambuRuntime(config:, sequence_id:, connected:, mqtt:, pending:)
          let state = State(..state, runtime:)
          case string.lowercase(report.result) == "success" {
            True -> state
            False -> {
              let reason = case report.reason {
                "" -> report.result
                r -> r
              }
              state.emit(CommandFailed(command, RejectedByPrinter(reason)))
              state
            }
          }
        }
      }
    }
    _, _ -> state
  }
}

fn handle_bambu_command(
  state: State,
  config: bambu.Config,
  sequence_id: Int,
  client: mqtt_actor.Client,
  pending: List(#(Int, PrinterMessage)),
  command: PrinterMessage,
) -> actor.Next(State, Msg) {
  case command {
    PausePrint ->
      bambu_publish(
        state,
        config,
        sequence_id,
        client,
        pending,
        command,
        bambu.pause_payload,
      )
    ResumePrint ->
      bambu_publish(
        state,
        config,
        sequence_id,
        client,
        pending,
        command,
        bambu.resume_payload,
      )
    CancelPrint ->
      bambu_publish(
        state,
        config,
        sequence_id,
        client,
        pending,
        command,
        bambu.cancel_payload,
      )
    StartPrint(file_id) ->
      bambu_start_print(state, config, sequence_id, client, pending, file_id)
  }
}

fn bambu_publish(
  state: State,
  config: bambu.Config,
  sequence_id: Int,
  client: mqtt_actor.Client,
  pending: List(#(Int, PrinterMessage)),
  command: PrinterMessage,
  payload: fn(Int) -> BitArray,
) -> actor.Next(State, Msg) {
  let sequence_id = sequence_id + 1
  bambu.publish_request(config, client, payload(sequence_id))
  actor.continue(
    State(
      ..state,
      runtime: BambuRuntime(
        config:,
        sequence_id:,
        connected: True,
        mqtt: Some(client),
        pending: pending_record(pending, sequence_id, command),
      ),
    ),
  )
}

fn bambu_start_print(
  state: State,
  config: bambu.Config,
  sequence_id: Int,
  client: mqtt_actor.Client,
  pending: List(#(Int, PrinterMessage)),
  file_id: Int,
) -> actor.Next(State, Msg) {
  let command = StartPrint(file_id)
  case fetch_gcode(state.db, file_id) {
    Error(e) -> {
      state.emit(CommandFailed(command, TransportError(e)))
      actor.continue(state)
    }
    Ok(bytes) -> {
      let filename = common.gcode_filename(file_id)
      case bambu.upload_gcode(config, filename, bytes) {
        Error(e) -> {
          state.emit(CommandFailed(command, e))
          actor.continue(state)
        }
        Ok(Nil) ->
          bambu_publish(
            state,
            config,
            sequence_id,
            client,
            pending,
            command,
            fn(seq) { bambu.start_print_payload(seq, filename) },
          )
      }
    }
  }
}

fn handle_mqtt_state(
  state: State,
  connection: mqtt.ConnectionState,
) -> actor.Next(State, Msg) {
  case connection {
    mqtt.ConnectAccepted(_) -> bambu_mqtt_accepted(state)
    mqtt.ConnectFailed(reason) -> bambu_mqtt_down(state, reason)
    mqtt.ConnectRejected(e) ->
      bambu_mqtt_down(state, "connect rejected: " <> string.inspect(e))
    mqtt.Disconnected -> bambu_mqtt_down(state, "disconnected")
    mqtt.DisconnectedUnexpectedly(reason) -> bambu_mqtt_down(state, reason)
  }
}

fn bambu_mqtt_accepted(state: State) -> actor.Next(State, Msg) {
  case state.runtime {
    BambuRuntime(config:, sequence_id:, mqtt:, pending:, ..) -> {
      case mqtt {
        None -> actor.continue(state)
        Some(client) -> {
          let status = merge(state.status, Connection(Connected))
          state.emit(StatusUpdate(status))
          let _ = bambu.subscribe_report(config, client)
          let sequence_id = sequence_id + 1
          bambu.publish_request(
            config,
            client,
            bambu.pushall_payload(sequence_id),
          )
          cancel_timer(state.reconnect_timer)
          actor.continue(
            State(
              ..state,
              status:,
              reconnect_timer: None,
              runtime: BambuRuntime(
                config:,
                sequence_id:,
                connected: True,
                mqtt: Some(client),
                pending:,
              ),
            ),
          )
        }
      }
    }
    _ -> actor.continue(state)
  }
}

fn bambu_mqtt_down(state: State, reason: String) -> actor.Next(State, Msg) {
  case state.runtime {
    BambuRuntime(config:, sequence_id:, mqtt:, pending:, ..) -> {
      let status = merge(state.status, Connection(Disconnected(reason)))
      state.emit(StatusUpdate(status))
      cancel_timer(state.reconnect_timer)
      let timer = process.send_after(state.self, 5000, ReconnectTick)
      actor.continue(
        State(
          ..state,
          status:,
          reconnect_timer: Some(timer),
          runtime: BambuRuntime(
            config:,
            sequence_id:,
            connected: False,
            mqtt:,
            pending:,
          ),
        ),
      )
    }
    _ -> actor.continue(state)
  }
}

/// Reconnect tick for push transports: clear the fired timer and, if the
/// transport is down, re-initiate the connection.
fn handle_reconnect_tick(state: State) -> actor.Next(State, Msg) {
  cancel_timer(state.reconnect_timer)
  case state.runtime {
    BambuRuntime(connected: False, mqtt: Some(client), ..) -> {
      mqtt_actor.connect(client, True, None)
      actor.continue(State(..state, reconnect_timer: None))
    }
    MoonrakerRuntime(config:, client: None, ..) -> {
      let runtime = init_moonraker(state.config.id, config, state.self)
      actor.continue(State(..state, reconnect_timer: None, runtime:))
    }
    _ -> actor.continue(State(..state, reconnect_timer: None))
  }
}

fn handle_klippy_retry(state: State) -> actor.Next(State, Msg) {
  cancel_timer(state.klippy_timer)
  actor.continue(
    State(..state, klippy_timer: None, runtime: send_server_info(state.runtime)),
  )
}

fn send_server_info(runtime: BackendRuntime) -> BackendRuntime {
  case runtime {
    MoonrakerRuntime(config:, client:, next_id:, pending:, monitor:) -> {
      case client {
        None -> runtime
        Some(client) -> {
          let payload =
            moonraker.rpc_request(next_id, moonraker.server_info_method(), None)
          moonraker.send_json(client, payload)
          MoonrakerRuntime(
            config:,
            client: Some(client),
            next_id: next_id + 1,
            pending: list.take(
              [#(next_id, moonraker.ServerInfo), ..pending],
              max_pending,
            ),
            monitor:,
          )
        }
      }
    }
    other -> other
  }
}

fn handle_moonraker_event(
  state: State,
  event: moonraker.Event,
) -> actor.Next(State, Msg) {
  case event {
    moonraker.TextFrame(text) -> handle_moonraker_text(state, text)
    moonraker.Closed(reason) -> moonraker_down(state, reason)
  }
}

fn handle_moonraker_down(
  state: State,
  down: process.Down,
) -> actor.Next(State, Msg) {
  case state.runtime {
    MoonrakerRuntime(client:, monitor:, ..) -> {
      case monitor, client {
        Some(m), Some(_) if m == down.monitor ->
          moonraker_down(state, "socket closed")
        _, _ -> actor.continue(state)
      }
    }
    _ -> actor.continue(state)
  }
}

fn moonraker_down(state: State, reason: String) -> actor.Next(State, Msg) {
  case state.runtime {
    MoonrakerRuntime(pending:, ..) -> {
      // Clear client first so a concurrent Closed+Down double-fire is idempotent.
      let runtime = clear_moonraker_client(state.runtime)
      // Fail any pending commands so callers get answers.
      list.each(pending, fn(entry) {
        case entry.1 {
          moonraker.CommandPending(command) ->
            state.emit(CommandFailed(command, NotConnected))
          _ -> Nil
        }
      })
      let status = merge(state.status, Connection(Disconnected(reason)))
      state.emit(StatusUpdate(status))
      cancel_timer(state.reconnect_timer)
      cancel_timer(state.klippy_timer)
      let timer = process.send_after(state.self, 5000, ReconnectTick)
      actor.continue(
        State(
          ..state,
          status:,
          reconnect_timer: Some(timer),
          klippy_timer: None,
          runtime:,
        ),
      )
    }
    _ -> actor.continue(state)
  }
}

fn handle_moonraker_text(state: State, text: String) -> actor.Next(State, Msg) {
  case moonraker.parse_inbound(text) {
    moonraker.Invalid -> actor.continue(state)
    moonraker.Response(id:, outcome:) ->
      handle_moonraker_response(state, id, outcome)
    moonraker.StatusDelta(delta) ->
      apply_moonraker_updates(state, moonraker.status_updates(delta))
    moonraker.KlippyDisconnected ->
      apply_moonraker_updates(state, [
        Connection(Disconnected("klippy disconnected")),
      ])
    moonraker.KlippyReady -> {
      // Re-query server.info so we can re-subscribe cleanly.
      let state = State(..state, runtime: send_server_info(state.runtime))
      actor.continue(state)
    }
    moonraker.KlippyShutdown ->
      apply_moonraker_updates(state, [
        Connection(Disconnected("klippy shutdown")),
      ])
    moonraker.OtherNotification(_) -> actor.continue(state)
  }
}

fn apply_moonraker_updates(
  state: State,
  updates: List(StatusPatch),
) -> actor.Next(State, Msg) {
  case updates {
    [] -> actor.continue(state)
    _ -> {
      let status = merge_all(state.status, updates)
      state.emit(StatusUpdate(status))
      actor.continue(State(..state, status:))
    }
  }
}

fn handle_moonraker_response(
  state: State,
  id: Int,
  outcome: Result(dynamic.Dynamic, #(Int, String)),
) -> actor.Next(State, Msg) {
  case state.runtime {
    MoonrakerRuntime(config:, client:, next_id:, pending:, monitor:) -> {
      case list.key_find(pending, id) {
        Error(_) -> actor.continue(state)
        Ok(pending_kind) -> {
          let pending = list.filter(pending, fn(entry) { entry.0 != id })
          let runtime =
            MoonrakerRuntime(config:, client:, next_id:, pending:, monitor:)
          let state = State(..state, runtime:)
          resolve_moonraker_pending(state, pending_kind, outcome)
        }
      }
    }
    _ -> actor.continue(state)
  }
}

fn resolve_moonraker_pending(
  state: State,
  pending_kind: moonraker.Pending,
  outcome: Result(dynamic.Dynamic, #(Int, String)),
) -> actor.Next(State, Msg) {
  case pending_kind, outcome {
    moonraker.ServerInfo, Ok(result) -> handle_server_info(state, result)
    moonraker.ServerInfo, Error(#(_, message)) ->
      moonraker_reconnect(state, "server.info failed: " <> message)
    moonraker.Subscribe, Ok(result) -> {
      let updates = case moonraker.subscribe_status(result) {
        None -> []
        Some(status) ->
          list.append([Connection(Connected)], moonraker.status_updates(status))
      }
      apply_moonraker_updates(state, updates)
    }
    moonraker.Subscribe, Error(#(_, message)) ->
      moonraker_reconnect(state, "subscribe failed: " <> message)
    moonraker.CommandPending(_), Ok(_) -> actor.continue(state)
    moonraker.CommandPending(command), Error(#(_, message)) -> {
      state.emit(CommandFailed(command, RejectedByPrinter(message)))
      actor.continue(state)
    }
  }
}

fn handle_server_info(
  state: State,
  result: dynamic.Dynamic,
) -> actor.Next(State, Msg) {
  case moonraker.parse_server_info(result) {
    Error(e) -> moonraker_reconnect(state, e)
    Ok(moonraker.StateReady) -> {
      // Cancel any pending klippy retry and subscribe for the full object set.
      cancel_timer(state.klippy_timer)
      let runtime = send_subscribe(state.runtime)
      actor.continue(
        State(
          ..state,
          klippy_timer: None,
          runtime:,
          status: merge(state.status, Connection(Connected)),
        ),
      )
    }
    Ok(moonraker.StateStarting) -> {
      // Klippy is starting — retry server.info shortly without dropping the WS.
      cancel_timer(state.klippy_timer)
      let timer = process.send_after(state.self, 2000, KlippyRetry)
      actor.continue(
        State(
          ..state,
          klippy_timer: Some(timer),
          runtime: send_server_info(state.runtime),
        ),
      )
    }
    Ok(moonraker.StateDown(reason)) ->
      apply_moonraker_updates(state, [Connection(Disconnected(reason))])
  }
}

fn send_subscribe(runtime: BackendRuntime) -> BackendRuntime {
  case runtime {
    MoonrakerRuntime(config:, client:, next_id:, pending:, monitor:) -> {
      case client {
        None -> runtime
        Some(client) -> {
          let payload =
            moonraker.rpc_request(
              next_id,
              moonraker.subscribe_method(),
              Some(moonraker.subscribe_params()),
            )
          moonraker.send_json(client, payload)
          MoonrakerRuntime(
            config:,
            client: Some(client),
            next_id: next_id + 1,
            pending: list.take(
              [#(next_id, moonraker.Subscribe), ..pending],
              max_pending,
            ),
            monitor:,
          )
        }
      }
    }
    other -> other
  }
}

fn moonraker_reconnect(state: State, reason: String) -> actor.Next(State, Msg) {
  let status = merge(state.status, Connection(Disconnected(reason)))
  state.emit(StatusUpdate(status))
  cancel_timer(state.reconnect_timer)
  cancel_timer(state.klippy_timer)
  let timer = process.send_after(state.self, 5000, ReconnectTick)
  actor.continue(
    State(
      ..state,
      status:,
      reconnect_timer: Some(timer),
      klippy_timer: None,
      runtime: clear_moonraker_client(state.runtime),
    ),
  )
}

fn clear_moonraker_client(runtime: BackendRuntime) -> BackendRuntime {
  case runtime {
    MoonrakerRuntime(config:, client:, ..) -> {
      case client {
        Some(c) -> {
          let _ = process.demonitor_process(c.monitor)
          Nil
        }
        None -> Nil
      }
      MoonrakerRuntime(
        config:,
        client: None,
        next_id: 1,
        pending: [],
        monitor: None,
      )
    }
    other -> other
  }
}

fn handle_moonraker_command(
  state: State,
  config: moonraker.Config,
  client: Option(moonraker.Client),
  next_id: Int,
  pending: List(#(Int, moonraker.Pending)),
  monitor: Option(process.Monitor),
  command: PrinterMessage,
) -> actor.Next(State, Msg) {
  case client {
    None -> {
      state.emit(CommandFailed(command, NotConnected))
      actor.continue(state)
    }
    Some(client) ->
      case command {
        PausePrint ->
          moonraker_rpc(
            state,
            config,
            client,
            next_id,
            pending,
            monitor,
            command,
            moonraker.pause_method(),
            None,
          )
        ResumePrint ->
          moonraker_rpc(
            state,
            config,
            client,
            next_id,
            pending,
            monitor,
            command,
            moonraker.resume_method(),
            None,
          )
        CancelPrint ->
          moonraker_rpc(
            state,
            config,
            client,
            next_id,
            pending,
            monitor,
            command,
            moonraker.cancel_method(),
            None,
          )
        StartPrint(file_id) ->
          moonraker_start_print(
            state,
            config,
            client,
            next_id,
            pending,
            monitor,
            file_id,
          )
      }
  }
}

fn moonraker_rpc(
  state: State,
  config: moonraker.Config,
  client: moonraker.Client,
  next_id: Int,
  pending: List(#(Int, moonraker.Pending)),
  monitor: Option(process.Monitor),
  command: PrinterMessage,
  method: String,
  params: option.Option(json.Json),
) -> actor.Next(State, Msg) {
  let payload = moonraker.rpc_request(next_id, method, params)
  moonraker.send_json(client, payload)
  actor.continue(
    State(
      ..state,
      runtime: MoonrakerRuntime(
        config:,
        client: Some(client),
        next_id: next_id + 1,
        pending: list.take(
          [#(next_id, moonraker.CommandPending(command)), ..pending],
          max_pending,
        ),
        monitor:,
      ),
    ),
  )
}

fn moonraker_start_print(
  state: State,
  config: moonraker.Config,
  client: moonraker.Client,
  next_id: Int,
  pending: List(#(Int, moonraker.Pending)),
  monitor: Option(process.Monitor),
  file_id: Int,
) -> actor.Next(State, Msg) {
  let command = StartPrint(file_id)
  case fetch_gcode(state.db, file_id) {
    Error(e) -> {
      state.emit(CommandFailed(command, TransportError(e)))
      actor.continue(state)
    }
    Ok(bytes) -> {
      let filename = common.gcode_filename(file_id)
      case moonraker.upload_gcode(config, filename, bytes) {
        Error(e) -> {
          state.emit(CommandFailed(command, e))
          actor.continue(state)
        }
        Ok(Nil) ->
          moonraker_rpc(
            state,
            config,
            client,
            next_id,
            pending,
            monitor,
            command,
            moonraker.start_print_method(),
            Some(moonraker.start_print_params(filename)),
          )
      }
    }
  }
}

fn handle_prusa_command(
  state: State,
  client: prusa.Client,
  command: PrinterMessage,
) -> actor.Next(State, Msg) {
  case command {
    StartPrint(file_id) ->
      case fetch_gcode(state.db, file_id) {
        Error(e) -> {
          state.emit(CommandFailed(command, TransportError(e)))
          actor.continue(state)
        }
        Ok(bytes) ->
          prusa_outcome(
            state,
            command,
            prusa.upload_and_start(client, file_id, bytes),
          )
      }
    PausePrint -> prusa_outcome(state, command, prusa.pause(client))
    ResumePrint -> prusa_outcome(state, command, prusa.resume(client))
    CancelPrint -> prusa_outcome(state, command, prusa.cancel(client))
  }
}

/// Persist the client returned by a successful command (digest nonce may
/// have been learned mid-request); on failure keep the old client.
fn prusa_outcome(
  state: State,
  command: PrinterMessage,
  outcome: Result(#(prusa.Client, Nil), CommandError),
) -> actor.Next(State, Msg) {
  case outcome {
    Ok(#(client, Nil)) ->
      actor.continue(State(..state, runtime: PrusaRuntime(client)))
    Error(e) -> {
      state.emit(CommandFailed(command, e))
      actor.continue(state)
    }
  }
}

fn poll(state: State) -> actor.Next(State, Msg) {
  case state.runtime {
    PrusaRuntime(client) ->
      case prusa.fetch_status(client) {
        Error(e) -> {
          // Poll failure is not a command — surface connection only.
          let reason = case e {
            TransportError(message) -> message
            NotConnected -> "not connected"
            RejectedByPrinter(message) -> message
          }
          let status =
            merge(
              state.status,
              Connection(Disconnected("poll failed: " <> reason)),
            )
          state.emit(StatusUpdate(status))
          schedule_poll(State(..state, status:, runtime: PrusaRuntime(client)))
        }
        Ok(#(client, updates)) -> {
          let status = merge_all(state.status, updates)
          state.emit(StatusUpdate(status))
          schedule_poll(State(..state, status:, runtime: PrusaRuntime(client)))
        }
      }
    // Bambu (push) and Moonraker (websocket) have no polling to do.
    BambuRuntime(..) | MoonrakerRuntime(..) -> actor.continue(state)
  }
}

fn schedule_poll(state: State) -> actor.Next(State, Msg) {
  case state.runtime {
    PrusaRuntime(_) -> {
      cancel_timer(state.poll_timer)
      let delay = prusa.poll_interval_ms(is_printing(state.status))
      let timer = process.send_after(state.self, delay, PollTick)
      actor.continue(State(..state, poll_timer: Some(timer)))
    }
    _ -> {
      cancel_timer(state.poll_timer)
      actor.continue(State(..state, poll_timer: None))
    }
  }
}

fn cancel_timer(timer: Option(process.Timer)) -> Nil {
  case timer {
    Some(t) -> {
      let _ = process.cancel_timer(t)
      Nil
    }
    None -> Nil
  }
}

fn is_printing(status: PrinterStatus) -> Bool {
  case status.print {
    Printing -> True
    _ -> False
  }
}

fn fetch_gcode(db: database.Db, file_id: Int) -> Result(BitArray, String) {
  case sql.get_gcode_file(database.connection(db), file_id) {
    Ok(returned) ->
      case returned.rows {
        [row] -> Ok(row.bytes)
        [] -> Error("gcode file not found")
        _ -> Error("unexpected gcode row count")
      }
    Error(e) -> Error(inspect_error(e))
  }
}

fn inspect_error(e: pog.QueryError) -> String {
  case e {
    pog.ConstraintViolated(message, ..) -> message
    pog.PostgresqlError(message:, ..) -> message
    pog.QueryTimeout -> "query timeout"
    pog.ConnectionUnavailable -> "database unavailable"
    _ -> "database error"
  }
}
