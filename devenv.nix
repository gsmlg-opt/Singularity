{ pkgs, inputs, ... }:

let
  pkgs-stable = import inputs.nixpkgs-stable { system = pkgs.stdenv.system; };
in
{
  packages = [
    pkgs-stable.git
    pkgs.beam29Packages.elixir-ls
    pkgs-stable.nodejs_24
    pkgs.watchexec
  ];

  languages.elixir.enable = true;
  languages.elixir.package = pkgs.beam29Packages.elixir_1_20;

  services.postgres = {
    enable = true;
    package = pkgs-stable.postgresql_17;
    # Unix socket only (PGHOST points at it), so no TCP port can clash with
    # other projects' databases. config/dev.exs and test.exs connect via PGHOST.
    listen_addresses = "";
  };

  # The local test environment: `devenv up -d`, then http://10.100.10.10:4120/.
  # Code, templates and assets reload in place (Phoenix code reloader and the
  # DuskmoonBundler watcher). Changes that need a restart — configuration,
  # dependencies, migrations — restart the server once they settle for 15s
  # (devenv's own `watch` has a fixed, short debounce). Each start creates and
  # migrates the database first. A crash restarts the process.
  processes.singularity = {
    exec = ''
      exec watchexec \
        --debounce 15s \
        --restart \
        --stop-signal SIGTERM \
        --stop-timeout 15s \
        --no-vcs-ignore \
        --watch config \
        --watch mix.exs \
        --watch mix.lock \
        --watch apps/singularity/mix.exs \
        --watch apps/singularity_web/mix.exs \
        --watch apps/singularity/priv/repo/migrations \
        --exts exs,lock \
        -- 'mix deps.get && mix ecto.create --quiet && mix ecto.migrate && mix phx.server'
    '';
    env = {
      PORT = "4120";
      PHX_IP = "0.0.0.0";
    };
    after = [ "devenv:processes:postgres" ];
    restart.on = "on_failure";
  };
}
