CREATE TYPE "evaluation_export_status" AS ENUM ('pending', 'running', 'completed', 'dead');--> statement-breakpoint

CREATE TABLE "agent_feedback_events" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL REFERENCES "users"("id") ON DELETE cascade,
  "run_id" uuid NOT NULL REFERENCES "agent_runs"("id") ON DELETE cascade,
  "artifact_id" uuid REFERENCES "agent_artifacts"("id") ON DELETE set null,
  "work_order_id" uuid REFERENCES "work_orders"("id") ON DELETE set null,
  "event_type" text NOT NULL,
  "value" real,
  "reason_code" text,
  "correction" jsonb,
  "metadata" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "idempotency_key" text NOT NULL,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT "agent_feedback_events_idempotency_unique" UNIQUE("idempotency_key"),
  CONSTRAINT "agent_feedback_events_value_check" CHECK (value IS NULL OR (value >= -1 AND value <= 1)),
  CONSTRAINT "agent_feedback_events_target_check" CHECK (
    artifact_id IS NULL OR work_order_id IS NULL
  )
);--> statement-breakpoint
CREATE INDEX "agent_feedback_events_run_created" ON "agent_feedback_events" ("run_id", "created_at");--> statement-breakpoint
CREATE INDEX "agent_feedback_events_user_type_created" ON "agent_feedback_events" ("user_id", "event_type", "created_at");--> statement-breakpoint

CREATE TABLE "evaluation_results" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL REFERENCES "users"("id") ON DELETE cascade,
  "run_id" uuid NOT NULL REFERENCES "agent_runs"("id") ON DELETE cascade,
  "step_id" uuid REFERENCES "agent_run_steps"("id") ON DELETE cascade,
  "evaluator_key" text NOT NULL,
  "evaluator_version" text NOT NULL,
  "source" text NOT NULL,
  "score" real NOT NULL,
  "passed" boolean NOT NULL,
  "reason" text,
  "evidence" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "idempotency_key" text NOT NULL,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT "evaluation_results_idempotency_unique" UNIQUE("idempotency_key"),
  CONSTRAINT "evaluation_results_score_check" CHECK (score >= 0 AND score <= 1),
  CONSTRAINT "evaluation_results_source_check" CHECK (source IN ('deterministic', 'llm_judge', 'human', 'behavior'))
);--> statement-breakpoint
CREATE INDEX "evaluation_results_run_key" ON "evaluation_results" ("run_id", "evaluator_key");--> statement-breakpoint
CREATE INDEX "evaluation_results_user_passed_created" ON "evaluation_results" ("user_id", "passed", "created_at");--> statement-breakpoint

CREATE TABLE "evaluation_case_candidates" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL REFERENCES "users"("id") ON DELETE cascade,
  "run_id" uuid NOT NULL REFERENCES "agent_runs"("id") ON DELETE cascade,
  "feedback_event_id" uuid REFERENCES "agent_feedback_events"("id") ON DELETE set null,
  "reason" text NOT NULL,
  "privacy_class" text NOT NULL DEFAULT 'private',
  "sanitization_status" text NOT NULL DEFAULT 'pending',
  "review_status" text NOT NULL DEFAULT 'candidate',
  "sanitized_case" jsonb,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT "evaluation_case_candidates_feedback_unique" UNIQUE("feedback_event_id"),
  CONSTRAINT "evaluation_case_candidates_privacy_check" CHECK (privacy_class IN ('private', 'redacted', 'synthetic', 'consented')),
  CONSTRAINT "evaluation_case_candidates_sanitization_check" CHECK (sanitization_status IN ('pending', 'redacted', 'approved', 'rejected')),
  CONSTRAINT "evaluation_case_candidates_review_check" CHECK (review_status IN ('candidate', 'reviewing', 'accepted', 'rejected'))
);--> statement-breakpoint
CREATE INDEX "evaluation_case_candidates_review" ON "evaluation_case_candidates" ("review_status", "created_at");--> statement-breakpoint

