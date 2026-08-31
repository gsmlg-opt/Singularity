# Singularity

Singularity is a local-first personal data and knowledge operating system; its active `0.2.0` release is a single-user personal knowledge base.

The Elixir umbrella is split into seven applications with a fixed dependency graph. PostgreSQL is the canonical store for application records and asset metadata. Asset bytes use encrypted local storage temporarily, pending an embedded `ex_storage_service` adapter. CouchDB is not part of the architecture.

## Applications

- `singularity_core` — pure domain values and behaviours
- `singularity_domains` — domain workflows built on the core contracts
- `singularity_storage` — PostgreSQL and encrypted asset-storage adapters
- `singularity_ingest` — source ingestion and normalization
- `singularity_retrieval` — knowledge retrieval
- `singularity_runtime` — use-case orchestration across application boundaries
- `singularity_web` — web interface with access only to the runtime boundary

## Active `0.2.0` scope

Current work is Phase 0 only: scope lock, governance, characterization, and a
green baseline. Phase 1 must not begin until Phase 0 is accepted and Phase 1
has its own approved design and detailed implementation plan.

Vault is frozen compatibility substrate for `0.2.0`, not an active product
module or release deliverable. Existing `vault_id` persistence and adapter
plumbing may remain as opaque legacy owner-scope encoding. New knowledge APIs
derive owner scope from authenticated runtime context and never accept a
caller-selected Vault scope. Removing or replacing legacy Vault
infrastructure requires a separately approved migration project.

> Every user-owned object belongs to an authenticated owner scope, and every
> projection points to an immutable source version.

Qdrant is out of scope for `0.2.0`.

Embeddings, semantic or vector search, RAG, Agents, OCR, and unrelated domains
or connectors are also out of scope.

The storage decisions are recorded in
[ADR 0001](docs/adr/0001-postgresql-is-canonical.md) and
[ADR 0002](docs/adr/0002-local-storage-until-embedded-ess.md). The active
Vault compatibility decision is
[ADR 0003](docs/adr/0003-vault-frozen-for-knowledge-base-development.md).
The
[approved release design](docs/superpowers/specs/2026-08-31-singularity-v0.2-release-design.md)
and
[canonical release directive](docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md)
govern `0.2.0`.

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

devenv shell -- env NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen
devenv shell -- mix npm.verify
devenv shell -- mix duskmoon_bundler.js.check
devenv shell -- mix npm.run test:js
devenv shell -- mix duskmoon_bundler.build singularity_web --tailwind
devenv shell -- mix npm.run test:e2e

devenv shell -- mix xref graph --format cycles --fail-above 0
nix run nixpkgs#actionlint -- \
  .github/workflows/ci.yml \
  .github/workflows/test.yml \
  .github/workflows/release.yml

git diff --check
git status --short
)
```

Browser acceptance ends with a sealed encrypted backup.
`mix singularity.test.restore` is the sole independent restore-scoped integrity
proof. Keep the backup passphrase safe: losing it makes recovery impossible.

See the [Architecture and Implementation Guide](docs/guide.md) as an
architecture reference. Its active `0.2.0` status notice, roadmap, and
invariants govern current work together with the approved release design.
