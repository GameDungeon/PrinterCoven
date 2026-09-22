import gleam/erlang/process
import gleam/otp/static_supervisor as supervisor
import server/web_server
import wisp

pub fn main() {
  // Setup
  wisp.configure_logger()

  // Start Actors
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(web_server.supervised())
    |> supervisor.start

  process.sleep_forever()
}
