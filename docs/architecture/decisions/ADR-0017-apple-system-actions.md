# ADR-0017: Local-first Apple System Actions with native confirmation and receipts

- **Status:** Accepted
- **Date:** 2026-08-26
- **Implementation issue:** [#887](https://github.com/getyak/daypage/issues/887)
- **Extends:** [ADR-0008](ADR-0008-local-first-sync-and-cloud-mcp.md),
  [ADR-0009](ADR-0009-native-surfaces-shared-contracts.md)
- **Related:** [#876](https://github.com/getyak/daypage/issues/876) and
  [ADR-0012](ADR-0012-action-button-screenshot-capture.md) own screenshot ingress;
  this decision owns the shared action boundary that receives its suggested actions.

## Context

DayPage already reaches several Apple system surfaces: App Intents and shortcuts,
WidgetKit and Control Center, local notifications and AlarmKit, Core Location, Photos,
MapKit, Watch capture, and the local Markdown Vault. It also exposes a user-scoped Cloud
MCP over Supabase OAuth/PAT and RLS. These capabilities are useful but do not yet form a
safe product contract for an agent that recognizes an actionable moment and wants to
create a calendar event, reminder, contact, route, focus session, or capture operation.

A direct “agent calls EventKit” design would collapse distinct trust boundaries:

- an agent suggestion is not a user decision;
- a cloud grant is not device OS authorization;
- a database acknowledgement is not proof that an Apple store changed;
- Apple side effects and Postgres cannot participate in one atomic transaction;
- Calendar and Contacts identifiers can be device/container scoped and can change;
- private memo, contact, photo, health, and location values must not leak into a widget,
  Live Activity, Spotlight index, diagnostic event, or cross-device receipt.

The existing raw Vault contract must remain unchanged. Action execution and undo are
operational state, not memo YAML. Conversely, keeping every action only in volatile UI
state would make approval, retry, crash recovery, and audit claims untruthful.

## Decision

Adopt a **proposal -> native decision -> device execution -> immutable receipt** model.
Agents and inference providers may create bounded proposals. Only a native DayPage
surface can record a user decision. Only a device adapter can call an Apple Framework.
Every attempted external effect produces a local per-item receipt and a recoverable
execution state before any cloud acknowledgement is shown.

```text
agent / local inference / system entry
                 |
                 v
        versioned ActionProposal
                 |
        native preview + edit
                 |
         exact user decision
                 |
      durable device execution claim
                 |
        Apple Framework adapter
                 |
        immutable ActionReceipt
                 |
       sync / reconcile / undo
```

### 1. Four sources of truth remain distinct

| Boundary | Authoritative state | Explicitly not authoritative for |
| --- | --- | --- |
| Markdown Vault | Memos, Daily Pages, and user-authored content | Apple actions, approvals, OS permissions |
| Local action ledger | Proposals, decisions, pending/executing state, receipts, reconciliation, device undo material | Actual Calendar/Contacts/Notification resources |
| Apple Framework store | The external event, reminder, contact, notification, Live Activity, or route launch | DayPage approval history or cross-device policy |
| Supabase/Postgres | Authenticated replica, MCP query/proposal boundary, monotonic changes, exact sync receipts, execution leases | Memo capture truth, OS permission, raw external identifiers |

The action ledger lives under DayPage-owned operational metadata at
`vault/_agent/system-actions/`. It is versioned, replaceable from durable records where
possible, excluded from user content, and never changes raw Markdown bytes. A local-only
Vault can use every native action without signing in; cloud sync is additive.

OS authorization is observed live on the executing device. A synced capability policy
can express “offer calendar suggestions” or “show contact actions,” but it never contains
or implies `authorizationStatus`. Another device must request its own permission just in
time.

### 2. The shared contract is typed, versioned, and framework-neutral

`DayPageModels` owns value types with no UIKit, SwiftUI, EventKit, Contacts, HealthKit,
or other Apple Framework types:

- `SystemActionProposal`: stable UUID, kind, schema version, revision, payload, payload
  hash, title/rationale, source references, creator/source, redaction policy, target
  device preference, creation/expiry timestamps, and lifecycle state.
- `SystemActionDecision`: proposal UUID, exact revision and payload hash, approve/reject,
  decision timestamp, device, and optional edited replacement proposal.
- `SystemActionReceipt`: stable UUID, proposal UUID, phase (`execute` or `undo`), attempt,
  outcome, device, bounded result, error code, reconciliation state, and timestamps.
- `SystemActionCapabilityPolicy`: whether a capability is offered/synchronized and its
  disclosure level, never OS authorization.
- typed payloads for calendar event, reminder, contact draft, notification, route,
  capture, focus session, moment, and local context attachment.

The supported action-kind enumeration is closed per schema version. Within the v1
envelope, an unknown `kind` decodes locally as an unsupported record that remains visible
and rejects execution. The v1 cloud contract intentionally rejects unknown schema
versions and unknown kinds at its boundary; a future schema therefore requires an
explicit opaque-envelope migration before older cloud clients can preserve it. Source
references use DayPage-owned memo/page/entity identifiers and are bounded in count.
Payloads have canonical encoding, byte limits, and SHA-256 hashes.

Apple adapters implement framework-neutral ports in `DayPageServices`. They convert Kit
DTOs at the target boundary and do not choose policy, write the Vault, or silently
request broader access. App Intents, widgets, controls, and screens invoke the same use
cases rather than duplicating execution logic.

### 3. Approval binds to exact content

Approval records both proposal revision and payload hash. Editing any executable field
creates a new revision and invalidates older approval. Display-only rendering differences
do not change the hash; every value that can affect the external resource does.
The v1 wire record expresses replacement as the standard-schema-validatable boolean
`has_replacement`. A true rejected decision always means “a next revision of this same
proposal”; Swift and Postgres derive the same proposal UUID internally rather than
accepting a second cross-field UUID that ordinary JSON Schema could not bind.

An agent, MCP client, background job, widget timeline, notification response, or another
device cannot approve on the user's behalf. A shortcut may capture or open review, but a
proposal that changes Calendar, Contacts, Reminders, notifications, HealthKit, or another
external store must reach the native confirmation boundary unless an individual,
reversible, user-created automation policy was explicitly configured for that action
kind. Initial delivery does not include silent automation policies.

Multi-action suggestions are a list of independent proposals. Execution produces one
receipt per item. A partial failure never rolls back unrelated successful items or claims
the batch was atomic. Retry targets only failed or ambiguous items.

### 4. Local durability precedes every side effect and success claim

The coordinator persists a pending execution record before calling a native adapter.
After framework success, it immediately writes the local receipt and device-scoped undo
material before attempting remote sync. UI success means the local receipt is durable;
remote state is shown separately. A transient receipt-upload failure never rewrites a
confirmed native success as a framework failure.

Offline expiry is checked before a claim record or `executing` lifecycle is persisted.
If the expiry boundary is crossed between planning and authorization, that unused local
plan is rolled back to `approved`. Online preparation deliberately defers expiry to the
server: approval admissibility uses database time and execution uses the lease's
server-issued time, never an untrusted client decision clock.

For online multi-device coordination, the server issues a short execution lease bound to
tenant, proposal, phase, revision, payload hash, and device. A valid exact approval is
required before a lease. Offline execution is allowed only on the creating device,
except that a `specific_device` proposal uses its explicit target. An `any` proposal
without a native creator (including every MCP proposal) cannot execute offline. While
an unreceipted lease exists, including after its nominal expiry, competitors remain busy;
an exact retry is executable only while the server still considers the lease active, and
after expiry the same operation also receives `busy` and may only reconcile and publish
terminal evidence against its original lease. A reconciler never re-claims merely to write
that first terminal receipt; only a previously receipted non-success resolution uses a new
operation and lease. The server-issued
lease time becomes `started_at`, avoiding device clock-skew rejection after a native
effect. Once any lease or receipt exists, proposal revision, targeting, and provenance
are permanently frozen so the eventual receipt always binds to the executed tuple.
If synchronized product policy is revoked after the lease is issued, no new claim may be
created, but the exact already-leased receipt is still accepted as terminal evidence so
the lease cannot be stranded by the revocation.

This design does not promise a distributed exactly-once transaction. A process may die
after the Apple store changes and before a receipt is committed. Each adapter therefore
provides a reconciliation strategy:

- EventKit embeds a bounded DayPage action marker in a URL/structured field and searches
  only the narrow expected interval when full access is available; otherwise ambiguity
  requires user review.
- UserNotifications uses a deterministic request identifier derived from the action ID.
- ActivityKit persists its activity ID locally and reconciles active activities.
- Contacts stores raw identifiers only locally and treats an unprovable post-crash save
  as ambiguous; it never blindly creates a second contact.
- route launch and foreground capture cancellation are explicit non-durable/cancelled outcomes.

Exact retry of a committed operation returns its historical receipt. Reusing an
operation ID with another entity, kind, revision, phase, or payload fingerprint fails
closed.

### 5. Undo is device-scoped and honest

Undo is a separate approved phase with its own receipt and execution lease. It can run
only on the device holding the original external identifier and before-snapshot. The
cloud stores a hash of that identifier for correlation, never the raw value.
The server independently verifies that the undo claimant and receipt device match the
successful execute receipt for the same proposal revision and payload hash.

An adapter declares one of these rollback capabilities:

- `reversible`: deterministic delete/cancel/end using local execution material;
- `compensating`: creates a visible reverse operation rather than restoring identity;
- `manual`: opens the relevant system UI with an explanation;
- `none`: the effect cannot be undone by DayPage.

Calendar, Reminder, and Contact creation persist an exact device-local snapshot of the
fields DayPage wrote, including Reminder seconds and subsecond components. If an
identifier changed after synchronization or the current system object differs from that
snapshot, undo becomes `needsReview` and performs no deletion; it never reports success
merely because the local row was removed.

### 6. Backend schema and RLS are an RPC-only mutation boundary

Drizzle migration `0030_system_actions.sql` owns six relations:

- `system_action_proposals`: current versioned proposal snapshot and tombstone;
- `system_action_approvals`: immutable decision bound to proposal revision/hash;
- `system_action_receipts`: immutable execute/undo results;
- `system_action_capability_policies`: synchronized DayPage product policy;
- `system_action_sync_operations`: exact idempotency receipts and request fingerprint;
- `system_action_execution_leases`: short-lived coordination, excluded from pull.

Durable action objects use an independent global monotonic change sequence. Pull pages
merge proposals, decisions, receipts, and policies by sequence; tenant cursors need not
be contiguous. Mutable snapshots carry tombstones so deletions converge.

All tables revoke privileges from PUBLIC, `anon`, and `authenticated` before granting
the minimum tenant SELECT access. Direct client INSERT, UPDATE, DELETE, and TRUNCATE are
forbidden. Versioned apply, pull, and claim RPCs derive the tenant only from `auth.uid()`,
fully qualify objects, pin `search_path`, enforce limits and the state machine, and are
covered by two-tenant negative tests. Sync receipts and execution leases are not directly
selectable unless an RPC needs to return a bounded result.

The existing `sync_operations` receipt table receives the same privilege hardening:
authenticated callers may use the existing sync RPC but cannot mutate or truncate
receipts directly.
The backend also treats capability policy as an authorization boundary, not metadata:
proposal, decision, and claim paths atomically require each payload-derived capability
to have an active, offered, synchronized, nondeleted `full_proposal` policy. Receipt
apply normally enforces the same boundary, with one narrow exception for terminal
evidence bound to an exact lease issued before a later revocation. Payloads whose
required-capability set is empty remain device-local.

The native outbox preserves sequential policy revisions and backfills the complete
proposal-revision, decision, and receipt causal chain when full synchronization is
enabled. It removes only exactly acknowledged envelopes. A validated permanent rejection
quarantines that one envelope fingerprint so unrelated actions continue, while the
immutable local ledger record remains available for audit and user review.
For mutable proposal and capability-policy races, and for the one-decision-per-phase
replacement boundary, that rejection also records the exact stable key and revision. The
next authenticated pull may then adopt the same-revision server proposal/policy/decision
winner and advance its cursor; an unrelated same-revision mismatch remains a hard conflict.
Existing local execution or receipt evidence is never overwritten and instead moves the
proposal to `needsReview`. Receipt attempt ordinals are unique per executor identity rather
than globally: an exclusive lease prevents simultaneous effects, while two sequential
devices that both used ordinal N retain both immutable device-bound receipts. Native
recovery associates a receipt with a persisted execution only when the normalized executor
device matches and, once known, the lease matches; another device's same-ordinal receipt
cannot advance the local counter or consume the interrupted local lease.

### 7. MCP proposes but never decides or executes

The Cloud MCP adds only:

- `daypage_propose_action`;
- `daypage_list_action_proposals`;
- `daypage_list_action_receipts`.

It never exposes approve, reject, execute, undo, OS permission, external identifier, raw
contact, raw health, photo byte, or precise-location tools. Tool output states that a
proposal is pending native user review. Action access uses separate, default-off
`can_read_actions` and `can_propose_actions` grants; existing `can_write` memo access does
not imply either permission. OAuth continues through caller JWT + RLS. PAT requests use
the fixed security-definer RPC and the same action grant checks, without a service-role
credential.
Historical PATs carrying the legacy `admin` scope retain their pre-existing memo
compatibility, but `admin` implies neither action scope. The owner must issue or rotate
to a PAT with an explicit `actions:read` or `actions:propose` grant.
MCP proposals are fixed to `private` redaction until a native approval; an agent cannot
opt its own pre-approval title or rationale into broader surfaces.
OAuth consent and reconnect use an owner-only RPC that always resets action grants to
their default-off state. A separate owner settings RPC enables them explicitly; revoke
atomically clears memo read/write and both action flags.

### 8. Permission and privacy are capability-specific

DayPage requests permission only in response to a concrete confirmed interaction:

- Contacts selection uses the system picker/limited APIs without full-store access.
  Confirmed contact creation requests write access just in time and saves the exact
  approved fields directly; no mutable post-approval editor can change the payload.
- Photos imports use `PhotosPicker`; saving an export requests add-only access. The app
  does not scan the recent library merely to show a composer strip.
- Calendar creation uses iOS 17+ write-only access or the iOS 16 legacy event grant,
  then saves the exact approved event directly. Full read access is reserved for undo
  and separately enabled conflict/read behavior.
- Reminders full access is requested only after the user confirms reminder creation.
- Location When In Use is requested for a one-shot moment. Always access is requested
  only after enabling visit automation with a separate explanation.
- HealthKit is read-only, minimum-type, explicitly opt-in, and derives local summaries.
  Health samples never enter the cloud ledger or agent context by default.
- Watch audio is moved to a content-addressed phone asset and paired with a protected,
  durable inbox obligation before raw memo append. Append/queue failure retains that
  obligation across protected-data changes and relaunch; a delivered tombstone prevents
  orphan recovery from recreating an already materialized memo.
- Rejecting a Moment writes a protected, exact proposal-revision cleanup intent before the
  ledger rejection. Restart cleanup verifies that immutable rejection before deleting;
  an uncommitted intent is cancelled and preserves the draft. The manifest is retained
  until its staged photo is removed, and failed cleanup is surfaced and replayed.
- Focus pause/end update the Live Activity before removing its alert surface. Resume
  schedules the alert first and compensates by cancelling it if ActivityKit update fails;
  AlarmKit cancellation errors propagate as ambiguous evidence instead of being swallowed.
- MapKit receives the exact already-approved destination label, including valid
  whitespace and the full 240-byte contract boundary; adapters do not normalize it again.

Diagnostics contain action kind, state, latency, bounded error code, and correlation ID.
They exclude proposal text, memo bodies, contact values, coordinates, health samples,
photo/OCR content, framework identifiers, and provider payloads.

Spotlight, widgets, notifications, controls, and Live Activities expose bounded titles,
times, counts, and privacy-sensitive placeholders. Signing out, disabling indexing, or
deleting an owned entity clears the user-scoped index/snapshot without deleting Vault
content.

### 9. Platform availability is layered, not raised globally

The iOS app remains deployable to iOS 16.1 and DayPageKit to iOS 16:

| Capability | Base/fallback | Newer enhancement |
| --- | --- | --- |
| Calendar | iOS 16.1 legacy event access and exact direct save | iOS 17 write-only exact save |
| Contacts | JIT access and exact direct save | iOS 18 limited selection controls for context |
| Spotlight | Core Spotlight items | iOS 18 `IndexedEntity` |
| Widget | iOS 16.1 deep links/timeline | iOS 17 interaction, iOS 18 controls |
| Focus activity | ActivityKit iOS 16.1 | iOS 17 LiveActivityIntent, iOS 18 controls |
| Reminder alert | UserNotifications | AlarmKit on iOS 26 where available |
| Photos | PhotosPicker selected items | platform-specific transfer improvements |

Availability is guarded both where a type is constructed and where a bundle registers a
configuration. Apple Framework types stay out of pure Kit targets so macOS, watchOS, and
package builds do not inherit unsupported SDK requirements.

The App, Widget, and #876 Share Extension use one App Group for small versioned inbox
envelopes and privacy-minimized widget/activity snapshots. They never expose the raw Vault
through shared `UserDefaults`. The widget target is lowered to iOS 16.1; high-version
configurations remain conditionally registered.

### 10. Local execution does not depend on cloud availability

The composition root binds the ledger to a stable, hashed device-local identity while
signed out and to a hashed authenticated identity while signed in. Crossing that identity
boundary enters a durable quarantine, clears action state and derived system surfaces, and
only then publishes the new binding. This prevents one user's outbox, capture inbox,
Moment records, widget snapshot, or Spotlight records from being reused by another.
Explicit sign-out first closes the coordinator barrier while the old authenticated token
is still available, waits for active sync/claim/adapter/receipt work, and proves the ledger
is erasable before asking Supabase to revoke that identity. A ledger holding a remote claim/lease without
an authenticated server-confirmed terminal receipt refuses the explicit sign-out before
token revocation: the old identity remains bound, quarantine stays off, and the coordinator
barrier reopens so sync or reconciliation can finish. Quarantine is reserved for an identity
that was already revoked or otherwise changed externally before cleanup could be proven;
re-entering that same identity can then clear derived surfaces and resume reconciliation
without discarding evidence.

Execution selects the remote lease path only when all three conditions are true at the
decision point: an authenticated session exists, the network is considered available, and
every payload-required capability has an active `full_proposal` policy. A missing,
deleted, redacted, private-only, or partially configured policy fails closed to the local
owner path. A response loss after remote selection never silently changes that already
persisted attempt to offline execution.

Proposal revisions preserve the original `createdAt`; only the revision, payload hash and
new lifecycle timestamps change. This keeps Today grouping and historical provenance
stable while invalidating the old exact approval.

### 11. Native input and output surfaces share one runtime handoff

The iOS experience presents the same ledger through an in-context Today card and a four
section Action Center (`Pending`, `Today`, `Automations`, `Receipts`). The review sheet
shows executable fields, revision/hash binding, per-field changes, permission timing,
target device, executor mode, reconciliation state, and item-level undo eligibility.
The System Access screen reads current framework authorization on the device; no status is
copied from capability policy or another device.

System entry points are deliberately thin:

- App Intents, widgets, controls, Spotlight identifiers and deep links carry bounded
  entity IDs or draft parameters and return to the same foreground coordinator;
- the #876 bridge accepts only a versioned, reference-only Share inbox envelope. It cannot
  carry source bytes, OCR text, a URL, memo content, or executable payload;
- Focus Live Activity pause/resume/end intents update the visible activity immediately,
  then write a one-shot App Group command containing the action ID and captured remaining
  time. The foreground app peeks rather than consumes that command, owns cancellation and
  re-arming of the matching alert, and acknowledges only the exact command after the
  operation succeeds; a failed handoff therefore remains retryable;
- on iOS 26 a confirmed Focus end alert uses AlarmKit when JIT authorization succeeds,
  otherwise exactly one deterministic local notification is scheduled. The receipt stores
  which surface was used, reconciliation checks only that surface, and cleanup cancels
  both possible identifiers without rescheduling;
- passive visit monitoring has a separate persisted product opt-in in addition to the OS
  grant. Only the Automations surface can request Always location for this behavior;
  disabling it stops monitoring even if iOS retains authorization. Spatial/time-bounded
  upsert rules deduplicate Core Location arrival/departure replays before showing a draft.

### 12. Capture and local context remain recoverable and intentionally filed

Capture Studio writes selected photos, camera images, files, document scans, recognized
text, voice, and PencilKit drawings to a file-protected DayPage inbox. It durably writes a
bounded manifest before returning success, validates regular-file/type/size invariants on
read, and exposes explicit preview, discard, “attach to verified source memo,” and “file as
new memo” operations. Filing uses deterministic memo/asset identifiers and the existing
atomic Vault/outbox path, so crash recovery cannot duplicate the memo or attachment.
Deleting an inbox copy never deletes a filed memo or Vault attachment. Identity
transitions clear only the scoped inbox.

Moment uses a separate protected device-local draft store. PhotosPicker data, one-shot
coordinates, and contact reference hashes stay local; the cloud action contains only the
bounded proposal fields permitted by policy. The user explicitly saves the draft before a
proposal exists, and rejection/cancellation discards that draft and its staged photo.
HealthKit and WeatherKit produce
bounded local-context records referenced by UUID; raw samples, raw provider responses and
coordinates are not serialized into the cloud proposal or receipt.

Notification delivery uses the exact privacy-bounded title/body shown at approval; the
framework client does not apply a second truncation or newline rewrite afterward. Watch
voice transfers use a content SHA-256 transfer identity plus a stable creation timestamp;
reconnect retries reuse an existing asset/memo and never overwrite a prior asset path.

## Consequences

### Positive

- An external or in-app agent can help without becoming a silent authority over private
  system data.
- Every accepted effect has a user-visible proposal, exact decision, result, and honest
  recovery/undo story.
- DayPage remains useful offline and without an account.
- Framework adapters are testable behind ports and do not pollute shared models.
- MCP, native UI, widgets, shortcuts, and future automation reuse one contract.
- The raw Vault remains readable and byte-compatible.

### Costs

- Proposal, decision, execution, receipt, and sync states create more objects than a
  direct API call.
- Cross-store crashes require adapter-specific reconciliation and sometimes user review.
- Manual Xcode target membership and App Group signing increase integration risk.
- Real Contacts, EventKit accounts, Siri/Spotlight discovery, background visits, camera,
  lock-screen/Dynamic Island, HealthKit, AlarmKit, and Watch behavior still require
  matching-OS or real-device evidence beyond Simulator tests.

## Alternatives considered

### Let MCP or the backend execute Apple actions

Rejected because Apple Framework stores and permissions are device-local, and the server
would need credentials or authority it should not possess.

### Treat a cloud proposal as approved on every device

Rejected because user intent and OS authorization are device/context specific. It also
permits a compromised agent grant to cause external effects.

### Store actions in `task_suggestions`, `change_log`, or memo YAML

Rejected. Those tables serve other product semantics and do not preserve exact native
approval/receipt invariants. Memo YAML is user content and cannot safely carry
device-scoped external identifiers or operational retry state.

### Use a single polymorphic action row

Rejected because mutable state would overwrite the evidence proving which payload the
user approved and which execution/undo result occurred. Separate immutable decisions and
receipts keep the audit trail verifiable.

### Promise exactly-once Apple effects

Rejected because there is no atomic transaction across an Apple Framework and Postgres.
The accurate contract is durable idempotency where the framework supports it, short
leases across online devices, and explicit reconciliation/ambiguity elsewhere.

### Request every permission during onboarding

Rejected because it asks for sensitive access before intent exists, increases denial,
and contradicts data minimization. Onboarding may explain capabilities but does not
trigger permission prompts.

## Rollout and verification

Delivery proceeds in coherent vertical slices without changing the acceptance scope:

1. canonical schemas, ADR, Kit model/ledger/coordinator, raw-Vault byte-isolation tests;
2. backend migration/RLS/RPC/MCP, empty local Supabase verification, privilege hardening;
3. Calendar/Reminders/Notifications/Contacts adapters and proposal-review-receipt UI;
4. AppEntity/CoreSpotlight, widgets/controls, App Group bridge, #876 integration;
5. Moment, Photos, Map, Vision/Pencil, Location, Focus Activity, Health/Weather context;
6. accessibility/localization/privacy, cross-target builds, Simulator and device matrix.

Every named module and user flow is scored independently. Overall acceptance is the
minimum score, not an average. It requires every row at least 95/100, no automatic-fail
condition, two consecutive clean-context QA passes on the same clean candidate SHA, and
an independent evidence review.

Automatic failure includes cross-tenant access, direct receipt mutation, unapproved
execution, duplicate external creation without reconciliation, action execution or undo
changing raw Vault bytes, missing usage descriptions/privacy manifests, privileged
credentials in a client, private content in logs/system surfaces, an unavailable required
system entry, or a mandatory check that is skipped or masked by a successful wrapper.

Rollback disables proposal sync and native executor composition while preserving the
local ledger and immutable receipts. Database objects are additive and remain until a
separately reviewed cleanup migration. Stopping an adapter never deletes Vault content or
marks a pending proposal successful.
