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

Phase 2 has [qualified local acceptance](docs/verification/2026-10-09-phase-2-acceptance.md)
on tested source `c34935a112a2b4b807ed741e8e67e44d4e63eafe`.
Phase 3 has [qualified local acceptance](docs/verification/2026-10-09-phase-3-acceptance.md)
on tested source `35c1f8360dd22b129832a1618b3723032a1983bd`.
Its historical [Phase 3 design](docs/superpowers/specs/2026-10-09-singularity-v0.2-phase-3-unified-lexical-search-design.md)
and [Phase 3 implementation plan](docs/superpowers/plans/2026-10-09-singularity-v0.2-phase-3-unified-lexical-search.md)
remain provenance for the accepted search slice.
Phase 4 has [qualified local acceptance](docs/verification/2026-10-11-phase-4-acceptance.md)
on tested source `42c01a5c99b1df3d1e4284d277c6ea48046875cb`; E2E remains NOT RUN.
Its documentation handoff is `5f7e6363be534dbfb4dfa1475538fddcbd29cf32`.
The historical Phase 4 source-link scope remains documented by the
[versioned-source design](docs/superpowers/specs/2026-10-11-singularity-v0.2-phase-4-knowledge-links-design.md)
and [detailed implementation plan](docs/superpowers/plans/2026-10-11-singularity-v0.2-phase-4-knowledge-links.md).
The active implementation slice is Phase 5 under the
[portable-export and logical-backup design](docs/superpowers/specs/2026-10-11-singularity-v0.2-phase-5-export-backup-design.md)
and [detailed implementation plan](docs/superpowers/plans/2026-10-11-singularity-v0.2-phase-5-export-backup.md).
Phase 5 prepares portable Markdown, retained originals, extracted text and a
non-secret manifest, complete V3 backups, V1/V2/V3 restore with source integrity
and search reconstruction, and a historical `0.1.0` upgrade. Its implementation
and acceptance remain unqualified; no browser features or production activation
are enabled.
New backups use logical V3 after combined writer and restore qualification.
Explicit V2 retains its fail-closed unsupported-canonical guard.
See the [Task12 default-transition design](docs/superpowers/specs/2026-10-18-singularity-v0.2-phase-5-task12-default-v3-design.md) and
[detailed plan](docs/superpowers/plans/2026-10-18-singularity-v0.2-phase-5-task12-default-v3.md).
Task12's tested/reviewed local source is `4d832e91a5cf093ecd081be7b4fd515426b21f7d`;
see its [actual source/gate handoff](docs/verification/2026-10-18-phase-5-task12-handoff.md)
for evidence and the documentation-closure boundary.
Task11's local documentation handoff is `e24b2b2b10f4bb2d21d7600ad8bdc2f931237d56`;
its [source/gate handoff](docs/verification/2026-10-18-phase-5-task11-handoff.md)
remains the historical qualification snapshot.
Under the [continuous development authorization](AGENTS.md#continuous-development-authorization--2026-10-10):
Later phases require designs, detailed plans, required verification, and
independent review, without renewed routine human approval.
Advance automatically only after the preceding phase's required gates pass.
Necessary in-scope repairs are not limited by old file lists.
Version bumps, tags, releases, pushes, and deployments remain separately gated.
The user's 2026-10-10 E2E deferral permits local phase advancement after all other
required checks and independent review pass. E2E remains manual-only and NOT RUN;
final browser/release acceptance remains required.

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

The user's [2026-10-19 minimal exception](docs/superpowers/specs/2026-10-19-singularity-v0.2-phase-5-export-lease-ownership-design.md)
permits only native Asset/Document export-request lease ownership and cleanup
in `KeyCustodian`/`DownloadLease`, with focused native regressions. Ordinary
downloads/workers, all authorization/source/crypto checks and the rest of Vault
remain frozen. That design-stage authorization did not itself qualify source.
The native prerequisite now has [qualified local source acceptance](docs/verification/2026-10-19-phase-5-export-lease-ownership-handoff.md)
at `6c7f867309470e23e8f34c06a8f53af0b496d48d`. Original Task16 artifact/API/startup
composition and its end-to-end ALL-leases assertions remain unaccepted; Phase5
is still in progress. E2E remains NOT RUN.

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

Fresh and historical test databases provision the approved `pg_trgm` 1.6 search
extension before migrations. This requires the external administrator connection
in `SINGULARITY_ROLE_PROVISIONER_DATABASE_URL` (provided by `devenv shell`) and
the PostgreSQL server's `pg_trgm` package. Provisioning targets each allocated
application database, not the administrator's maintenance database. The task-only
bootstrap does not add an administrator repository or runtime credentials;
incompatible existing extension state fails without being rewritten. See the
[deployment provisioning step](docs/deployment/docker.md#provision-search-extensions)
for persistent databases.

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
