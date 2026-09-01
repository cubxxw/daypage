# Agent Evaluation runbook

This runbook operates the evaluation system accepted by
[ADR-0019](architecture/decisions/ADR-0019-agent-evaluation-learning-plane.md). It does
not authorize exporting private content, training on user notes, changing a production
prompt, or promoting the Agent Data Plane to `primary`.

## What runs automatically

For every completed `memo-understand` Run, DayPage stores six deterministic invariant
scores: response-policy consistency, external-action confirmation, Memory confirmation,
context-selection integrity, source-span validity, and response-budget compliance. Run
completion/failure, scores, and later feedback enqueue Opik projections when export is
enabled. Agent processing is fail-open with respect to evaluation persistence/export;
an evaluation provider outage never blocks capture or changes the Agent result.

The user-scoped Run detail endpoint returns `run`, `steps`, `artifacts`, `work_orders`,
`feedback`, and `evaluations`. Feedback is submitted to:

```text
POST /api/agent-runs/:run_id/feedback
```

The body uses one exact event type plus an idempotency key. Action events require a
Work Order ID; Memory events require a `memory_proposal` Artifact ID. Corrections may
include `before`, `after`, and changed field names. The server verifies all targets
belong to the authenticated user and Run.

## Local deterministic gate

The default gate runs without API keys or network access:

```bash
pnpm --filter daypage-web eval:validate
```

It validates all 148 cases and their golden outputs. Current distribution:

| Category | Cases |
| --- | ---: |
| Routing | 40 |
| Context | 20 |
| Action | 20 |
| Memory | 16 |
| Safety | 16 |
| Response | 16 |
| Daily | 10 |
| Longitudinal | 10 |

The `Agent Evaluation Gate` workflow runs this deterministic suite, focused tests, and
Web type checking whenever evaluation contracts, prompts, datasets, or runner code
change, then retains the schema-versioned report as CI evidence.

Filter a deterministic run with `--case`, `--tag`, `--category`, or `--limit`. Write a
machine-readable report only when needed:

```bash
pnpm --filter daypage-web eval:validate -- --category safety --output ../output/evaluation/safety-golden.json
```

## Real-model experiments

Set an OpenAI-compatible endpoint and key, then run the candidate model. Reports default
to `output/evaluation/` and include synthetic input/output, metrics, error evidence,
latency, and token usage.

```bash
OPENAI_API_KEY=... OPENAI_MODEL=gpt-4o-mini \
  pnpm --filter daypage-web eval:run -- \
  --model gpt-4o-mini --concurrency 4
```

Useful bounded runs:

```bash
pnpm --filter daypage-web eval:run -- --model gpt-4o-mini --category safety
pnpm --filter daypage-web eval:run -- --model gpt-4o-mini --tag cross-person
pnpm --filter daypage-web eval:run -- --model gpt-4o-mini --case context.pricing
```

Add the independent seven-dimension judge only by explicit choice:

```bash
pnpm --filter daypage-web eval:run -- \
  --model candidate-model --judge-model independent-judge-model
```

Do not point this checked-in synthetic runner at a raw production export. Production
failure candidates must pass the consent/redaction/synthesis workflow first.

## Promotion and regression

Re-run a saved report against the default hard gates and quality thresholds:

```bash
pnpm --filter daypage-web eval:gate -- --report ../output/evaluation/candidate.json
```

Use a known report for paired regression protection:

```bash
pnpm --filter daypage-web eval:gate -- \
  --report ../output/evaluation/candidate.json \
  --baseline ../output/evaluation/baseline.json
```

The command exits non-zero if any model execution/validation fails, a safety hard gate
falls below 100%, an absolute threshold fails, or a shared metric drops by more than two
percentage points from the baseline. A passing experiment is evidence for review, not
automatic authorization to change production.

## Opik configuration and sync

Evaluation export defaults to off. Configure one of these privacy modes:

