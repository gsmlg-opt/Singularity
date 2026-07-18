{ pkgs, inputs, ... }:

let
  pkgs-stable = import inputs.nixpkgs-stable { system = pkgs.stdenv.system; };
in
{
  packages = with pkgs-stable; [
    git
    beam28Packages.elixir-ls
    nodejs_24
    chromium
  ];

  languages.elixir.enable = true;
  languages.elixir.package = pkgs-stable.beam28Packages.elixir;

  services.postgres = {
    enable = true;
    package = pkgs-stable.postgresql_17;
  };

  env.PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
  env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH =
    "${pkgs-stable.chromium}/bin/chromium";
}
