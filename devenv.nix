{
  pkgs,
  lib,
  config,
  inputs,
  ...
}: {
  packages = [pkgs.git];

  languages.gleam.enable = true;

  # services.postgres.enable = true;
}