```dotenv
EVALUATION_EXPORT_MODE=metadata_only
EVALUATION_PSEUDONYM_SALT=<random server secret>
OPIK_API_KEY=<cloud key>
OPIK_URL_OVERRIDE=https://www.comet.com/opik/api
OPIK_PROJECT_NAME=daypage-agent-staging
OPIK_WORKSPACE=<workspace>
OPIK_ENVIRONMENT=staging
```

For self-hosted Opik, set its API URL; an API key is not required by DayPage when the
URL is not a Comet Cloud host. Prefer `metadata_only`. `full_content_opt_in` silently
degrades to metadata-only unless the owning user has opted in.

Synchronize the version-qualified synthetic Dataset and versioned prompt:

```bash
pnpm --filter daypage-web eval:sync-opik
```

Upload while running, or upload a saved report idempotently by experiment name:

```bash
pnpm --filter daypage-web eval:run -- --model candidate-model --opik
pnpm --filter daypage-web eval:upload-opik -- --report ../output/evaluation/candidate.json
```

The uploaded Experiment links the Opik Dataset version and `daypage.memo-understand`
prompt version, and writes every deterministic/judge dimension as a separate feedback
score.

With `DATABASE_URL` set, add `--persist` to `eval:run` to upsert the bounded report
summary and gate decision into DayPage's authoritative `evaluation_experiments` table.
Raw per-case outputs remain in the explicitly written local report and optional Opik
Experiment; they are not copied into the database summary.

## Human annotation

Create or reuse the named trace queue and add traces selected with an explicit Opik OQL
filter:

```bash
pnpm --filter daypage-web eval:annotation-queue -- \
  --name daypage-agent-review \
  --filter 'feedback_scores.user.context_relevance < 1' \
  --limit 100
```

Review response policy, selected context, grounded claims, proposed actions, and Memory
proposals. Never promote raw queue content directly. Accepted dataset additions must be
synthetic, explicitly consented, or approved redactions, then checked into a new dataset
version with a reason and regression expectation.

## Database verification

After applying migrations, run the transactional gate:

```bash
pnpm db:migrate:local
docker exec -i supabase_db_daypage psql -U postgres -d postgres \
  < web/scripts/verify-agent-evaluation.sql
```

It rolls back both synthetic tenants and verifies score/privacy constraints,
cross-tenant RLS, owner visibility, and that authenticated clients cannot forge direct
evaluation writes. The broader local backend gate includes this verifier:

```bash
pnpm backend:verify:local
```

## Operations

Use an authorized operations role and scope user data before inspecting individual
records:

```sql
select status, entity_type, operation, count(*), max(attempts) as max_attempts
from evaluation_export_outbox
where created_at > now() - interval '24 hours'
group by status, entity_type, operation;

select evaluator_key, count(*) as samples, avg(score) as mean_score,
       count(*) filter (where not passed) as failures
from evaluation_results
where created_at > now() - interval '24 hours'
group by evaluator_key
order by evaluator_key;

select reason, sanitization_status, review_status, count(*)
from evaluation_case_candidates
group by reason, sanitization_status, review_status;
```

Repeated `dead` export rows indicate bad Opik configuration, authorization, schema
drift, or an unavailable endpoint. Fix the cause before replaying; do not delete the
DayPage Run, feedback, or evaluator history. Routine logs must not contain memo bodies,
prompts, corrections, credentials, or artifact payloads.

## Rollback

1. Set `EVALUATION_EXPORT_MODE=off`; this stops new provider outbox rows and makes the
   drain a no-op.
2. Leave deterministic local evaluation enabled unless it is the diagnosed fault; it
   does not call Opik or block the Run.
3. Pause any external annotation or experiment workflow.
4. Preserve feedback, results, candidates, reports, and dead-letter rows for audit.
5. Reverting an Opik projection does not undo an external action; action safety remains
   owned by Work Order approval and connector receipts.
