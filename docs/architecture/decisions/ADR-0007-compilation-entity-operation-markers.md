# ADR-0007: Compilation entity operation markers

- **Status:** Accepted
- **Date:** 2026-08-07
- **Issue:** [#869](https://github.com/getyak/daypage/issues/869)

## Context

Compilation can fail after one or more entity pages were written but before the Daily
Page `source_hash` completion marker is durable. A retry reruns a non-deterministic LLM,
so comparing generated Markdown bytes cannot reliably identify already-applied work.
Writing the Daily Page marker first is also unsafe because it causes a partial compile to
be skipped forever.

## Decision

1. The raw-input `source_hash` is the stable operation ID for entity persistence.
2. Instructions resolving to one entity page are applied in memory and written once
   atomically.
3. The page write includes `<!-- daypage-compilation:<source_hash> -->`. Markdown readers
   ignore this compatibility-safe derived-data marker.
4. A page carrying that operation marker skips content replay even when regenerated text
   differs.
5. `wiki/index.md` reconciliation is idempotent and still runs for marked pages, allowing
   retry to heal an index write that failed after the page commit.
6. The Daily Page `source_hash` is written only after all throwable entity and index work
   succeeds.
7. Normal compilation uses the raw `source_hash` directly. Explicit force recompilation
   derives the operation ID from that hash plus the pre-attempt Daily Page filesystem
   revision. A failed attempt sees the same revision and remains replay-safe; a successful
   atomic Daily Page replacement advances the revision so the next explicit force action
   can apply newly generated entity updates.

The operation-ID overload is used by compilation. The legacy entity API retains exact
content replay protection for non-compilation callers.

## Consequences

- Same-input retries do not duplicate entity content or occurrence counts merely because
  the LLM changed wording.
- A partial multi-page attempt can resume without replaying pages already committed.
- Explicit force recompilation can refresh an existing entity page without weakening
  retry safety for a failed force attempt.
- Entity pages accumulate small hidden operation markers; no existing YAML/Markdown
  reader or migration is required.
- Exactly-once identity is currently scoped to the resolved entity page. A future
  compilation journal may preserve the first parsed plan across retries and cover a model
  that changes an entity to an unrelated slug.

## Alternatives considered

- **Exact generated-text comparison:** rejected because model output is non-deterministic.
- **Write the Daily Page marker first:** rejected because later failure would suppress retry.
- **Introduce the full compilation journal now:** deferred to the journal workstream in
  [#868](https://github.com/getyak/daypage/issues/868); it is larger than this foundation
  wave and requires recovery/migration design.
