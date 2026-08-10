# Singularity

Singularity is a local-first personal data and knowledge operating system.

The Elixir umbrella is split into seven applications with a fixed dependency graph. PostgreSQL is the canonical store for application records and asset metadata. Asset bytes use encrypted local storage temporarily, pending an embedded `ex_storage_service` adapter. CouchDB is not part of the architecture.

## Applications

- `singularity_core` — pure domain values and behaviours
- `singularity_domains` — domain workflows built on the core contracts
- `singularity_storage` — PostgreSQL and encrypted asset-storage adapters
- `singularity_ingest` — source ingestion and normalization
- `singularity_retrieval` — knowledge retrieval
- `singularity_runtime` — use-case orchestration across application boundaries
- `singularity_web` — web interface with access only to the runtime boundary

Qdrant is required in Milestone 8 as a rebuildable vector index. It is intentionally not a dependency of the foundation.

The storage decisions are recorded in [ADR 0001](docs/adr/0001-postgresql-is-canonical.md) and [ADR 0002](docs/adr/0002-local-storage-until-embedded-ess.md).

## Development

Run the complete local verification sequence from one shell so its cleanup trap
remains active for the entire run:

```bash
(
set -euo pipefail
trap 'devenv processes down' EXIT

devenv up -d
devenv processes wait --timeout 120
devenv shell -- bash \
  apps/singularity_storage/priv/repo/bootstrap_roles.sh
devenv shell -- mix deps.get
devenv shell -- mix deps.unlock --check-unused
devenv shell -- mix format --check-formatted
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix test
devenv shell -- mix singularity.test.integration
devenv shell -- mix singularity.test.restore
# TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#129
# WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#129
devenv shell -- env NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen
devenv shell -- mix npm.verify
devenv shell -- mix duskmoon_bundler.js.check
devenv shell -- mix npm.run test:js
devenv shell -- mix duskmoon_bundler.build singularity_web --tailwind
devenv shell -- mix npm.run test:e2e
devenv shell -- mix xref graph --format cycles --fail-above 0
)
```

Browser acceptance ends with a sealed encrypted backup.
`mix singularity.test.restore` is the sole independent restore-scoped integrity
proof. Keep the backup passphrase safe: losing it makes recovery impossible.

See the [Architecture and Implementation Guide](docs/guide.md) for the current system design.
