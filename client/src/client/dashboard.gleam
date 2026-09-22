import client/ui_common
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

pub fn view() -> Element(msg) {
  html.div([], [
    ui_common.page_header("3D Printers", "Manage and monitor your fleet of printers."),
    printer_grid(),
  ])
}

fn printer_grid() -> Element(msg) {
  html.div([attribute.class("grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-6")], [
    printer_box(
      name: "Printer 1",
      model: "Bambu Lab X1C",
      status: "Printing",
      job: "Bracket_V3.stl",
      progress: 67,
      nozzle_temp: "215°C",
      bed_temp: "60°C",
    ),
    printer_box(
      name: "Printer 2",
      model: "Bambu Lab P1S",
      status: "Idle",
      job: "",
      progress: 0,
      nozzle_temp: "25°C",
      bed_temp: "24°C",
    ),
    printer_box(
      name: "Printer 3",
      model: "Ender 3 V3",
      status: "Printing",
      job: "Housing_Lid.stl",
      progress: 23,
      nozzle_temp: "205°C",
      bed_temp: "55°C",
    ),
    printer_box(
      name: "Printer 4",
      model: "Prusa MK4S",
      status: "Idle",
      job: "",
      progress: 0,
      nozzle_temp: "22°C",
      bed_temp: "23°C",
    ),
    printer_box(
      name: "Printer 5",
      model: "Bambu Lab A1",
      status: "Printing",
      job: "Gear_Assembly.stl",
      progress: 91,
      nozzle_temp: "220°C",
      bed_temp: "65°C",
    ),
    printer_box(
      name: "Printer 6",
      model: "Elegoo Neptune 4",
      status: "Idle",
      job: "",
      progress: 0,
      nozzle_temp: "24°C",
      bed_temp: "24°C",
    ),
  ])
}

fn printer_box(
  name name: String,
  model model: String,
  status status: String,
  job job: String,
  progress progress: Int,
  nozzle_temp nozzle_temp: String,
  bed_temp bed_temp: String,
) -> Element(msg) {
  let is_printing = status == "Printing"
  let badge_color = case is_printing {
    True -> "blue"
    False -> "green"
  }

  ui_common.card([
    html.div([attribute.class("flex items-center justify-between mb-1")], [
      html.h2([attribute.class("text-lg font-semibold text-gray-100")], [
        html.text(name),
      ]),
      ui_common.badge(status, badge_color),
    ]),
    html.p([attribute.class("text-xs text-gray-400 mb-4")], [html.text(model)]),
    job_section(is_printing, job, progress),
    html.div([attribute.class("flex gap-4 text-sm text-gray-400 border-t border-gray-700 pt-3")], [
      html.div([], [
        html.span([attribute.class("text-gray-400")], [html.text("Nozzle: ")]),
        html.span([attribute.class("font-medium text-gray-200")], [html.text(nozzle_temp)]),
      ]),
      html.div([], [
        html.span([attribute.class("text-gray-400")], [html.text("Bed: ")]),
        html.span([attribute.class("font-medium text-gray-200")], [html.text(bed_temp)]),
      ]),
    ]),
  ])
}

fn job_section(is_printing: Bool, job: String, progress: Int) -> Element(msg) {
  case is_printing {
    True ->
      html.div([attribute.class("mb-4")], [
        html.p([attribute.class("text-sm text-gray-300 mb-1")], [
          html.text("Printing: "),
          html.span([attribute.class("font-medium text-gold")], [html.text(job)]),
        ]),
        html.div([attribute.class("w-full bg-gray-700 rounded-full h-2")], [
          html.div([
            attribute.class("bg-sage h-2 rounded-full"),
            attribute.style("width", ui_common.int_to_string(progress) <> "%"),
          ], []),
        ]),
        html.p([attribute.class("text-xs text-gray-400 mt-1 text-right")], [
          html.text(ui_common.int_to_string(progress) <> "%"),
        ]),
      ])
    False ->
      html.p([attribute.class("text-sm text-gray-400 mb-4")], [
        html.text("Waiting for job"),
      ])
  }
}
