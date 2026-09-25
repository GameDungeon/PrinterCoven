select
  id,
  display_name,
  backend,
  static_trays
from
  printers
order by
  created_at,
  id;
