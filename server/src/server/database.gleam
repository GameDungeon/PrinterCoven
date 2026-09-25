import envoy
import gleam/erlang/process
import gleam/io
import gleam/otp/supervision
import pog

pub type Db {
  Db(name: process.Name(pog.Message))
}

pub fn process() -> Db {
  Db(name: process.new_name("printer_coven_db"))
}

pub fn supervised(db: Db) -> supervision.ChildSpecification(pog.Connection) {
  case envoy.get("DATABASE_URL") {
    Ok(database_url) -> {
      let assert Ok(config) = pog.url_config(db.name, database_url)
      pog.supervised(config)
    }
    Error(_) -> {
      io.println(
        "WARNING: DATABASE_URL not set; falling back to local defaults",
      )
      pog.default_config(db.name)
      |> pog.database("printer_coven")
      |> pog.pool_size(10)
      |> pog.supervised
    }
  }
}

pub fn connection(db: Db) -> pog.Connection {
  pog.named_connection(db.name)
}
