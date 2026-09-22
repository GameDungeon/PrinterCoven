import client/ui_common
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

pub fn view() -> Element(msg) {
  html.div([], [
    ui_common.page_header("Filament Inventory", "Track your filament stock and storage locations."),
    filament_table(),
  ])
}

fn filament_table() -> Element(msg) {
  ui_common.table_wrapper([
    html.table([ui_common.table_full()], [
      ui_common.table_head([
        html.tr([], [
          ui_common.table_header("Brand"),
          ui_common.table_header("Material"),
          ui_common.table_header("Color"),
          ui_common.table_header("Weight"),
          ui_common.table_header("Spool"),
          ui_common.table_header("Location"),
        ]),
      ]),
      ui_common.table_body([
        filament_row("Bambu", "PLA Basic", "White", 850, "1 kg", "Shelf A"),
        filament_row("Bambu", "PETG HF", "Black", 620, "1 kg", "Shelf A"),
        filament_row("Overture", "PLA Matte", "Slate Gray", 180, "1 kg", "Shelf B"),
        filament_row("Prusament", "PETG", "Galaxy Black", 950, "1 kg", "Shelf B"),
        filament_row("eSUN", "ABS+", "White", 430, "1 kg", "Drawer 1"),
        filament_row("Bambu", "TPU 95A", "Blue", 780, "0.5 kg", "Drawer 2"),
        filament_row("Polymaker", "PLA Pro", "Forest Green", 55, "1 kg", "Shelf A"),
      ]),
    ]),
  ])
}

fn filament_row(
  brand: String,
  material: String,
  color: String,
  weight_g: Int,
  spool_size: String,
  location: String,
) -> Element(msg) {
  let is_low = weight_g < 200
  let weight_label = case spool_size {
    "1 kg" -> ui_common.int_to_string(weight_g) <> "g / 1 kg"
    "0.5 kg" -> ui_common.int_to_string(weight_g) <> "g / 500g"
    _ -> ui_common.int_to_string(weight_g) <> "g"
  }
  let weight_classes = case is_low {
    True -> "px-6 py-4 whitespace-nowrap text-sm text-red-400 font-medium"
    False -> "px-6 py-4 whitespace-nowrap text-sm text-gray-300"
  }

  ui_common.table_row([
    ui_common.table_cell_primary([html.text(brand)]),
    ui_common.table_cell([html.text(material)]),
    ui_common.table_cell([
      html.div([attribute.class("flex items-center gap-2")], [
        color_dot(color),
        html.text(color),
      ]),
    ]),
    html.td([attribute.class(weight_classes)], [html.text(weight_label)]),
    ui_common.table_cell_muted([html.text(spool_size)]),
    ui_common.table_cell_muted([html.text(location)]),
  ])
}

fn color_dot(color: String) -> Element(msg) {
  let bg = case color {
    "White" -> "bg-white border border-gray-500"
    "Black" -> "bg-gray-900 border border-gray-500"
    "Slate Gray" -> "bg-gray-500"
    "Galaxy Black" -> "bg-gray-700 border border-gray-500"
    "Blue" -> "bg-blue-500"
    "Forest Green" -> "bg-emerald-600"
    _ -> "bg-gray-400"
  }

  html.span([attribute.class("inline-block w-3 h-3 rounded-full shrink-0 " <> bg)], [])
}
