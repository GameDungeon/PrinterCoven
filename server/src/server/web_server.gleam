import client/dashboard
import client/filament
import client/job_queue
import client/projects
import client/routes
import client/ui_common
import envoy
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/application
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/io
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor
import gleam/otp/supervision
import lustre
import lustre/attribute
import lustre/element
import lustre/element/html
import lustre/server_component
import mist
import server/dashboard_component
import server/printer.{
  type ConnectionState, type Fault, type FaultSeverity, type PrintState,
  type PrinterMessage, type PrinterStatus, type ProgressInfo, type Slot,
  type Temperature, type Tray, CancelPrint, Cancelled, Complete, Connected,
  Connecting, Critical, Disconnected, Errored, Idle, NeedsAttention, PausePrint,
  Paused, Printing, ResumePrint, StartPrint, Warning,
}
import server/printer_manager.{
  type ManagerEvent, type ManagerMessage, ForwardCommand, GetStatus,
  ListPrinters, ManagerStatus, Subscribe, Unsubscribe,
}
import wisp.{type Request, type Response}
import wisp/wisp_mist

pub type Context {
  Context(static_directory: String, manager: process.Name(ManagerMessage))
}

// ---------------------------------------------------------------------------
// Printer status JSON (API wire format; see docs/development.md)
// ---------------------------------------------------------------------------

