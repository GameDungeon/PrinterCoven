import client/ui_common
import lustre/element.{type Element}
import lustre/element/html

pub fn view() -> Element(msg) {
  html.div([], [
    ui_common.page_header("Job Queue", "View and manage queued print jobs."),
    job_table(),
  ])
}

fn job_table() -> Element(msg) {
  ui_common.table_wrapper([
    html.table([ui_common.table_full()], [
      ui_common.table_head([
        html.tr([], [
          ui_common.table_header("Job Name"),
          ui_common.table_header("Printer"),
          ui_common.table_header("Status"),
          ui_common.table_header("Priority"),
          ui_common.table_header("Submitted"),
        ]),
      ]),
      ui_common.table_body([
        job_row("Bracket_V3.stl", "Printer 1", "Printing", "High", "2 min ago"),
        job_row("Housing_Lid.stl", "Printer 2", "Queued", "Normal", "5 min ago"),
        job_row("Gear_Assembly.stl", "Printer 1", "Queued", "Normal", "8 min ago"),
        job_row("Mount_Plate.stl", "Printer 3", "Failed", "High", "12 min ago"),
        job_row("Enclosure_Base.stl", "Printer 4", "Queued", "Low", "15 min ago"),
        job_row("Calibration_Piece.stl", "Printer 2", "Completed", "Low", "22 min ago"),
      ]),
    ]),
  ])
}

fn job_row(
  name: String,
  printer: String,
  status: String,
  priority: String,
  submitted: String,
) -> Element(msg) {
  ui_common.table_row([
    ui_common.table_cell_primary([html.text(name)]),
    ui_common.table_cell_muted([html.text(printer)]),
    ui_common.table_cell_nopad([status_badge(status)]),
    ui_common.table_cell_muted([html.text(priority)]),
    ui_common.table_cell_muted([html.text(submitted)]),
  ])
}

fn status_badge(status: String) -> Element(msg) {
  let color = case status {
    "Printing" -> "blue"
    "Queued" -> "yellow"
    "Failed" -> "red"
    "Completed" -> "green"
    _ -> "gray"
  }

  ui_common.badge(status, color)
}
