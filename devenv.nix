{ pkgs, inputs, ... }:

let
  pkgs-stable = import inputs.nixpkgs-stable { system = pkgs.stdenv.system; };
in
{
  packages = with pkgs-stable; [
    git
    beam28Packages.elixir-ls
    nodejs_24
  ];

  languages.elixir.enable = true;
  languages.elixir.package = pkgs-stable.beam28Packages.elixir;

  services.postgres = {
    enable = true;
    package = pkgs-stable.postgresql_17;
  };
}