fn connection_encoder(connection: ConnectionState) -> json.Json {
  case connection {
    Connected -> json.object([#("state", json.string("connected"))])
    Connecting -> json.object([#("state", json.string("connecting"))])
    Disconnected(reason) ->
      json.object([
        #("state", json.string("disconnected")),
        #("reason", json.string(reason)),
      ])
  }
}

fn print_state_encoder(state: PrintState) -> json.Json {
  let name = case state {
    Idle -> "idle"
    Printing -> "printing"
    Paused -> "paused"
    NeedsAttention -> "needs_attention"
    Complete -> "complete"
    Cancelled -> "cancelled"
    Errored -> "errored"
  }
  json.string(name)
}

fn fault_severity_encoder(severity: FaultSeverity) -> json.Json {
  case severity {
    Warning -> json.string("warning")
    Critical -> json.string("error")
  }
}

fn fault_encoder(fault: Fault) -> json.Json {
  json.object([
    #("code", json.string(fault.code)),
    #("message", json.string(fault.message)),
    #("severity", fault_severity_encoder(fault.severity)),
  ])
}

fn progress_encoder(progress: ProgressInfo) -> json.Json {
  json.object([
    #("percent", json.float(progress.percent)),
    #(
      "time_remaining_seconds",
      json.nullable(progress.time_remaining_seconds, json.int),
    ),
  ])
}

fn temperature_encoder(temp: Temperature) -> json.Json {
  json.object([
    #("name", json.string(temp.name)),
    #("current", json.float(temp.current)),
    #("target", json.float(temp.target)),
  ])
}

fn slot_encoder(slot: Slot) -> json.Json {
  json.object([
    #("index", json.int(slot.index)),
    #("material", json.nullable(slot.material, json.string)),
    #("color", json.nullable(slot.color, json.string)),
    #("remaining_percent", json.nullable(slot.remaining_percent, json.float)),
  ])
}

fn tray_encoder(tray: Tray) -> json.Json {
  json.object([
    #("index", json.int(tray.index)),
    #("slots", json.array(tray.slots, slot_encoder)),
  ])
}

fn status_encoder(status: PrinterStatus) -> json.Json {
  json.object([
    #("connection", connection_encoder(status.connection)),
    #("print", print_state_encoder(status.print)),
    #("progress", json.nullable(status.progress, progress_encoder)),
    #("temperatures", json.array(status.temperatures, temperature_encoder)),
    #("trays", json.array(status.trays, tray_encoder)),
    #("faults", json.array(status.faults, fault_encoder)),
  ])
}

pub fn supervised(
  manager: process.Name(ManagerMessage),
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  let wisp_secret = case envoy.get("WISP_SECRET") {
    Ok(key) -> key
    Error(_) -> {
      // Random-per-boot secret invalidates sessions/CSRF on every restart.
      io.println(
        "WARNING: WISP_SECRET not set; using a random secret for this boot only",
      )
      wisp.random_string(64)
    }
  }

  get_handler(wisp_secret, manager)
  |> mist.new
  |> mist.port(8000)
  |> mist.supervised
}

pub fn middleware(
  req: wisp.Request,
  ctx: Context,
  handle_request: fn(wisp.Request) -> wisp.Response,
) -> wisp.Response {
  let req = wisp.method_override(req)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)
  use req <- wisp.csrf_known_header_protection(req)
  use <- wisp.serve_static(req, "/static", ctx.static_directory)

  handle_request(req)
}

fn get_handler(
  wisp_secret: String,
  manager: process.Name(ManagerMessage),
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  let assert Ok(priv_directory) = wisp.priv_directory("server")
  let static_directory = priv_directory <> "/static"

  let ctx = Context(static_directory:, manager:)

  let wisp_handler = wisp_mist.handler(handle_request(_, ctx), wisp_secret)

  // Routes that need raw mist (WebSocket upgrade, file serving) are handled
  // before the wisp middleware stack; everything else goes through wisp.
  fn(req: request.Request(mist.Connection)) -> response.Response(
    mist.ResponseData,
  ) {
    case request.path_segments(req) {
      ["api", "printers", "ws"] -> handle_printer_ws(req, ctx)
      ["vendor", "lustre-runtime.mjs"] -> serve_lustre_runtime()
      _ -> wisp_handler(req)
    }
  }
}

fn handle_request(req: Request, ctx: Context) -> Response {
  use req <- middleware(req, ctx)

  case wisp.path_segments(req) {
    [] -> serve_page(routes.Dashboard)
    ["jobs"] -> serve_page(routes.JobQueue)
    ["projects"] -> serve_page(routes.Projects)
    ["projects", id_str] ->
      case int.parse(id_str) {
        Ok(id) -> serve_page(routes.ProjectDetail(id:))
        Error(_) -> serve_page(routes.NotFound(uri: request.to_uri(req)))
      }
    ["filament"] -> serve_page(routes.Filament)
    ["api", "printers"] -> handle_printers_api(req, ctx)
    ["api", "printers", id, ..rest] -> handle_printer_api(req, ctx, id, rest)
    _ -> serve_page(routes.NotFound(uri: request.to_uri(req)))
  }
}

fn handle_printers_api(req: Request, ctx: Context) -> Response {
  case req.method {
    http.Get -> {
      let reply = process.new_subject()
      process.send(process.named_subject(ctx.manager), ListPrinters(reply))
      case process.receive(reply, 500) {
        Ok(printers) ->
          json.array(printers, fn(entry) {
            json.object([
              #("id", json.string(entry.0.id)),
              #("status", status_encoder(entry.1)),
            ])
          })
          |> json.to_string
          |> wisp.json_response(200)
        Error(_) -> wisp.internal_server_error()
      }
    }
    _ -> wisp.method_not_allowed([http.Get])
  }
}

fn handle_printer_api(
  req: Request,
  ctx: Context,
  id: String,
  rest: List(String),
) -> Response {
  case rest, req.method {
    [], http.Get -> handle_get_printer(ctx, id)
    [], http.Post -> handle_printer_command(req, ctx, id)
    ["events"], http.Get -> handle_printer_events(ctx, id)
    _, _ -> wisp.method_not_allowed([http.Get, http.Post])
  }
}

fn handle_get_printer(ctx: Context, id: String) -> Response {
  let reply = process.new_subject()
  process.send(process.named_subject(ctx.manager), GetStatus(reply, id))
  case process.receive(reply, 500) {
    Ok(Ok(status)) ->
      json.object([
        #("id", json.string(id)),
        #("status", status_encoder(status)),
      ])
      |> json.to_string
      |> wisp.json_response(200)
    Ok(Error(_)) -> wisp.not_found()
    Error(_) -> wisp.internal_server_error()
  }
}

fn handle_printer_command(req: Request, ctx: Context, id: String) -> Response {
  use body <- wisp.require_string_body(req)
  case json.parse(body, command_decoder()) {
    Ok(command) -> {
      process.send(
        process.named_subject(ctx.manager),
        ForwardCommand(id, command),
      )
      json.object([#("ok", json.bool(True))])
      |> json.to_string
      |> wisp.json_response(202)
    }
    Error(_) -> wisp.bad_request("invalid command body")
  }
}

fn command_decoder() -> decode.Decoder(PrinterMessage) {
  use action <- decode.field("action", decode.string)
  case action {
    "start" -> {
      use file_id <- decode.field("file_id", decode.int)
      decode.success(StartPrint(file_id))
    }
    "pause" -> decode.success(PausePrint)
    "resume" -> decode.success(ResumePrint)
    "cancel" -> decode.success(CancelPrint)
    _ -> decode.failure(PausePrint, "action")
  }
}

fn handle_printer_events(ctx: Context, id: String) -> Response {
  let subscriber = process.new_subject()
  process.send(process.named_subject(ctx.manager), Subscribe(subscriber))
  sse_loop(subscriber, ctx, id)
}

fn sse_loop(
  subscriber: process.Subject(ManagerEvent),
  ctx: Context,
  id: String,
) -> Response {
  case process.receive(subscriber, 30_000) {
    Ok(ManagerStatus(printer_id, status)) if printer_id == id -> {
      let payload =
        json.object([
          #("id", json.string(printer_id)),
          #("status", status_encoder(status)),
        ])
        |> json.to_string
      // Single-event first cut; true long-lived SSE stream is a follow-up.
      process.send(process.named_subject(ctx.manager), Unsubscribe(subscriber))
      wisp.response(200)
      |> wisp.set_header("content-type", "text/event-stream")
      |> wisp.set_header("cache-control", "no-cache")
      |> wisp.set_body(wisp.Text("event: status\ndata: " <> payload <> "\n\n"))
    }
    Ok(_) -> sse_loop(subscriber, ctx, id)
    Error(_) -> {
      process.send(process.named_subject(ctx.manager), Unsubscribe(subscriber))
      wisp.internal_server_error()
    }
  }
}

// ---------------------------------------------------------------------------
// Dashboard server component transport
// ---------------------------------------------------------------------------

/// Messages flowing into the WebSocket process: patches from the component
/// runtime to forward to the browser, and status fan-out from the manager
/// to dispatch into the component.
type SocketMessage {
  FromRuntime(server_component.ClientMessage(dashboard_component.Message))
  FromManager(ManagerEvent)
}

type Socket {
  Socket(
    component: lustre.Runtime(dashboard_component.Message),
    manager: process.Name(ManagerMessage),
    manager_sub: process.Subject(ManagerEvent),
  )
}

/// One component runtime per connection: `on_init` starts it and subscribes
/// to the manager, `on_close` tears both down.
fn handle_printer_ws(
  req: request.Request(mist.Connection),
  ctx: Context,
) -> response.Response(mist.ResponseData) {
  mist.websocket(
    request: req,
    on_init: fn(_conn) { init_socket(ctx.manager) },
    handler: loop_socket,
    on_close: close_socket,
  )
}

fn init_socket(
  manager: process.Name(ManagerMessage),
) -> #(Socket, Option(process.Selector(SocketMessage))) {
  let assert Ok(component) =
    lustre.start_server_component(dashboard_component.app(), Nil)

  // Outbound patches from the component runtime arrive on this subject.
  let runtime_out = process.new_subject()
  // Status events from the manager arrive on this subject.
  let manager_sub = process.new_subject()

  server_component.register_subject(runtime_out)
  |> lustre.send(to: component)

  process.send(process.named_subject(manager), Subscribe(manager_sub))

  // Initial snapshot. Both this reply and later manager events are forwarded
  // from this process, so the snapshot is always dispatched first.
  let reply = process.new_subject()
  process.send(process.named_subject(manager), ListPrinters(reply))
  let printers = case process.receive(reply, 500) {
    Ok(printers) -> printers
    Error(_) -> []
  }
  lustre.send(
    component,
    lustre.dispatch(dashboard_component.PrintersLoaded(printers)),
  )

  let selector =
    process.new_selector()
    |> process.select_map(runtime_out, fn(msg) { FromRuntime(msg) })
    |> process.select_map(manager_sub, fn(msg) { FromManager(msg) })

  #(Socket(component:, manager:, manager_sub:), Some(selector))
}

fn loop_socket(
  state: Socket,
  message: mist.WebsocketMessage(SocketMessage),
  connection: mist.WebsocketConnection,
) -> mist.Next(Socket, SocketMessage) {
  case message {
    mist.Text(payload) -> {
      case json.parse(payload, server_component.runtime_message_decoder()) {
        Ok(runtime_message) -> lustre.send(state.component, runtime_message)
        Error(_) -> Nil
      }
      mist.continue(state)
    }
    mist.Binary(_) -> mist.continue(state)
    mist.Custom(FromRuntime(client_message)) -> {
      let payload = server_component.client_message_to_json(client_message)
      let assert Ok(_) =
        mist.send_text_frame(connection, json.to_string(payload))
      mist.continue(state)
    }
    mist.Custom(FromManager(ManagerStatus(printer_id:, status:))) -> {
      lustre.send(
        state.component,
        lustre.dispatch(dashboard_component.PrinterUpdated(printer_id:, status:)),
      )
      mist.continue(state)
    }
    mist.Closed | mist.Shutdown -> mist.stop()
  }
}

fn close_socket(state: Socket) -> Nil {
  // Shut the runtime down or it leaks; drop the manager subscription too.
  lustre.shutdown()
  |> lustre.send(to: state.component)
  process.send(
    process.named_subject(state.manager),
    Unsubscribe(state.manager_sub),
  )
}

/// Serve the pre-built Lustre server-component client runtime (registers the
/// `<lustre-server-component>` custom element used by the dashboard).
fn serve_lustre_runtime() -> response.Response(mist.ResponseData) {
  let assert Ok(lustre_priv) = application.priv_directory("lustre")
  let path = lustre_priv <> "/static/lustre-server-component.min.mjs"
  case mist.send_file(path, offset: 0, limit: None) {
    Ok(file) ->
      response.new(200)
      |> response.prepend_header("content-type", "application/javascript")
      |> response.set_body(file)
    Error(_) ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

fn serve_page(route: routes.Route) -> Response {
  let content = fn() {
    case route {
      routes.NotFound(_) -> html.div([], [html.text("404 Not Found")])
      routes.Dashboard -> dashboard.view()
      routes.JobQueue -> job_queue.view()
      routes.Projects -> projects.view()
      routes.ProjectDetail(id) -> projects.view_project(id)
      routes.Filament -> filament.view()
    }
  }

  let page = case route {
    routes.NotFound(_) -> content()
    _ -> ui_common.view(content, route)
  }

  let route_json = json.to_string(routes.route_encoder(route))
  let status = case route {
    routes.NotFound(_) -> 404
    _ -> 200
  }

  let html_content =
    html.html([], [
      html.head([], [
        html.title([], "Printer Coven"),
        html.link([
          attribute.rel("stylesheet"),
          attribute.href("/static/client.css"),
        ]),
        html.script(
          [attribute.type_("module"), attribute.src("/static/client.js")],
          "",
        ),
        html.script(
          [
            attribute.type_("module"),
            attribute.src("/vendor/lustre-runtime.mjs"),
          ],
          "",
        ),
        html.script(
          [attribute.type_("application/json"), attribute.id("model")],
          route_json,
        ),
      ]),
      html.body([], [
        html.div([attribute.id("app")], [page]),
      ]),
    ])

  html_content
  |> element.to_document_string
  |> wisp.html_response(status)
}
