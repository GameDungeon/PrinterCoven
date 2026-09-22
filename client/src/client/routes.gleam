import gleam/int
import gleam/uri.{type Uri}
import lustre/attribute.{type Attribute}

pub type Route {
  Dashboard
  JobQueue
  Projects
  ProjectDetail(id: Int)
  Filament
  NotFound(uri: Uri)
}

pub fn parse(uri: Uri) -> Route {
  case uri.path_segments(uri.path) {
    [] | [""] -> Dashboard
    ["jobs"] -> JobQueue
    ["projects"] -> Projects
    ["projects", id_str] -> case int.parse(id_str) {
      Ok(id) -> ProjectDetail(id:)
      Error(_) -> NotFound(uri:)
    }
    ["filament"] -> Filament
    _ -> NotFound(uri:)
  }
}

pub fn href(route: Route) -> Attribute(msg) {
  let url = case route {
    Dashboard -> "/"
    JobQueue -> "/jobs"
    Projects -> "/projects"
    ProjectDetail(id) -> "/projects/" <> int.to_string(id)
    Filament -> "/filament"
    NotFound(_) -> "/404"
  }
  attribute.href(url)
}
