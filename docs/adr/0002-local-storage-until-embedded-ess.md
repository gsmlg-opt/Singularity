# ADR 0002: Use local storage until embedded ESS is available

Status: Accepted
Date: 2026-07-18

## Context

Singularity needs encrypted storage for asset bytes, but the storage service does not yet provide the embedded adapter required by a local-first deployment. The existing [gsmlg-opt/ex_storage_service#5](https://github.com/gsmlg-opt/ex_storage_service/issues/5) request tracks that capability with `needed` severity.

## Decision

Asset bytes will use an encrypted local-storage adapter behind the `singularity_storage` boundary. This adapter is temporary and will be replaced by embedded `ex_storage_service` integration after issue #5 is resolved and the dependency is updated.

## Consequences

The foundation does not add a storage daemon or copy the obsolete `singularity_store` API. Local asset data must be backed up alongside PostgreSQL and does not provide distributed availability. Keeping the adapter behind `singularity_storage` limits the eventual replacement to that application boundary.
