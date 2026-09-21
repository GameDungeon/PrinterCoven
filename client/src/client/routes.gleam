import gleam/uri.{type Uri}
import lustre/attribute.{type Attribute}

pub type Route {
  Dashboard
  NotFound(uri: Uri)
}

pub fn parse(uri: Uri) -> Route {
  case uri.path_segments(uri.path) {
    [] | [""] -> Dashboard
    _ -> NotFound(uri:)
  }
}

pub fn href(route: Route) -> Attribute(msg) {
  let url = case route {
    Dashboard -> "/"
    NotFound(_) -> "/404"
  }
  attribute.href(url)
}
