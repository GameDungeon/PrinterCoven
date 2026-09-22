{
  pkgs,
  lib,
  config,
  inputs,
  ...
}: {
  packages = [pkgs.git];

  languages.gleam.enable = true;

services.postgres = {
    enable = true;
    listen_addresses = "127.0.0.1";
    initialDatabases = [
      { name = "printer_coven"; }
    ];
  };

  env.WISP_SECRET = "NotSoSecretAfterAll";
}
