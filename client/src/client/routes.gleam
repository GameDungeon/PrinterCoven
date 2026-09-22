import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option
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

pub fn route_encoder(route: Route) -> json.Json {
  case route {
    Dashboard -> json.object([#("variant", json.string("Dashboard"))])
    JobQueue -> json.object([#("variant", json.string("JobQueue"))])
    Projects -> json.object([#("variant", json.string("Projects"))])
    ProjectDetail(id) ->
      json.object([
        #("variant", json.string("ProjectDetail")),
        #("id", json.int(id)),
      ])
    Filament -> json.object([#("variant", json.string("Filament"))])
    NotFound(_) -> json.object([#("variant", json.string("NotFound"))])
  }
}

pub fn route_decoder() -> decode.Decoder(Route) {
  use variant <- decode.field("variant", decode.string)
  case variant {
    "Dashboard" -> decode.success(Dashboard)
    "JobQueue" -> decode.success(JobQueue)
    "Projects" -> decode.success(Projects)
    "Filament" -> decode.success(Filament)
    "NotFound" -> decode.success(NotFound(uri: uri.Uri(
      scheme: option.None,
      userinfo: option.None,
      host: option.None,
      port: option.None,
      path: "",
      query: option.None,
      fragment: option.None,
    )))
    "ProjectDetail" -> {
      use id <- decode.field("id", decode.int)
      decode.success(ProjectDetail(id:))
    }
    _ -> decode.failure(Dashboard, "Route")
  }
}
