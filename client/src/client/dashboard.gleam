import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

pub fn view() -> Element(msg) {
  html.div([], [
    html.header([attribute.class("mb-8")], [
      html.h1([attribute.class("text-3xl font-bold text-gray-900")], [
        html.text("3D Printers"),
      ]),
      html.p([attribute.class("mt-2 text-gray-600")], [
        html.text("Manage and monitor your fleet of printers."),
      ]),
    ]),
    printer_grid(),
  ])
}

fn printer_grid() -> Element(msg) {
  html.div([attribute.class("grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-6")], [
    printer_box("Printer 1"),
    printer_box("Printer 2"),
    printer_box("Printer 3"),
    printer_box("Printer 4"),
    printer_box("Printer 5"),
    printer_box("Printer 6"),
  ])
}

fn printer_box(name: String) -> Element(msg) {
  html.div(
    [
      attribute.class(
        "border border-gray-200 rounded-lg p-6 bg-white shadow-sm hover:shadow-md transition-shadow",
      ),
    ],
    [
      html.div([attribute.class("flex items-center justify-between mb-4")], [
        html.h2([attribute.class("text-lg font-semibold text-gray-800")], [
          html.text(name),
        ]),
        html.span([attribute.class("px-2 py-1 text-xs font-medium bg-green-100 text-green-800 rounded")], [
          html.text("Idle"),
        ]),
      ]),
      html.div([attribute.class("text-sm text-gray-500")], [
        html.p([], [html.text("Status: Waiting for job")]),
      ]),
    ],
  )
}
