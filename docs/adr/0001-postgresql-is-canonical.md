# ADR 0001: PostgreSQL is canonical

Status: Accepted
Date: 2026-07-18

## Context

The original five-application topology assigned canonical persistence to `singularity_store` and planned CouchDB as its backing service. The seven-application foundation needs one authoritative store for structured knowledge records, revision history, ingestion state, and asset metadata without maintaining two persistence models.

## Decision

PostgreSQL is the canonical store for all structured application data. CouchDB and the obsolete `singularity_store` application are removed as a clean break. The new `singularity_storage` boundary will own PostgreSQL persistence and asset-storage adapters without preserving the old store API.

## Consequences

Application records have one transactional source of truth, and future migrations use the existing PostgreSQL toolchain. There is no CouchDB compatibility layer, dual-write path, or data migration in this pre-production foundation. Asset bytes remain outside PostgreSQL and follow the temporary storage decision in ADR 0002.
