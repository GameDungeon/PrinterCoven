import gleam/http.{Get}
import wisp.{type Request, type Response}

pub fn page(req: Request) -> Response {
  use <- wisp.require_method(req, Get)

  wisp.ok()
  |> wisp.html_body("Hello World!")
}
