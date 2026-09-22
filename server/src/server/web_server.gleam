import envoy
import gleam/http/request
import gleam/http/response
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import mist.{type Connection, type ResponseData}
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
  let assert Ok(priv_directory) = wisp.priv_directory("examples")
  let static_directory = priv_directory <> "/static"

  let ctx = Context(static_directory:)

  let handler = handle_request(_, ctx)

  wisp_mist.handler(handler, wisp_secret)
}

fn handle_request(req: Request, ctx: Context) -> Response {
  use req <- middleware(req, ctx)

  case wisp.path_segments(req) {
    // This matches `/`
    [] -> wisp.not_found()

    // This matches all other paths
    _ -> wisp.not_found()
  }
}
