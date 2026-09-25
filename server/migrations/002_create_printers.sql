create table if not exists printers (
  id text primary key,
  display_name text not null,
  backend jsonb not null,
  static_trays jsonb not null default '[{"index": 0, "slot_count": 1}]',
  created_at timestamptz not null default now()
);
