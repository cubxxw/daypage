# ADR-0015: Stable memo-detail identity and bounded media presentation

- **Status:** Accepted
- **Date:** 2026-08-26
- **Issue:** [#882](https://github.com/getyak/daypage/issues/882)

## Context

Opening a memo detail crossed several unsafe boundaries at once. Navigation
carried an ID that was resolved against a mutable Today or Daily list, while
the destination retained that list's view model for editing and deletion. A
list refresh could therefore invalidate an in-flight destination. Today and
Daily also used different route types and persistence implementations.

The detail view was a single 1,500-line component that synchronously coupled
navigation, Vault writes, entity lookup, full-Vault echo retrieval, EXIF
parsing, full-resolution image decoding, editing, and presentation. Imported or
externally edited Markdown can contain non-finite durations, invalid
coordinates, unsafe attachment paths, and numeric EXIF values that are finite
but outside `Int`'s range. One historical crash converted a reciprocal shutter
value directly to `Int`; opening several original photos could also create a
decoded working set large enough for iOS to terminate the process.

## Decision

### Navigate by stable record identity

Every memo entry point pushes one `MemoDetailRef` containing the memo UUID, its
owning day, source semantics, and optional presentation hint. The destination
does not resolve against a mutable list snapshot.

`MemoDetailHost` resolves the current record through `MemoRecordStore`, owns
loading/unavailable state, and supplies async edit/delete operations to the
presentation layer. `MemoRecordStore` uses `RawStorage.mutate`, so each
read-transform-write and outbox update is serialized at the storage boundary.
Today and Daily observe `rawStorageDidWrite` and rebuild their independent read
models after a committed mutation.

### Validate permissive Vault values at the presentation boundary

The Markdown schema remains unchanged. `MemoPresentationSafety` validates
floating-point conversion, duration, geographic bounds, and Vault-relative
attachment paths. Invalid optional presentation data is omitted or shown as an
unavailable attachment; it never causes a data migration or destructive
rewrite.

All EXIF numeric formatting goes through `PhotoMetadataService` and
`MemoExifFormat`. `Int(exactly:)` after rounding rejects NaN, infinity, and
finite values outside the representable integer range.

### Decode display-sized images

Attachment surfaces use `AttachmentImagePipeline`, which reads directly with
ImageIO and creates transformed thumbnails capped at 4,096 pixels. The
process-wide `NSCache` is costed by decoded bytes, limited to 96 MB, and purged
on memory warnings. Original Vault assets remain untouched.

### Separate authoritative and derived concerns

The detail presentation is split into a storage host, body editor, attachment
sections, metadata, photo views, echoes, and a small shell. Entity names, photo
headers, and echoes are disposable derived data. Echo retrieval reuses the
asynchronous `SearchIndex` snapshot instead of scanning every raw Markdown file
whenever a card opens.

## Consequences

### Positive

- A Today/Daily refresh cannot invalidate an already-pushed memo route.
- Detail mutations share one atomic storage contract and surface failures.
- Malformed optional metadata degrades locally instead of terminating the app.
- Photo memory cost is bounded by display needs and an explicit cache budget.
- Detail entry no longer performs a new full-Vault scan.
- Component ownership is narrow enough for targeted tests and future changes.

### Costs

- A pushed detail performs one authoritative day-file read before rendering.
- Today and Daily may briefly show their previous snapshot until the write
  notification reload finishes.
- The image cache can evict aggressively after a memory warning, causing a
  later image to decode again.

## Alternatives considered

### Carry the full `Memo` in navigation

Rejected. It avoids the destination read but turns the route into a stale
snapshot and makes deletion/edit races ambiguous.

### Keep list view models as the mutation interface

Rejected. It preserves duplicate write implementations and couples a durable
record operation to whichever screen happened to open it.

### Predecode original images

Rejected. It optimizes zoom latency at the cost of unbounded memory and makes
multi-photo details most likely to be terminated by jetsam.

### Persist a separate detail database

Rejected. The Markdown Vault remains authoritative; the current latency does
not justify a second durable source of truth.

## Verification

- `MemoPresentationSafetyTests` cover non-finite/out-of-range integers,
  duration, coordinates, and path traversal.
- `MemoRecordStoreTests` cover stable-ID load, atomic edit/delete, sibling
  preservation, missing records, and rejected empty bodies.
- `MemoExifShutterTests` cover zero, NaN, infinity, least-nonzero, and
  greatest-finite EXIF inputs.
- `AttachmentImagePipelineTests` verifies a 1,600 x 1,200 source decodes within
  a 320-pixel bound.
- The complete DayPageKit suite, focused iOS tests, iOS Simulator build, and
  simulator launch/log inspection are required gates.
