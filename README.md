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

```sh
devenv shell -- mix deps.get
devenv shell -- mix format --check-formatted
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix test
devenv shell -- mix xref graph --format cycles --fail-above 0
```

See the [Architecture and Implementation Guide](docs/guide.md) for the current system design.
