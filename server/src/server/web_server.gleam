import client/dashboard
import client/filament
import client/job_queue
import client/projects
import client/routes
import client/ui_common
import envoy
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/otp/static_supervisor
import gleam/otp/supervision
import lustre/attribute
import lustre/element
import lustre/element/html
import mist
import wisp.{type Request, type Response}
import wisp/wisp_mist

pub type Context {
  Context(static_directory: String)
}

pub fn supervised() -> supervision.ChildSpecification(
  static_supervisor.Supervisor,
) {
  let wisp_secret = case envoy.get("WISP_SECRET") {
    Ok(key) -> key

    // TODO: Add logging for this
    Error(_) -> wisp.random_string(64)
  }

  get_handler(wisp_secret)
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
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  let assert Ok(priv_directory) = wisp.priv_directory("server")
  let static_directory = priv_directory <> "/static"

  let ctx = Context(static_directory:)

  let handler = handle_request(_, ctx)

  wisp_mist.handler(handler, wisp_secret)
}

fn handle_request(req: Request, ctx: Context) -> Response {
  use req <- middleware(req, ctx)

  case wisp.path_segments(req) {
    [] -> serve_page(routes.Dashboard)
    ["jobs"] -> serve_page(routes.JobQueue)
    ["projects"] -> serve_page(routes.Projects)
    ["projects", id_str] -> case int.parse(id_str) {
      Ok(id) -> serve_page(routes.ProjectDetail(id:))
      Error(_) -> serve_page(routes.NotFound(uri: request.to_uri(req)))
    }
    ["filament"] -> serve_page(routes.Filament)
    _ -> serve_page(routes.NotFound(uri: request.to_uri(req)))
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
        html.link([attribute.rel("stylesheet"), attribute.href("/static/client.css")]),
        html.script(
          [attribute.type_("module"), attribute.src("/static/client.js")],
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
