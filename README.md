# Singularity

Singularity is a personal, LLM-native knowledge base that preserves immutable source history and produces evidence-grounded answers.

PRD-001 is delivered as six bounded pull requests. The first establishes the five-application Elixir umbrella and its contracts; later slices add CouchDB, deterministic chunking, Qdrant, Backplane, and Phoenix.

## Applications

- `singularity_core` — pure domain values and behaviours
- `singularity_store` — canonical persistence boundary
- `singularity_retrieval` — vector projection boundary
- `singularity_runtime` — use-case orchestration
- `singularity_web` — future Phoenix interface

## Development

```sh
devenv shell
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix xref graph --format cycles --fail-above 0
```

See `PRD-001-singularity-knowledge-core.md` for product requirements and `docs/superpowers/plans/` for implementation plans.
