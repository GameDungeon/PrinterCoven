import gleam/erlang/process
import gleam/otp/static_supervisor as supervisor
import server/database
import server/migrate
import server/printer_manager
import server/web_server
import wisp

pub fn main() -> Nil {
  wisp.configure_logger()

  let db = database.process()

  // Children start sequentially in the order added: DB pool first, then
  // migrations (its start function blocks until applied), then services that
  // query tables, then the web server. Names are created once here and passed
  // down: `process.new_name` makes a fresh unique name per call.
  let manager_name = printer_manager.manager_name()

  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(database.supervised(db))
    |> supervisor.add(migrate.supervised(db))
    |> supervisor.add(printer_manager.supervised(db, manager_name))
    |> supervisor.add(web_server.supervised(manager_name))
    |> supervisor.start

  process.sleep_forever()
}
