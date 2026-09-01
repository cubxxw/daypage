# ADR-0019: Agent evaluation and learning plane

- **Status:** Accepted
- **Date:** 2026-09-01
- **Issue:** [#916](https://github.com/getyak/daypage/issues/916)
- **Depends on:** [ADR-0013](ADR-0013-privacy-safe-operational-diagnostics.md), [ADR-0018](ADR-0018-backend-first-agent-data-plane.md)
- **Runbook:** [Agent Evaluation runbook](../../agent-evaluation-runbook.md)

## Context

DayPage does not have one universally correct response. The important decision often
happens before prose generation: classify the entry, choose `silent`, `light`,
`reflect`, or `act`, retrieve the smallest useful context set, and keep external effects
and durable Memory changes proposal-only. A final-answer-only score cannot locate which
decision failed, and delayed product metrics cannot safely distinguish a useful quiet
response from an ignored bad response.

The Agent Data Plane already records immutable Run and Step snapshots. It needs a
corresponding evaluation plane that supports immediate deterministic checks, explicit
user feedback, offline regression experiments, human review, and longitudinal case
mining without turning private memo content into routine telemetry.

## Decision

### Keep DayPage authoritative and treat Opik as an asynchronous projection

DayPage Postgres stores feedback events, evaluator results, failure-derived case
candidates, experiment summaries, and an evaluation export outbox. A provider outage
must not fail note processing or lose user feedback. The worker projects traces, spans,
and scores to Opik after the DayPage transaction succeeds, with leases, idempotency,
bounded retries, and dead-letter state.

The stable trace identity is the DayPage Run ID. Run Steps become spans; feedback and
evaluator results become named scores. Skill checksum, immutable Skill version, model,
mode, token counts, status, and privacy mode are trace metadata. Synthetic offline
cases become a version-qualified Opik Dataset; model/prompt changes become Experiments.
Opik prompt versions are linked to uploaded experiments.

### Evaluate the decision stack, not only the reply

The `memo-understand` output contract includes intent, response policy, an exhaustive
decision for every supplied context candidate, selected context IDs, grounded response
claims, proposed actions, and confirmation-required Memory proposals. Production
processing always runs deterministic invariants for response-policy consistency,
action and Memory confirmation, context-selection integrity, source bounds, and reply
budget.

Offline cases score routing, context precision/required recall, forbidden context,
tool selection, confirmation, date grounding, web-search policy, Memory policy and
support, response content/restraint, and source spans. Safety and privacy metrics are
hard gates. A separately invoked LLM Judge scores intent understanding, added value,
grounding, depth calibration, restraint, non-redundancy, and style fit on a 0–4 rubric.
The judge is not enabled on routine production content.

### Version cases and mine failures under an explicit privacy workflow

The checked-in `daypage-core-1.0.0` dataset contains 148 bilingual and adversarial
cases across routing, context, response, action, Memory, Daily, longitudinal, and safety
categories. Each case declares allowed policy, required/relevant/forbidden context,
required/forbidden actions, Memory expectations, textual constraints, and forbidden
behaviors rather than one canonical paragraph.

High-signal feedback creates a private case candidate. Private text is never
automatically copied into a shared dataset. A candidate must be synthesized, explicitly
consented, or redacted and approved before promotion. Opik annotation queues are an
operator-invoked review surface; DayPage remains the record of candidate privacy and
review state.

### Preserve feedback semantics

Feedback is append-only at the application boundary and idempotent. Exact events are
stored before semantic projection. `action.accepted`, `memory.confirmed`, and
`response.saved` are strong adoption signals. `response.dismissed` is an occurrence,
not automatically a negative quality label. Edits, corrections, “not relevant,” and
style blocks are failure-mining signals and preserve structured correction evidence.

Authenticated clients cannot write evaluation tables directly. They submit feedback
through a tenant-derived API that verifies the Run and optional Artifact or Work Order
belong together. External or destructive actions and long-term Memory continue to
require confirmation independently of any evaluation score.

### Gate promotion with absolute and paired-regression checks

Every report is schema-versioned and records the dataset version, case count, model,
prompt checksum, timestamps, tokens, output, evaluator evidence, and execution errors.
Promotion requires 100% execution success, all safety hard gates, configured minimum
metric averages, and no greater than a two-percentage-point regression from an optional
baseline. A failed model call or invalid structured output counts as a failed case.

## Privacy modes

Evaluation export defaults to `off`.

- `metadata_only`: exports identifiers, hashes, state, counts, model/Skill metadata,
  timing, and token usage; it exports no memo, prompt, or artifact body.
- `redacted`: recursively removes credential-shaped keys and redacts common email,
  phone, URL-credential, and token patterns.
- `full_content_opt_in`: exports content only when the server mode is enabled and the
  owning user has an explicit `user_settings.settings.evaluation.full_content_opt_in`
  flag. Otherwise it degrades to metadata-only.

User IDs are replaced by a salted stable pseudonym. Routine logs remain content-free.
These controls reduce exposure; they are not a claim that pattern redaction can make
arbitrary private text anonymous.

## Consequences

- A poor response can be attributed to routing, retrieval, generation, action policy,
  grounding, or Memory behavior instead of receiving one opaque score.
- The product creates immediate behavior labels and durable correction evidence while
  avoiding the false inference that every click or dismissal means quality.
- Offline model/prompt changes are reproducible and block promotion when safety or
  baseline quality regresses.
- Opik can be replaced or disabled without losing DayPage's authoritative history.
- Evaluation adds database rows, outbox traffic, review work, synthetic-case
  maintenance, and optional judge cost. It does not authorize automatic training on
  private notes or automatic production prompt promotion.

## Alternatives considered

- **Store traces only in Opik:** rejected because provider availability, retention, and
  privacy configuration must not control DayPage correctness or feedback durability.
- **Use click-through as the quality score:** rejected because dismissal and silence are
  ambiguous and can reward overactive responses.
- **Judge only the final text:** rejected because context contamination and unsafe action
  selection can hide behind fluent prose.
- **Run an LLM Judge on every production memo:** rejected because cost, latency, privacy,
  and correlated model error make it inappropriate as a default online invariant.
- **Automatically promote negative feedback into a dataset:** rejected because raw
  failure examples can contain highly private user content.

## Verification

Release evidence includes schema/type validation, 148 golden-case deterministic
results, evaluator mutation tests, privacy redaction tests, feedback projection tests,
promotion and baseline-regression tests, transactional database RLS/constraint tests,
Web type checking, lint/build checks, and an explicitly configured Opik smoke test when
that external service is part of the target environment.
