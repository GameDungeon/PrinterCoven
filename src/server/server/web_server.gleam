import gleam/otp/static_supervisor
import gleam/otp/supervision
import mist
import printer_coven/web_app/dashboard
import wisp.{type Request, type Response}
import wisp/wisp_mist

pub fn supervised(
  secret_key_base: String,
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  wisp_mist.handler(handle_request, secret_key_base)
  |> mist.new
  |> mist.port(8000)
  |> mist.supervised
}

pub fn middleware(
  req: wisp.Request,
  handle_request: fn(wisp.Request) -> wisp.Response,
) -> wisp.Response {
  let req = wisp.method_override(req)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)
  use req <- wisp.csrf_known_header_protection(req)

  handle_request(req)
}

fn handle_request(req: Request) -> Response {
  use req <- middleware(req)

  case wisp.path_segments(req) {
    // This matches `/`
    [] -> dashboard.page(req)

    // This matches all other paths
    _ -> wisp.not_found()
  }
}
