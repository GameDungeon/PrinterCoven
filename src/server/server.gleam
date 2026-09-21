import gleam/erlang/process
import gleam/otp/static_supervisor as supervisor
import server/web_server
import wisp

pub fn main() {
  // Setup
  wisp.configure_logger()

  let secret_key_base = wisp.random_string(64)
  // TODO: Load from env

  // Start Actors
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(web_server.supervised(secret_key_base))
    |> supervisor.start

  process.sleep_forever()
}
