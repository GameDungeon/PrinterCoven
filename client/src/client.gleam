import client/dashboard
import client/filament
import client/job_queue
import client/projects
import client/routes
import client/ui_common
import gleam/json
import gleam/result
import lustre
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import modem
import plinth/browser/document
import plinth/browser/element as plinth_element

type Model {
  Model(route: routes.Route)
}

type Message {
  UserNavigatedTo(route: routes.Route)
}

pub fn main() -> Nil {
  let initial_route =
    document.query_selector("#model")
    |> result.map(plinth_element.inner_text)
    |> result.try(fn(json_str) {
      json.parse(json_str, routes.route_decoder())
      |> result.replace_error(Nil)
    })
    |> result.unwrap(routes.Dashboard)

  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", initial_route)

  Nil
}

fn init(route: routes.Route) -> #(Model, Effect(Message)) {
  let model = Model(route:)

  let effect =
    modem.init(fn(uri) {
      uri
      |> routes.parse
      |> UserNavigatedTo
    })

  #(model, effect)
}

fn view(model: Model) -> Element(Message) {
  use <- with_layout(model.route)

  case model.route {
    routes.NotFound(_) -> html.div([], [html.text("404 Not Found")])
    routes.Dashboard -> dashboard.view()
    routes.JobQueue -> job_queue.view()
    routes.Projects -> projects.view()
    routes.ProjectDetail(id) -> projects.view_project(id)
    routes.Filament -> filament.view()
  }
}

fn with_layout(route: routes.Route, content: fn() -> Element(msg)) -> Element(msg) {
  case route {
    routes.NotFound(_) -> content()
    _ -> ui_common.view(content, route)
  }
}

fn update(_model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    UserNavigatedTo(route:) -> #(Model(route:), effect.none())
  }
}
