update
  users
set
  email = $2,
  username = $3,
  password_hash = $4,
  updated_at = now()
where
  id = $1;