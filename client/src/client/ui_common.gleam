import client/routes
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

pub fn view(content: fn() -> Element(msg), current_route: routes.Route) -> Element(msg) {
  html.div([attribute.class("flex h-screen")], [
    sidebar(current_route),
    html.main([attribute.class("flex-1 overflow-y-auto p-8")], [content()]),
  ])
}

fn sidebar(current_route: routes.Route) -> Element(msg) {
  html.nav(
    [
      attribute.class(
        "flex flex-col w-64 h-full bg-gray-900 text-gray-100 px-4 py-6",
      ),
    ],
    [
      html.h1([attribute.class("text-xl font-bold mb-8 px-2")], [
        html.text("Printer Coven"),
      ]),
      html.ul([attribute.class("flex flex-col gap-1")], [
        nav_link("Dashboard", routes.Dashboard, current_route),
      ]),
    ],
  )
}

fn nav_link(
  label: String,
  route: routes.Route,
  current_route: routes.Route,
) -> Element(msg) {
  let is_active = route == current_route
  let base_classes = "block px-3 py-2 rounded-md text-sm font-medium"
  let active_classes = case is_active {
    True -> " bg-gray-700 text-white"
    False -> " text-gray-300 hover:bg-gray-800 hover:text-white"
  }

  html.a(
    [
      routes.href(route),
      attribute.class(base_classes <> active_classes),
    ],
    [html.text(label)],
  )
}
