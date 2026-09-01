import { z } from "zod";

export const FeedbackEventTypeSchema = z.enum([
  "response.expanded",
  "response.saved",
  "response.edited",
  "response.dismissed",
  "response.not_relevant",
  "response.style_blocked",
  "action.accepted",
  "action.modified",
  "action.rejected",
  "memory.confirmed",
  "memory.corrected",
  "memory.rejected",
  "followup.continued",
]);

export const RecordFeedbackSchema = z
  .object({
    event_type: FeedbackEventTypeSchema,
    artifact_id: z.string().uuid().optional(),
    work_order_id: z.string().uuid().optional(),
    value: z.number().min(-1).max(1).optional(),
    reason_code: z.string().min(1).max(200).optional(),
    correction: z
      .object({
        before: z.unknown().optional(),
        after: z.unknown(),
        changed_fields: z.array(z.string().min(1).max(200)).max(50).optional(),
      })
      .optional(),
    metadata: z.record(z.string(), z.unknown()).optional(),
    idempotency_key: z.string().min(8).max(500),
  })
  .superRefine((value, context) => {
    if (
      ["response.edited", "action.modified", "memory.corrected"].includes(value.event_type) &&
      !value.correction
    ) {
      context.addIssue({
        code: "custom",
        path: ["correction"],
        message: `${value.event_type} requires correction evidence`,
      });
    }
    if (value.correction && JSON.stringify(value.correction).length > 50_000) {
      context.addIssue({
        code: "custom",
        path: ["correction"],
        message: "correction evidence exceeds 50,000 serialized characters",
      });
    }
    if (value.metadata && JSON.stringify(value.metadata).length > 16_000) {
      context.addIssue({
        code: "custom",
        path: ["metadata"],
        message: "feedback metadata exceeds 16,000 serialized characters",
      });
    }
  });

export const EvaluationContextCandidateSchema = z.object({
  id: z.string().uuid(),
  title: z.string().min(1).max(500),
  content: z.string().max(20_000),
  relevance: z.enum(["required", "relevant", "irrelevant", "forbidden"]),
});

export const EvaluationCaseSchema = z.object({
  id: z.string().regex(/^[a-z0-9][a-z0-9._-]+$/),
  version: z.number().int().positive(),
  category: z.enum([
    "routing",
    "context",
    "response",
    "action",
    "memory",
    "daily",
    "longitudinal",
    "safety",
  ]),
  tags: z.array(z.string().min(1).max(100)).min(1).max(20),
  input: z.object({
    memo_id: z.string().uuid(),
    entry: z.string().min(1).max(50_000),
    locale: z.string().min(2).max(20).default("zh-CN"),
    now: z.string().datetime().optional(),
    context: z.array(EvaluationContextCandidateSchema).max(20).default([]),
  }),
  expected: z.object({
    intent_kinds: z
      .array(
        z.enum([
          "emotion",
          "task",
          "idea",
          "link",
          "fact",
          "question",
          "work_log",
          "continuation",
          "other",
        ]),
      )
      .min(1),
    response_modes: z.array(z.enum(["silent", "light", "reflect", "act"])).min(1),
    required_context_ids: z.array(z.string().uuid()).default([]),
    relevant_context_ids: z.array(z.string().uuid()).default([]),
    forbidden_context_ids: z.array(z.string().uuid()).default([]),
    required_action_tools: z.array(z.string()).default([]),
    forbidden_action_tools: z.array(z.string()).default([]),
    memory_proposal: z.enum(["required", "allowed", "forbidden"]).default("allowed"),
    response_required_terms: z.array(z.string()).default([]),
    response_forbidden_terms: z.array(z.string()).default([]),
  }),
  forbidden: z
    .array(
      z.enum([
        "external_action_without_confirmation",
        "invent_exact_datetime",
        "public_web_search",
        "cross_person_context",
        "unsupported_memory_fact",
        "unsolicited_task",
        "user_visible_response",
      ]),
    )
    .default([]),
  notes: z.string().max(4_000).optional(),
});

export const EvaluationDatasetSchema = z.object({
  name: z.string().min(1),
  version: z.string().min(1),
  description: z.string().min(1),
  cases: z.array(EvaluationCaseSchema).min(1),
});

export const MetricResultSchema = z.object({
  key: z.string().min(1),
  score: z.number().min(0).max(1),
  passed: z.boolean(),
  hard_gate: z.boolean(),
  reason: z.string().min(1),
  evidence: z.record(z.string(), z.unknown()).default({}),
});

export const CaseEvaluationResultSchema = z.object({
  case_id: z.string(),
  passed: z.boolean(),
  score: z.number().min(0).max(1),
  hard_gate_failures: z.array(z.string()),
  metrics: z.array(MetricResultSchema),
});

export const ExperimentCaseResultSchema = z.object({
  case_id: z.string(),
  category: EvaluationCaseSchema.shape.category,
  tags: z.array(z.string()),
  status: z.enum(["completed", "failed"]),
  duration_ms: z.number().int().nonnegative(),
  tokens_in: z.number().int().nonnegative(),
  tokens_out: z.number().int().nonnegative(),
  model: z.string(),
  output: z.unknown().optional(),
  evaluation: CaseEvaluationResultSchema.optional(),
  error: z.string().optional(),
});

export const EvaluationExperimentReportSchema = z.object({
  schema_version: z.literal(1),
  dataset: z.object({
    name: z.string(),
    version: z.string(),
    case_count: z.number().int().nonnegative(),
  }),
  experiment: z.object({
    name: z.string(),
    model: z.string(),
    prompt_checksum: z.string(),
    started_at: z.string().datetime(),
    completed_at: z.string().datetime(),
  }),
  cases: z.array(ExperimentCaseResultSchema),
});

export type FeedbackEventType = z.infer<typeof FeedbackEventTypeSchema>;
export type RecordFeedbackInput = z.infer<typeof RecordFeedbackSchema>;
export type EvaluationCase = z.infer<typeof EvaluationCaseSchema>;
export type EvaluationDataset = z.infer<typeof EvaluationDatasetSchema>;
export type MetricResult = z.infer<typeof MetricResultSchema>;
export type CaseEvaluationResult = z.infer<typeof CaseEvaluationResultSchema>;
export type ExperimentCaseResult = z.infer<typeof ExperimentCaseResultSchema>;
export type EvaluationExperimentReport = z.infer<typeof EvaluationExperimentReportSchema>;
