create table if not exists gcode_files (
  id bigserial primary key,
  bytes bytea not null,
  created_at timestamptz not null default now()
);
