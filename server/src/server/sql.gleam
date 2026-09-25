//// This module contains the code to run the sql queries defined in
//// `./src/server/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import pog

/// A row you get from running the `get_gcode_file` query
/// defined in `./src/server/sql/get_gcode_file.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type GetGcodeFileRow {
  GetGcodeFileRow(bytes: BitArray)
}

/// Runs the `get_gcode_file` query
/// defined in `./src/server/sql/get_gcode_file.sql`.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn get_gcode_file(
  db: pog.Connection,
  arg_1: Int,
) -> Result(pog.Returned(GetGcodeFileRow), pog.QueryError) {
  let decoder = {
    use bytes <- decode.field(0, decode.bit_array)
    decode.success(GetGcodeFileRow(bytes:))
  }

  "select
  bytes
from
  gcode_files
where
  id = $1;
"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `list_printers` query
/// defined in `./src/server/sql/list_printers.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ListPrintersRow {
  ListPrintersRow(
    id: String,
    display_name: String,
    backend: String,
    static_trays: String,
  )
}

/// Runs the `list_printers` query
/// defined in `./src/server/sql/list_printers.sql`.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn list_printers(
  db: pog.Connection,
) -> Result(pog.Returned(ListPrintersRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    use display_name <- decode.field(1, decode.string)
    use backend <- decode.field(2, decode.string)
    use static_trays <- decode.field(3, decode.string)
    decode.success(ListPrintersRow(id:, display_name:, backend:, static_trays:))
  }

  "select
  id,
  display_name,
  backend,
  static_trays
from
  printers
order by
  created_at,
  id;
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}
