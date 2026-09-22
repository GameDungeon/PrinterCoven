import client/routes
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

pub fn view(content: fn() -> Element(msg), current_route: routes.Route) -> Element(msg) {
  html.div([attribute.class("flex h-screen bg-gray-900")], [
    sidebar(current_route),
    html.main([attribute.class("flex-1 overflow-y-auto p-8")], [content()]),
  ])
}

fn sidebar(current_route: routes.Route) -> Element(msg) {
  html.nav(
    [
      attribute.class(
        "flex flex-col w-64 h-full bg-gray-800 text-gray-100 px-4 py-6 border-r border-gray-700",
      ),
    ],
    [
      html.h1([attribute.class("text-xl font-bold mb-8 px-2 text-gold")], [
        html.text("Printer Coven"),
      ]),
      html.ul([attribute.class("flex flex-col gap-1")], [
        nav_link("Dashboard", routes.Dashboard, current_route),
        nav_link("Job Queue", routes.JobQueue, current_route),
        nav_link("Projects", routes.Projects, current_route),
        nav_link("Filament", routes.Filament, current_route),
      ]),
    ],
  )
}

fn nav_link(
  label: String,
  route: routes.Route,
  current_route: routes.Route,
) -> Element(msg) {
  let is_active = case route, current_route {
    routes.Projects, routes.ProjectDetail(_) -> True
    a, b -> a == b
  }
  let base_classes = "block px-3 py-2 rounded-md text-sm font-medium"
  let active_classes = case is_active {
    True -> " bg-gray-700 text-sage"
    False -> " text-gray-300 hover:bg-gray-700/50 hover:text-gray-100"
  }

  html.a(
    [
      routes.href(route),
      attribute.class(base_classes <> active_classes),
    ],
    [html.text(label)],
  )
}

// ---------------------------------------------------------------------------
// Page header
// ---------------------------------------------------------------------------

pub fn page_header(title: String, description: String) -> Element(msg) {
  html.header([attribute.class("mb-8")], [
    html.h1([attribute.class("text-3xl font-bold text-gold")], [
      html.text(title),
    ]),
    html.p([attribute.class("mt-2 text-gray-400")], [
      html.text(description),
    ]),
  ])
}

// ---------------------------------------------------------------------------
// Card
// ---------------------------------------------------------------------------

pub fn card(children: List(Element(msg))) -> Element(msg) {
  html.div(
    [
      attribute.class(
        "border border-gray-700 rounded-lg p-6 bg-gray-800 shadow-sm hover:shadow-md transition-shadow",
      ),
    ],
    children,
  )
}

// ---------------------------------------------------------------------------
// Badge
// ---------------------------------------------------------------------------

pub fn badge(label: String, color: String) -> Element(msg) {
  let color_classes = case color {
    "blue" -> "bg-blue-500/20 text-blue-300 border border-blue-500/30"
    "green" -> "bg-sage/20 text-sage border border-sage/30"
    "yellow" -> "bg-amber-500/20 text-amber-300 border border-amber-500/30"
    "red" -> "bg-red-500/20 text-red-300 border border-red-500/30"
    "gray" -> "bg-gray-600 text-gray-200 border border-gray-500"
    _ -> "bg-gray-600 text-gray-200 border border-gray-500"
  }

  html.span(
    [attribute.class("px-2 py-1 text-xs font-medium rounded " <> color_classes)],
    [html.text(label)],
  )
}

// ---------------------------------------------------------------------------
// Table
// ---------------------------------------------------------------------------

pub fn table_wrapper(children: List(Element(msg))) -> Element(msg) {
  html.div(
    [attribute.class("bg-gray-800 border border-gray-700 rounded-lg shadow-sm overflow-hidden")],
    children,
  )
}

pub fn table_header(label: String) -> Element(msg) {
  html.th(
    [attribute.class("px-6 py-3 text-xs font-medium text-gray-400 uppercase tracking-wider")],
    [html.text(label)],
  )
}

pub fn table_body(rows: List(Element(msg))) -> Element(msg) {
  html.tbody([attribute.class("divide-y divide-gray-700")], rows)
}

pub fn table_row(cells: List(Element(msg))) -> Element(msg) {
  html.tr([attribute.class("hover:bg-gray-700/50")], cells)
}

pub fn table_cell(children: List(Element(msg))) -> Element(msg) {
  html.td(
    [attribute.class("px-6 py-4 whitespace-nowrap text-sm text-gray-300")],
    children,
  )
}

pub fn table_cell_primary(children: List(Element(msg))) -> Element(msg) {
  html.td(
    [attribute.class("px-6 py-4 whitespace-nowrap text-sm font-medium text-gray-100")],
    children,
  )
}

pub fn table_cell_muted(children: List(Element(msg))) -> Element(msg) {
  html.td(
    [attribute.class("px-6 py-4 whitespace-nowrap text-sm text-gray-400")],
    children,
  )
}

pub fn table_cell_nopad(children: List(Element(msg))) -> Element(msg) {
  html.td(
    [attribute.class("px-6 py-4 whitespace-nowrap")],
    children,
  )
}

pub fn table_full() -> Attribute(msg) {
  attribute.class("w-full text-left")
}

pub fn table_head(children: List(Element(msg))) -> Element(msg) {
  html.thead([attribute.class("bg-gray-700/60 border-b border-gray-700")], children)
}

// ---------------------------------------------------------------------------
// Int to string
// ---------------------------------------------------------------------------

pub fn int_to_string(n: Int) -> String {
  case n {
    0 -> "0"
    _ -> do_int_to_string(n, "")
  }
}

fn do_int_to_string(n: Int, acc: String) -> String {
  case n <= 0 {
    True -> acc
    False -> do_int_to_string(n / 10, int_digit_char(n % 10) <> acc)
  }
}

fn int_digit_char(d: Int) -> String {
  case d {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    5 -> "5"
    6 -> "6"
    7 -> "7"
    8 -> "8"
    9 -> "9"
    _ -> ""
  }
}
