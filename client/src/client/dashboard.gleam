import client/ui_common
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/server_component

/// Page shell for the dashboard. Printer cards are rendered by the
/// `server_component` at `/api/printers/ws`, which streams live status updates
/// from the printer manager.
pub fn view() -> Element(msg) {
  html.div([], [
    ui_common.page_header(
      "3D Printers",
      "Manage and monitor your fleet of printers.",
    ),
    server_component.element([server_component.route("/api/printers/ws")], []),
  ])
}

pub fn printer_box(
  name name: String,
  model model: String,
  status status: String,
  job job: String,
  progress progress: Int,
  nozzle_temp nozzle_temp: String,
  bed_temp bed_temp: String,
) -> Element(msg) {
  let is_printing = status == "Printing"
  let badge_color = case status {
    "Printing" -> "blue"
    "Offline" | "Errored" -> "red"
    "Paused" | "Needs attention" -> "yellow"
    _ -> "green"
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
    html.div(
      [
        attribute.class(
          "flex gap-4 text-sm text-gray-400 border-t border-gray-700 pt-3",
        ),
      ],
      [
        html.div([], [
          html.span([attribute.class("text-gray-400")], [html.text("Nozzle: ")]),
          html.span([attribute.class("font-medium text-gray-200")], [
            html.text(nozzle_temp),
          ]),
        ]),
        html.div([], [
          html.span([attribute.class("text-gray-400")], [html.text("Bed: ")]),
          html.span([attribute.class("font-medium text-gray-200")], [
            html.text(bed_temp),
          ]),
        ]),
      ],
    ),
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
          html.div(
            [
              attribute.class("bg-sage h-2 rounded-full"),
              attribute.style("width", ui_common.int_to_string(progress) <> "%"),
            ],
            [],
          ),
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
