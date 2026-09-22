insert into users (email, username, password_hash)
values ($1, $2, $3)
returning id;