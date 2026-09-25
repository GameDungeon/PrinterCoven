import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/io
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import server/database
import server/printer.{
  type CommandError, type PrinterConfig, type PrinterEvent, type PrinterMessage,
  type PrinterStatus, CommandFailed, NotConnected, RejectedByPrinter,
  StatusUpdate, TransportError,
}
import server/printer_actor.{type StartArg, StartArg}
import server/sql

/// Public API of the manager actor: command fan-in, status queries, and
/// status-event subscriptions.
pub type ManagerMessage {
  EventIn(printer_id: String, event: PrinterEvent)
  ForwardCommand(printer_id: String, command: PrinterMessage)
  GetStatus(
    reply: process.Subject(Result(PrinterStatus, String)),
    printer_id: String,
  )
  ListPrinters(reply: process.Subject(List(#(PrinterConfig, PrinterStatus))))
  Subscribe(subscriber: process.Subject(ManagerEvent))
  Unsubscribe(subscriber: process.Subject(ManagerEvent))
}

pub type ManagerEvent {
  ManagerStatus(printer_id: String, status: PrinterStatus)
}

pub type State {
  State(
    db: database.Db,
    configs: List(PrinterConfig),
    actors: Dict(String, printer_actor.Handle),
    latest: Dict(String, PrinterStatus),
    subscribers: List(process.Subject(ManagerEvent)),
  )
}

type FactoryName =
  process.Name(factory_supervisor.Message(StartArg, printer_actor.Handle))

/// Printer actors live under a factory supervisor; the manager actor loads
/// configs and starts one child per printer, then owns the latest-status
/// cache and command fan-in. Factory and manager restart together (OneForAll)
/// so a manager restart never orphans or duplicates children.
pub fn manager_name() -> process.Name(ManagerMessage) {
  process.new_name("printer_manager")
}

pub fn supervised(
  db: database.Db,
  manager_name: process.Name(ManagerMessage),
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  let factory_name = process.new_name("printer_factory")

  let factory =
    factory_supervisor.worker_child(fn(arg: StartArg) {
      printer_actor.start(arg)
    })
    |> factory_supervisor.named(factory_name)
    |> factory_supervisor.restart_strategy(supervision.Transient)
    |> factory_supervisor.supervised

  let manager =
    supervision.worker(fn() { start_manager(db, factory_name, manager_name) })

  static_supervisor.new(static_supervisor.OneForAll)
  |> static_supervisor.add(factory)
  |> static_supervisor.add(manager)
  |> static_supervisor.supervised
}

fn start_manager(
  db: database.Db,
  factory_name: FactoryName,
  manager_name: process.Name(ManagerMessage),
) -> actor.StartResult(Nil) {
  let configs = load_configs_retry(db)
  let factory = factory_supervisor.get_by_name(factory_name)

  let actors =
    list.fold(configs, dict.new(), fn(acc, config) {
      let name = process.new_name("printer_" <> config.id)
      // Actor event sink. The named-send guard keeps a mid-restart gap
      // (manager unregistered) from crashing the printer actor.
      let emit = fn(event: PrinterEvent) {
        case process.named(manager_name) {
          Error(_) -> Nil
          Ok(_) ->
            process.send(
              process.named_subject(manager_name),
              EventIn(config.id, event),
            )
        }
      }
      let arg = StartArg(config:, name:, emit:, db:)
      case factory_supervisor.start_child(factory, arg) {
        Ok(started) -> dict.insert(acc, config.id, started.data)
        Error(e) -> {
          io.println(
            "failed to start printer actor "
            <> config.id
            <> ": "
            <> string.inspect(e),
          )
          acc
        }
      }
    })

  let latest =
    list.fold(configs, dict.new(), fn(acc, config) {
      dict.insert(acc, config.id, printer.initial(config.static_trays))
    })

  let state = State(db:, configs:, actors:, latest:, subscribers: [])

  use started <- result.try(
    actor.new(state)
    |> actor.named(manager_name)
    |> actor.on_message(handle)
    |> actor.start
    |> result.map(fn(s) { actor.Started(pid: s.pid, data: Nil) }),
  )
  Ok(started)
}

fn load_configs_retry(db: database.Db) -> List(printer.PrinterConfig) {
  case load_configs(db) {
    Ok(configs) -> configs
    Error(_) -> {
      io.println("printer manager: failed to load configs, retrying...")
      process.sleep(500)
      load_configs_retry(db)
    }
  }
}

fn load_configs(db: database.Db) -> Result(List(printer.PrinterConfig), Nil) {
  use returned <- result.try(
    sql.list_printers(database.connection(db))
    |> result.replace_error(Nil),
  )
  list.try_map(returned.rows, fn(row) {
    use backend <- result.try(
      json.parse(row.backend, printer.backend_decoder())
      |> result.replace_error(Nil),
    )
    use trays <- result.try(
      json.parse(row.static_trays, printer.trays_decoder())
      |> result.replace_error(Nil),
    )
    Ok(printer.PrinterConfig(
      id: row.id,
      display_name: row.display_name,
      backend:,
      static_trays: trays,
    ))
  })
}

fn handle(
  state: State,
  msg: ManagerMessage,
) -> actor.Next(State, ManagerMessage) {
  case msg {
    EventIn(printer_id, event) -> handle_event(state, printer_id, event)
    ForwardCommand(printer_id, command) -> {
      case dict.get(state.actors, printer_id) {
        Error(_) -> synth_not_connected(state, printer_id, command)
        Ok(handle) ->
          case process.named(handle.name) {
            Error(_) -> synth_not_connected(state, printer_id, command)
            Ok(_) -> {
              process.send(handle.msg, printer_actor.Public(command))
              actor.continue(state)
            }
          }
      }
    }
    GetStatus(reply, printer_id) -> {
      process.send(reply, case dict.get(state.latest, printer_id) {
        Ok(status) -> Ok(status)
        Error(_) -> Error("unknown printer")
      })
      actor.continue(state)
    }
    ListPrinters(reply) -> {
      process.send(
        reply,
        list.map(state.configs, fn(config) {
          let status = case dict.get(state.latest, config.id) {
            Ok(status) -> status
            Error(_) -> printer.initial(config.static_trays)
          }
          #(config, status)
        }),
      )
      actor.continue(state)
    }
    Subscribe(subscriber) ->
      actor.continue(
        State(..state, subscribers: list.prepend(state.subscribers, subscriber)),
      )
    Unsubscribe(subscriber) ->
      actor.continue(
        State(
          ..state,
          subscribers: list.filter(state.subscribers, fn(s) { s != subscriber }),
        ),
      )
  }
}

/// Single fan-in point for printer events (from actors and from the
/// manager's own synthesized failures) so every consumer sees them alike.
fn handle_event(
  state: State,
  printer_id: String,
  event: PrinterEvent,
) -> actor.Next(State, ManagerMessage) {
  let state = case event {
    StatusUpdate(status) -> {
      let latest = dict.insert(state.latest, printer_id, status)
      list.each(state.subscribers, fn(sub) {
        process.send(sub, ManagerStatus(printer_id, status))
      })
      State(..state, latest:)
    }
    CommandFailed(command, error) -> {
      io.println(
        "printer "
        <> printer_id
        <> ": command failed: "
        <> string.inspect(command)
        <> ": "
        <> inspect_command_error(error),
      )
      state
    }
  }
  actor.continue(state)
}

fn inspect_command_error(error: CommandError) -> String {
  case error {
    NotConnected -> "not connected"
    RejectedByPrinter(reason) -> "rejected by printer: " <> reason
    TransportError(reason) -> "transport error: " <> reason
  }
}

/// Spec §4: manager synthesizes CommandFailed so callers always get an answer
/// mid-restart. Delivered through the same event path as actor events.
fn synth_not_connected(
  state: State,
  printer_id: String,
  command: PrinterMessage,
) -> actor.Next(State, ManagerMessage) {
  handle_event(state, printer_id, CommandFailed(command, NotConnected))
}
