# ADR-0018: Backend-first Agent data plane with local-first capture

- **Status:** Accepted
- **Date:** 2026-08-28
- **Issue:** [#916](https://github.com/getyak/daypage/issues/916)
- **Design:** [Backend-first Agent Data Plane](../../design/backend-first-agent-data-plane.md)

## Context

DayPage must keep memo capture available offline and preserve the portable raw
Markdown Vault. At the same time, the Native compiler and Web compiler currently
produce separate writable interpretations, Agent behavior is embedded in one large
pipeline, UTC scheduling does not represent a user's calendar day, and external
effects lack a durable approval/execution boundary.

ADR-0008 already makes Native raw capture local-first and revisioned across Supabase.
ADR-0010 treats local indexes as disposable read models. Neither decision establishes
where AI-derived truth, Agent configuration, scheduled reductions, or external action
receipts live.

## Decision

### Keep raw capture local-first; make intelligence backend-first

Native commits raw memos and attachments locally before networking. Web and MCP commit
raw memos to Supabase first. All paths use the same content hash, monotonically
increasing revision, tombstone, and durable memo-event contract.

Canonical observations, pages, Daily/Weekly reductions, Agent Runs, Automations,
proposals, and tool receipts are backend-owned. Native may cache these artifacts under
`vault/_agent/cache`, but it does not write them into the legacy `vault/wiki` tree when
the backend-first feature flag is active. Existing Markdown remains readable and is
never deleted or silently overwritten during rollout.

### Model execution as independently versioned resources

Agents, immutable Skill versions, Tool definitions and user connections, Automations,
Runs, Run Steps, Artifacts, provenance sources, Work Orders, and the tool execution
outbox have independent database identities and lifecycles.

Every Run snapshots its Agent, Skill checksum, Tool policy, trigger input, and budget.
The canonical memo-run identity is user, memo, accepted revision, and Skill checksum.
Advisory locks and unique constraints make ordinary replay idempotent; an explicit retry
creates a new attempt and demotes the previous canonical attempt without rewriting its
history.

LLM output crosses one versioned JSON envelope. Source spans must belong to the input
memo and stay inside its body. Each step records input/output hashes, duration, token
usage, bounded receipts, and structured errors. Invalid output receives one repair
attempt before the Run fails.

### Reduce artifacts instead of repeatedly re-reading raw history

The immutable, versioned `memo-understand` Skill consumes one accepted memo revision and emits observations, Daily
contributions, page patches, and action proposals. Page reconciliation uses optimistic
locking, bounded retry, idempotency markers, and `needs_review` conflict preservation.

Daily synthesis consumes current contribution artifacts for the user's IANA timezone.
Living updates are coalesced, finalization runs after the local day boundary, and a late
arrival creates a superseding revision. Weekly review consumes at most seven canonical
Daily artifacts and emits narrative, trends, open loops, standouts, reflection prompts,
and proposal-only actions.

Durable events and due Automations enter `gateway_jobs`. Workers claim rows with leases,
`SKIP LOCKED`, retry backoff, and dead-letter state. A memo trigger watches only raw
revision fields so compiler metadata cannot recursively enqueue itself.

### Require explicit approval for external effects

Tool policy combines the definition, Agent binding, user connection scopes, and the
model's requested approval. External and destructive effects can never become automatic
through an override. The `action-plan` Skill only creates proposals.

Approval writes a Work Order and an idempotent execution-outbox row. Execution rechecks
approval, connection status, revocation, and scopes immediately before calling a
registered executor. Receipts are bounded and scrubbed of credential-shaped keys.
Retries are permitted only for tools with a proven provider idempotency contract;
otherwise an uncertain failure becomes terminal rather than risking a duplicate real-
world action.

### Roll out through explicit modes

The server mode is `off`, `shadow`, or `primary`; the safe default is `shadow`. Shadow
Runs write isolated draft artifacts and cannot mutate canonical pages or propose actions.
The legacy compiler remains enabled unless primary mode or an explicit override disables
it. Native has a separate default-off feature flag and switches both its request path and
read projection together.

Database changes are additive. Rollback stops schedulers/workers and returns the feature
flags to legacy paths without deleting raw data, Run history, artifacts, or receipts.

## Consequences

- Offline capture and Vault portability remain intact.
- A single backend history explains what ran, against which revision, with which sources,
  model policy, costs, proposals, approvals, and receipts.
- Daily/Weekly behavior follows the user's calendar rather than UTC boundaries.
- Native may temporarily show “processing” after local capture because raw durability and
  derived intelligence are honestly separate states.
- The data plane adds tables, worker operation, artifact storage, and connector lifecycle
  costs. It intentionally does not make a generic LLM an unrestricted autonomous actor.
- Connector-specific executors still require separately reviewed integrations; an absent
  executor cannot truthfully produce a success receipt.

## Alternatives considered

- **Move raw capture to server-only:** rejected because offline capture and Vault
  ownership are primary product invariants.
- **Keep two writable compilers and reconcile later:** rejected because no conflict rule
  can establish one trustworthy derived history.
- **Run Daily directly over all raw memos:** rejected because it duplicates understanding,
  increases cost, and makes source-level provenance harder to retain.
- **Allow automatic external writes for convenience:** rejected because model output,
  stale authorization, retries, and provider ambiguity can cause irreversible effects.
- **Overwrite legacy wiki files with backend output:** rejected because it makes rollout
  destructive and obscures which system authored existing user-visible files.

## Verification

Release gates include:

- schema migration, constraints, grants, and negative cross-tenant RLS checks;
- exactly-one memo revision enqueue and no compiler-metadata feedback loop;
- canonical Run idempotency and explicit retry attempts;
- source-span bounds and artifact provenance;
- optimistic page version conflicts without lost updates;
- authenticated client reducer RPC coalescing;
- proposal approval, revoke/scope recheck, outbox leases, and bounded receipts;
- timezone/DST and Daily/Weekly boundary fixtures;
- Native cache/RPC contract tests, full DayPageKit tests, and an iOS Simulator build;
- Web/MCP type checks and focused runtime tests before each rollout-mode promotion.

Production mode changes, migrations, backfills, and connector activation remain separate
operational changes and are not authorized by this ADR alone.
