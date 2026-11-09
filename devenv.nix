{ pkgs, inputs, ... }:

let
  pkgs-stable = import inputs.nixpkgs-stable { system = pkgs.stdenv.system; };
in
{
  packages = [
    pkgs-stable.git
    pkgs.beam29Packages.elixir-ls
    pkgs-stable.nodejs_24
  ];

  languages.elixir.enable = true;
  languages.elixir.package = pkgs.beam29Packages.elixir;

  services.postgres = {
    enable = true;
    package = pkgs-stable.postgresql_17;
  };
}
