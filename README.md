# Singularity

Self-hosted personal information collector. Configure sources in the web UI;
Singularity collects them on a schedule and keeps every observation as a
browsable knowledge item.

First source type: GitHub Trending.

## Development

    devenv up -d
    devenv shell -- mix setup
    devenv shell -- mix phx.server

Open http://localhost:4000.

Collect one source immediately: `devenv shell -- mix singularity.collect <source_id>`.

See `AGENTS.md` for conventions and `docs/superpowers/specs/` for the design.
