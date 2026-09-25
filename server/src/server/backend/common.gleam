//// Helpers shared by the printer-backend adapters.

import gleam/http/response.{type Response}
import gleam/int
import server/printer.{type CommandError, RejectedByPrinter}

/// Filename as stored on the printer's filesystem (Bambu, Moonraker) and in
/// PrusaLink's upload path.
pub fn gcode_filename(file_id: Int) -> String {
  int.to_string(file_id) <> ".gcode"
}

/// Accept any 2xx status; map common failures to domain errors.
pub fn expect_accepted(resp: Response(body)) -> Result(Nil, CommandError) {
  case resp.status {
    status if status >= 200 && status < 300 -> Ok(Nil)
    404 -> Error(RejectedByPrinter("not found"))
    409 -> Error(RejectedByPrinter("conflict"))
    401 -> Error(RejectedByPrinter("unauthorized"))
    status -> Error(RejectedByPrinter("status " <> int.to_string(status)))
  }
}
