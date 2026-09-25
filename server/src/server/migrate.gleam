import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/otp/actor
import gleam/otp/supervision
import gorrion
import gorrion/types
import pog
import server/database

const migrations_dir = "migrations"

const max_attempts = 60

const retry_delay_ms = 500

/// Applies pending migrations synchronously during start, then idles.
/// Subsequent supervisor children start only after migrations succeed.
pub fn supervised(db: database.Db) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    let conn = database.connection(db)
    attempt(conn, 1)
    let pid = process.spawn(fn() { process.sleep_forever() })
    Ok(actor.Started(pid:, data: Nil))
  })
}

fn attempt(conn: pog.Connection, n: Int) -> Nil {
  case gorrion.migrate(db: conn, migrations_dir:) {
    Ok(Nil) -> Nil
    Error(error) if n >= max_attempts -> {
      io.println(
        "Migration failed after "
        <> int.to_string(n)
        <> " attempts: "
        <> describe(error),
      )
      panic as "database migrations failed"
    }
    Error(error) -> {
      io.println(
        "Migration attempt "
        <> int.to_string(n)
        <> " failed ("
        <> describe(error)
        <> "), retrying...",
      )
      process.sleep(retry_delay_ms)
      attempt(conn, n + 1)
    }
  }
}

fn describe(error: types.MigrationError) -> String {
  case error {
    types.QueryError(reason) -> "query error: " <> reason
    types.MigrationFailed(version:, name:, reason:) ->
      "migration " <> int.to_string(version) <> " (" <> name <> "): " <> reason
    types.RollbackFailed(version:, name:, reason:) ->
      "rollback " <> int.to_string(version) <> " (" <> name <> "): " <> reason
    types.NoMigrationsToRollback -> "no migrations to rollback"
    types.FileError(reason) -> "file error: " <> reason
  }
}
