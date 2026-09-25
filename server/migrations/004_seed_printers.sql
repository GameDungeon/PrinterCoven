insert into printers (id, display_name, backend, static_trays) values
  (
    'bambu-dev',
    'Bambu Dev',
    '{"Bambu": {"host": "192.168.1.50", "serial": "00M00A000000001", "access_code": "mock-access-code-a1b2"}}',
    '[{"index": 0, "slot_count": 1}]'
  ),
  (
    'prusa-dev',
    'Prusa Dev',
    '{"PrusaLink": {"host": "192.168.1.51", "username": "mockuser", "password": "mock-password-c3d4"}}',
    '[{"index": 0, "slot_count": 1}]'
  )
on conflict (id) do nothing;
