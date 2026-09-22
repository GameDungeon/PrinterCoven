select
  id,
  email,
  username,
  password_hash,
  created_at,
  updated_at
from
  users
order by
  created_at desc;