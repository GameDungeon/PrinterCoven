import client/dashboard
import client/routes
import client/ui_common
import lustre
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import modem

type Model {
  Model(route: routes.Route)
}

type Message {
  UserNavigatedTo(route: routes.Route)
}

pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)

  Nil
}

fn init(_args) -> #(Model, Effect(Message)) {
  let route = case modem.initial_uri() {
    Ok(uri) -> routes.parse(uri)
    Error(_) -> routes.Dashboard
  }

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
