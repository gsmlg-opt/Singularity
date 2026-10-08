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

Phase 1 is accepted locally at `a80957da41582de40bdf586a0cba1e14644acf0a`.
The active implementation slice is Phase 2 under the
[approved import/extraction design](docs/superpowers/specs/2026-09-22-singularity-v0.2-phase-2-import-extraction-design.md)
and [detailed implementation plan](docs/superpowers/plans/2026-09-22-singularity-v0.2-phase-2-import-extraction.md).
Later phases still require separate approved designs and detailed plans.
Version bumps, tags, releases, pushes, and deployments remain separately gated.

New canonical writes remain unavailable to production runtime roles.
Public import, extraction workers, search, Note Save integration, backup V3,
and browser behavior remain in their designated later phases.

Phase 2 must provide original-byte retention and abandoned extraction recovery
before public import. Phase 4 must seal Note source-set membership before enabling
its writes. Production activation requires a fail-closed backup guard for
unsupported canonical rows or complete V3 support.

Phase 1 source acceptance covers only the bounded authenticated storage digest
primitive, source-proof contract, source revalidation, and isolated contract tests.
Live runtime custody composition requires a separately approved Phase 2 design.
No custody, key, capability, or Vault change is authorized.
Test doubles do not prove live source verification.

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

For image builds and operator setup, see the
[Docker deployment guide](docs/deployment/docker.md). Building an image does
not accept the active release or authorize production activation.

GitHub Actions runs ExUnit and JavaScript unit tests automatically on pushes to
`main` and pull requests targeting `main`. Integration, restore, and Chromium
acceptance run only through Actions → Manual Acceptance → Run workflow; select
the branch or tag to test. Static CI checks remain automatic. Unit CI does not
replace the complete phase/release verification gate below.

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
  .github/workflows/e2e.yml \
  .github/workflows/release.yml \
  .github/workflows/docker-image.yml

git diff --check
git status --short
test -z "$(git status --porcelain)"
)
```

Browser acceptance ends with a sealed encrypted backup.
`mix singularity.test.restore` is the sole independent restore-scoped integrity
proof. Keep the backup passphrase safe: losing it makes recovery impossible.

See the [Architecture and Implementation Guide](docs/guide.md) as an
architecture reference. Its active `0.2.0` status notice, roadmap, and
invariants govern current work together with the approved release design.
