import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process
import gleam/result
import gleam/string
import kafein
import mug
import spoke/core
import spoke/mqtt_actor.{type TransportChannel, type TransportChannelConnector}

/// TLS transport connector for Bambu local MQTT (port 8883).
///
/// Modelled on `spoke_tcp`, but wraps the socket with kafein and does not
/// verify certificates (`VerifyNone`) — printers present self-signed certs.
pub fn connector(
  host host: String,
  port port: Int,
  connect_timeout connect_timeout: Int,
) -> TransportChannelConnector {
  fn() { connect(host, port, connect_timeout) }
}

fn connect(
  host: String,
  port: Int,
  connect_timeout: Int,
) -> Result(TransportChannel, String) {
  let options =
    mug.ConnectionOptions(host, port, connect_timeout, mug.Ipv4Preferred)
  use socket <- result.try(mug.connect(options) |> map_error("Connect error"))

  let wrap_options = kafein.default_options |> kafein.verify(kafein.VerifyNone)
  use ssl <- result.try(
    kafein.wrap(wrap_options, socket)
    |> result.map_error(fn(e) { "TLS error: " <> string.inspect(e) }),
  )

  let subject = process.new_subject()
  let selector =
    process.new_selector()
    |> kafein.select_ssl_messages(map_ssl_message)
    |> process.select(subject)

  process.send(subject, core.TransportEstablished)
  kafein.receive_next_packet_as_message(ssl)

  Ok(
    mqtt_actor.TransportChannel(
      selector,
      fn(data: BytesTree) { send(ssl, data) },
      fn() { kafein.shutdown(ssl) |> map_error("Shutdown error") },
    ),
  )
}

fn send(ssl: kafein.SslSocket, data: BytesTree) -> Result(Nil, String) {
  kafein.send_builder(ssl, data) |> map_error("Send error")
}

fn map_ssl_message(msg: kafein.SslMessage) -> core.TransportEvent {
  case msg {
    kafein.Packet(ssl, data) -> {
      kafein.receive_next_packet_as_message(ssl)
      core.ReceivedData(data)
    }
    kafein.SocketClosed(_) -> core.TransportClosed
    kafein.SslError(_, e) ->
      core.TransportFailed("TLS error: " <> string.inspect(e))
  }
}

fn map_error(r: Result(a, e), reason: String) -> Result(a, String) {
  result.map_error(r, fn(e) { reason <> ": " <> string.inspect(e) })
}
