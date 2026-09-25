//// The dashboard's live printer grid, running as a Lustre server component.
////
//// A component runtime is started per WebSocket connection (see
//// `web_server.handle_printer_ws`), which pushes the initial snapshot and
//// subsequent status updates into this app. The view reuses the shared
//// presentational markup from `client/dashboard`.

import client/dashboard
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import server/printer.{
  type BackendConfig, type PrintState, type PrinterConfig, type PrinterStatus,
  type Temperature, Bambu, Cancelled, Complete, Disconnected, Errored, Idle,
  Moonraker, NeedsAttention, Paused, Printing, ProgressInfo, PrusaLink,
  Temperature,
}

pub type Message {
  PrintersLoaded(printers: List(#(PrinterConfig, PrinterStatus)))
  PrinterUpdated(printer_id: String, status: PrinterStatus)
}

type Model =
  Dict(String, #(PrinterConfig, PrinterStatus))

pub fn app() -> lustre.App(Nil, Model, Message) {
  lustre.component(init, update, view, [])
}

fn init(_) -> #(Model, Effect(Message)) {
  #(dict.new(), effect.none())
}

fn update(model: Model, msg: Message) -> #(Model, Effect(Message)) {
  case msg {
    PrintersLoaded(printers) -> {
      let model =
        list.fold(printers, dict.new(), fn(acc, entry) {
          dict.insert(acc, entry.0.id, entry)
        })
      #(model, effect.none())
    }
    PrinterUpdated(printer_id:, status:) -> {
      let model = case dict.get(model, printer_id) {
        Ok(#(config, _)) -> dict.insert(model, printer_id, #(config, status))
        // Not in our config list; the next snapshot will include it.
        Error(_) -> model
      }
      #(model, effect.none())
    }
  }
}

fn view(model: Model) -> Element(Message) {
  html.div(
    [attribute.class("grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-6")],
    list.map(sorted(model), fn(entry) {
      let config = entry.0
      let status = entry.1
      dashboard.printer_box(
        name: config.display_name,
        model: backend_label(config.backend),
        status: status_label(status),
        job: "—",
        progress: progress_percent(status),
        nozzle_temp: temp_label(status.temperatures, "nozzle"),
        bed_temp: temp_label(status.temperatures, "bed"),
      )
    }),
  )
}

fn sorted(model: Model) -> List(#(PrinterConfig, PrinterStatus)) {
  dict.values(model)
  |> list.sort(by: fn(a, b) {
    string.compare(a.0.display_name, b.0.display_name)
  })
}

/// A printer that is idle with no connection is offline rather than ready.
fn status_label(status: PrinterStatus) -> String {
  case status.connection, status.print {
    Disconnected(_), Idle -> "Offline"
    _, state -> print_label(state)
  }
}

fn print_label(state: PrintState) -> String {
  case state {
    Idle -> "Idle"
    Printing -> "Printing"
    Paused -> "Paused"
    NeedsAttention -> "Needs attention"
    Complete -> "Complete"
    Cancelled -> "Cancelled"
    Errored -> "Errored"
  }
}

fn backend_label(backend: BackendConfig) -> String {
  case backend {
    Bambu(..) -> "Bambu Lab"
    PrusaLink(..) -> "Prusa"
    Moonraker(..) -> "Moonraker"
  }
}

fn progress_percent(status: PrinterStatus) -> Int {
  case status.progress {
    Some(ProgressInfo(percent:, ..)) -> float.round(percent)
    None -> 0
  }
}

fn temp_label(temperatures: List(Temperature), name: String) -> String {
  case list.find(temperatures, fn(temp) { temp.name == name }) {
    Ok(Temperature(current:, ..)) -> int.to_string(float.round(current)) <> "°C"
    Error(_) -> "—"
  }
}