CREATE TABLE "evaluation_export_outbox" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" uuid NOT NULL REFERENCES "users"("id") ON DELETE cascade,
  "run_id" uuid REFERENCES "agent_runs"("id") ON DELETE cascade,
  "entity_type" text NOT NULL,
  "entity_id" uuid NOT NULL,
  "operation" text NOT NULL,
  "privacy_mode" text NOT NULL DEFAULT 'metadata_only',
  "payload" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "idempotency_key" text NOT NULL,
  "status" "evaluation_export_status" NOT NULL DEFAULT 'pending',
  "attempts" integer NOT NULL DEFAULT 0,
  "available_at" timestamptz NOT NULL DEFAULT now(),
  "lease_token" uuid,
  "lease_expires_at" timestamptz,
  "external_id" text,
  "last_error" text,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT "evaluation_export_outbox_idempotency_unique" UNIQUE("idempotency_key"),
  CONSTRAINT "evaluation_export_outbox_attempts_check" CHECK (attempts >= 0),
  CONSTRAINT "evaluation_export_outbox_entity_check" CHECK (entity_type IN ('trace', 'feedback', 'evaluation_result', 'dataset_item', 'experiment')),
  CONSTRAINT "evaluation_export_outbox_operation_check" CHECK (operation IN ('upsert', 'score', 'insert', 'delete')),
  CONSTRAINT "evaluation_export_outbox_privacy_check" CHECK (privacy_mode IN ('metadata_only', 'redacted', 'full_content_opt_in'))
);--> statement-breakpoint
CREATE INDEX "evaluation_export_outbox_due" ON "evaluation_export_outbox" ("status", "available_at", "lease_expires_at");--> statement-breakpoint
CREATE INDEX "evaluation_export_outbox_run" ON "evaluation_export_outbox" ("run_id", "created_at");--> statement-breakpoint

CREATE TABLE "evaluation_experiments" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "created_by" uuid REFERENCES "users"("id") ON DELETE set null,
  "name" text NOT NULL,
  "dataset_name" text NOT NULL,
  "dataset_version" text NOT NULL,
  "baseline_config" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "candidate_config" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "thresholds" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "results" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "git_sha" text,
  "status" text NOT NULL DEFAULT 'pending',
  "promotion_decision" text,
  "opik_experiment_id" text,
  "opik_url" text,
  "started_at" timestamptz,
  "completed_at" timestamptz,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT "evaluation_experiments_name_unique" UNIQUE("name"),
  CONSTRAINT "evaluation_experiments_status_check" CHECK (status IN ('pending', 'running', 'completed', 'failed')),
  CONSTRAINT "evaluation_experiments_promotion_check" CHECK (promotion_decision IS NULL OR promotion_decision IN ('promote', 'hold', 'reject'))
);--> statement-breakpoint
CREATE INDEX "evaluation_experiments_dataset_created" ON "evaluation_experiments" ("dataset_name", "created_at");--> statement-breakpoint

ALTER TABLE "agent_feedback_events" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "evaluation_results" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "evaluation_case_candidates" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "evaluation_export_outbox" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "evaluation_experiments" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint

CREATE POLICY "agent_feedback_events_owner_read" ON "agent_feedback_events" FOR SELECT TO authenticated USING (user_id = auth.uid());--> statement-breakpoint
CREATE POLICY "evaluation_results_owner_read" ON "evaluation_results" FOR SELECT TO authenticated USING (user_id = auth.uid());--> statement-breakpoint
CREATE POLICY "evaluation_case_candidates_owner_read" ON "evaluation_case_candidates" FOR SELECT TO authenticated USING (user_id = auth.uid());--> statement-breakpoint
CREATE POLICY "evaluation_export_outbox_owner_read" ON "evaluation_export_outbox" FOR SELECT TO authenticated USING (user_id = auth.uid());--> statement-breakpoint

REVOKE ALL ON agent_feedback_events, evaluation_results, evaluation_case_candidates,
  evaluation_export_outbox, evaluation_experiments FROM PUBLIC, anon;--> statement-breakpoint
GRANT SELECT ON agent_feedback_events, evaluation_results, evaluation_case_candidates,
  evaluation_export_outbox TO authenticated;
