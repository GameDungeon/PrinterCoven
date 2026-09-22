import client/routes
import client/ui_common
import gleam/list
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

// ---------------------------------------------------------------------------
// Project list view
// ---------------------------------------------------------------------------

pub fn view() -> Element(msg) {
  html.div([], [
    ui_common.page_header("Projects", "Browse your 3D print project files."),
    project_table(),
  ])
}

fn project_table() -> Element(msg) {
  ui_common.table_wrapper([
    html.table([ui_common.table_full()], [
      ui_common.table_head([
        html.tr([], [
          ui_common.table_header("Name"),
          ui_common.table_header("Description"),
          ui_common.table_header("Files"),
          ui_common.table_header("Last Modified"),
        ]),
      ]),
      ui_common.table_body([
        project_row(1, "Bracket Set", "Mounting brackets for enclosure", 3, "2 hours ago"),
        project_row(2, "Housing Kit", "Printer housing components", 4, "Yesterday"),
        project_row(3, "Calibration Suite", "Calibration and test prints", 2, "3 days ago"),
        project_row(4, "Phone Accessories", "Phone stands and holders", 2, "1 week ago"),
      ]),
    ]),
  ])
}

fn project_row(
  id: Int,
  name: String,
  description: String,
  file_count: Int,
  last_modified: String,
) -> Element(msg) {
  ui_common.table_row([
    html.td([attribute.class("px-6 py-4 whitespace-nowrap")], [
      html.a(
        [
          routes.href(routes.ProjectDetail(id:)),
          attribute.class("text-sm font-medium text-sage hover:text-sage-dim"),
        ],
        [html.text(name)],
      ),
    ]),
    ui_common.table_cell([html.text(description)]),
    ui_common.table_cell_muted([html.text(ui_common.int_to_string(file_count) <> " files")]),
    ui_common.table_cell_muted([html.text(last_modified)]),
  ])
}

// ---------------------------------------------------------------------------
// Project detail view
// ---------------------------------------------------------------------------

pub fn view_project(id: Int) -> Element(msg) {
  let project = get_project(id)

  html.div([], [
    html.div([attribute.class("mb-6")], [
      html.a([
        routes.href(routes.Projects),
        attribute.class("text-sm text-gray-400 hover:text-gray-200"),
      ], [
        html.text("\u{2190} Back to Projects"),
      ]),
    ]),
    ui_common.page_header(project.name, project.description),
    file_explorer(project),
  ])
}

type Project {
  Project(
    name: String,
    description: String,
    files: List(File),
  )
}

type File {
  File(name: String, size: String)
}

fn get_project(id: Int) -> Project {
  case id {
    1 ->
      Project(
        name: "Bracket Set",
        description: "Mounting brackets for enclosure",
        files: [
          File("Corner_Bracket_v2.stl", "245 KB"),
          File("Mount_Bracket_v1.stl", "180 KB"),
          File("Corner_Bracket_Reinforced.stl", "310 KB"),
        ],
      )
    2 ->
      Project(
        name: "Housing Kit",
        description: "Printer housing components",
        files: [
          File("Base_Plate.stl", "890 KB"),
          File("Base_Support.stl", "340 KB"),
          File("Lid_Main.stl", "560 KB"),
          File("Lid_Handle.stl", "120 KB"),
        ],
      )
    3 ->
      Project(
        name: "Calibration Suite",
        description: "Calibration and test prints",
        files: [
          File("XYZ_Cube.stl", "15 KB"),
          File("Temp_Tower.stl", "22 KB"),
        ],
      )
    4 ->
      Project(
        name: "Phone Accessories",
        description: "Phone stands and holders",
        files: [
          File("Phone_Stand.stl", "120 KB"),
          File("Cable_Spool.stl", "78 KB"),
        ],
      )
    _ ->
      Project(
        name: "Unknown Project",
        description: "",
        files: [],
      )
  }
}

fn file_explorer(project: Project) -> Element(msg) {
  html.div(
    [attribute.class("bg-gray-800 border border-gray-700 rounded-lg shadow-sm p-4")],
    [
      html.ul([attribute.class("divide-y divide-gray-700")], [
        list.map(project.files, fn(f) { file_row(f) })
        |> element.fragment,
      ]),
    ],
  )
}

fn file_row(f: File) -> Element(msg) {
  html.li([attribute.class("py-1")], [
    html.div([attribute.class("flex items-center gap-2 py-1 px-2 rounded hover:bg-gray-700/50 cursor-pointer")], [
      file_icon(),
      html.span([attribute.class("text-sm text-gray-300")], [html.text(f.name)]),
      html.span([attribute.class("text-xs text-gray-400 ml-auto")], [html.text(f.size)]),
    ]),
  ])
}

fn file_icon() -> Element(msg) {
  html.span([attribute.class("text-gray-400")], [html.text("\u{1F4C4}")])
}
