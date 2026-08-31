# ADR 0003: Vault frozen for knowledge-base development

Status: Accepted
Date: 2026-08-31

## Context

Singularity is currently being developed as a single-user, local-first
personal knowledge base. The established storage and runtime foundation still
contains Vault tables, `vault_id` columns, cryptographic behavior, and adapter
plumbing from the earlier product model. Active roadmap guidance continued to
describe Vault as a feature and ownership boundary, which could direct new
knowledge-base work into Vault redesign or expansion.

The `0.2.0` release must build Documents, source-pinned knowledge links,
PostgreSQL lexical search, portable export, and complete backup/restore while
preserving the released foundation. Removing legacy Vault infrastructure
would be a separate migration with different compatibility and security risk.

## Decision

Vault is frozen compatibility substrate for `0.2.0`, not an active product
module or release deliverable.

1. Existing Vault implementation remains unchanged for compatibility.
2. New knowledge-domain APIs derive owner scope from authenticated runtime
   context and never expose a caller-selected `vault_id`.
3. Existing `vault_id` fields and adapter plumbing may remain only as opaque
   legacy owner-scope encoding where current persistence requires them.
4. New knowledge rules do not depend on Vault behavior.
5. Removing or replacing legacy Vault infrastructure requires a separately
   approved migration project.
6. Historical specifications remain historical records; this ADR governs
   active development and supersedes conflicting active roadmap guidance.

The active invariant is:

> Every user-owned object belongs to an authenticated owner scope, and every
> projection points to an immutable source version.

## Consequences

`0.2.0` work does not add Vault features, migrations, policies, commands,
telemetry, tests, or acceptance criteria. A Vault-related file may be touched
only for the smallest compile-preserving compatibility patch required by
approved knowledge work, and the implementation report must identify it.

Current persistence may continue to encode authenticated owner scope with
legacy columns until a separately approved migration is designed. That
encoding is not a caller-selectable knowledge-domain concept.

Active README and guide text points to this ADR. Historical implementation
records are not rewritten to erase earlier decisions.
