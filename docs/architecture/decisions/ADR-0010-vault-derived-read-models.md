# ADR-0010: Asynchronous derived read models for the Markdown Vault

- **Status:** Accepted
- **Date:** 2026-08-25
- **Issues:** [#345](https://github.com/getyak/daypage/issues/345),
  [#827](https://github.com/getyak/daypage/issues/827)

## Context

DayPage's raw Markdown Vault is the durable, portable source of truth. That
format is optimized for ownership and interoperability, not for repeatedly
answering aggregate UI queries. A timeline load or full-text search that opens
and parses every `vault/raw/YYYY-MM-DD.md` file grows from hundreds of
milliseconds after one year to seconds after several years.

The first metadata index removed most repeated timeline scans, but its cold
read still performed a synchronous full scan on the main actor. Timeline rows
also reopened an entire day merely to prepare a context-menu preview. Search
could start a second legacy full scan while its background index was already
warming. Finally, external-change validation used the `raw/` directory mtime;
editing an existing child does not reliably update that directory timestamp.

## Decision

### Keep Markdown authoritative; treat indexes as disposable read models

Timeline and search keep independent, in-memory snapshots derived from raw
Markdown. They never become a write path and can always be rebuilt. No database
or persistent index is introduced by this decision.

The snapshots are intentionally independent because their lifecycle and memory
cost differ:

- timeline metadata warms after Vault initialization because Today needs it;
- normalized full-text documents warm only when Search appears, avoiding
  launch-time CPU and memory work for users who do not search.

### Cold reads are asynchronous

No UI-facing read may synchronously scan the whole Vault. Timeline returns the
last immutable snapshot and publishes an update when its first build completes.
Search awaits its one in-flight build asynchronously, then searches memory; it
does not launch a competing legacy scan.

SwiftUI receives stable, newest-first snapshots whose ordering is maintained at
mutation time. Timeline entries include a bounded three-line preview, so
scrolling rows and opening a context menu do not perform per-row file reads.

### Writes update one day off the main actor

`RawStorage.rawStorageDidWrite` identifies the affected date. Each read model
parses only that file on a detached task, cancels an older in-flight refresh for
the same date, and commits the newest result on the main actor. Unknown writes
and conflict merges request a full rebuild.

Writes arriving during a full scan are replayed after the snapshot swap. A
full rebuild cancels older single-day tasks so an obsolete parse cannot
overwrite a newer complete snapshot.

### External validation uses file signatures, not directory mtime

On foreground, a utility task enumerates raw Markdown metadata and compares a
map of filename to `(byteCount, contentModificationDate)`. This detects create,
delete, and ordinary edits to an existing file without parsing content on the
main actor.

A full rebuild captures signatures before and after parsing. If they differ,
the mixed-revision result is discarded and one clean pass is scheduled. This
keeps each published snapshot internally consistent when iCloud or another
editor changes files during a scan.

## Consequences

### Positive

- Today becomes interactive without waiting for years of history to parse.
- Timeline and search do no full-Vault file I/O on the main actor.
- A search cold start performs one scan instead of two competing scans.
- Context-menu previews do not create N additional day reads while scrolling.
- External edits to existing Markdown files invalidate correctly.
- The local-first file format, write path, and recovery properties are
  unchanged.

### Costs

- Timeline history may appear shortly after today's content on a true cold
  launch; the UI must treat “index warming” separately from “empty Vault.”
- Full rebuild cost still grows with Vault size, although it is off-main and
  paid once per lifecycle/invalidation rather than per render or keystroke.
- Timeline and search retain separate derived data and invalidation state.

## Alternatives considered

### Synchronous cold fallback

Rejected. It makes the first launch semantically immediate but blocks touch and
rendering for the users with the largest, most valuable Vaults.

### Build timeline and search together at launch

Rejected for now. It saves a later parse when Search is opened, but eagerly
normalizes every memo and increases launch CPU/memory for a secondary surface.

### Persist SQLite/FTS indexes

Deferred. Persistence can improve very large Vault cold builds, but introduces
schema/version/recovery concerns. It should be considered only with measured
evidence that the asynchronous in-memory design is insufficient.

## Verification

- A cold `TimelineIndex.entries()` returns without disk I/O and later publishes
  the complete snapshot.
- Incremental append, edit, and delete results equal a clean full rebuild.
- An externally added file and an externally edited existing file are both
  detected by foreground validation.
- Indexed search remains result-equivalent to legacy search semantics.
- `swift test --package-path DayPageKit`, the affected `DayPageTests`, and an
  iPhone Simulator build remain required gates.
