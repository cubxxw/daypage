import { z } from "zod";

export const SourceRefSchema = z
  .object({
    memo_id: z.string().uuid(),
    start: z.number().int().nonnegative(),
    end: z.number().int().positive(),
  })
  .refine((value) => value.end > value.start, {
    message: "source ref end must be greater than start",
  });

export const ObservationSchema = z.object({
  kind: z.enum(["fact", "relation", "task", "conflict", "inference"]),
  subject: z.string().min(1).max(500),
  predicate: z.string().min(1).max(200),
  value: z.unknown(),
  confidence: z.number().min(0).max(1),
  inference: z.boolean().default(false),
  source_refs: z.array(SourceRefSchema).min(1).max(20),
});

export const ArtifactDraftSchema = z.object({
  kind: z.string().min(1).max(100),
  schema_version: z.number().int().positive().default(1),
  logical_key: z.string().min(1).max(500).optional(),
  payload: z.record(z.string(), z.unknown()),
  body_md: z.string().max(100_000).nullable().optional(),
  source_refs: z.array(SourceRefSchema).min(1).max(100),
});

export const ProposedActionSchema = z.object({
  tool: z.string().min(1).max(200),
  arguments: z.record(z.string(), z.unknown()),
  effect: z.enum(["read", "internal_write", "external_write", "destructive"]),
  approval: z.enum(["auto", "required", "forbidden"]),
  rationale: z.string().max(2_000).optional(),
});

export const EntryIntentSchema = z.object({
  kind: z.enum([
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
  confidence: z.number().min(0).max(1),
  rationale: z.string().min(1).max(1_000),
});

export const ResponsePolicySchema = z.object({
  mode: z.enum(["silent", "light", "reflect", "act"]),
  reason_codes: z.array(z.string().min(1).max(100)).min(1).max(10),
  uncertainty: z.number().min(0).max(1),
  max_reply_tokens: z.number().int().min(0).max(4_096),
});

export const ContextCandidateDecisionSchema = z.object({
  page_id: z.string().uuid(),
  selected: z.boolean(),
  reason: z.string().min(1).max(1_000),
});

export const ContextDecisionSchema = z.object({
  strategy: z.enum(["none", "recent", "semantic", "hybrid"]),
  query_terms: z.array(z.string().min(1).max(200)).max(12),
  candidates: z.array(ContextCandidateDecisionSchema).max(20),
  selected_page_ids: z.array(z.string().uuid()).max(12),
});

export const GroundedClaimSchema = z.object({
  text: z.string().min(1).max(2_000),
  source_refs: z.array(SourceRefSchema).max(20),
  inference: z.boolean().default(false),
});

export const AgentResponseSchema = z.object({
  body_md: z.string().min(1).max(20_000),
  claims: z.array(GroundedClaimSchema).max(30),
  suggested_followups: z.array(z.string().min(1).max(500)).max(5),
});

export const MemoryProposalSchema = z.object({
  kind: z.enum(["fact", "preference", "decision", "person_state", "working_context"]),
  subject: z.string().min(1).max(500),
  predicate: z.string().min(1).max(200),
  value: z.unknown(),
  confidence: z.number().min(0).max(1),
  source_refs: z.array(SourceRefSchema).min(1).max(20),
  requires_confirmation: z.literal(true),
  rationale: z.string().min(1).max(2_000),
});

export const StepReceiptSchema = z.object({
  step: z.string().min(1).max(100),
  status: z.enum(["completed", "failed", "skipped"]),
  input_hash: z.string().optional(),
  output_hash: z.string().optional(),
  tokens_in: z.number().int().nonnegative().default(0),
  tokens_out: z.number().int().nonnegative().default(0),
  duration_ms: z.number().int().nonnegative(),
  tool: z.string().optional(),
  details: z.record(z.string(), z.unknown()).optional(),
});

export const MemoUnderstandingSchema = z
  .object({
    intent: EntryIntentSchema,
    response_policy: ResponsePolicySchema,
    context_decision: ContextDecisionSchema,
    response: AgentResponseSchema.nullable(),
    summary: z.string().min(1).max(4_000),
    observations: z.array(ObservationSchema).max(50),
    artifacts: z.array(ArtifactDraftSchema).max(20),
    proposed_actions: z.array(ProposedActionSchema).max(10),
    proposed_memory_updates: z.array(MemoryProposalSchema).max(10),
  })
  .superRefine((value, context) => {
    if (value.response_policy.mode === "silent" && value.response !== null) {
      context.addIssue({
        code: "custom",
        path: ["response"],
        message: "silent response policy must not emit a user-visible response",
      });
    }
    if (value.response_policy.mode !== "silent" && value.response === null) {
      context.addIssue({
        code: "custom",
        path: ["response"],
        message: "non-silent response policy must emit a user-visible response",
      });
    }
    if (value.response_policy.mode !== "silent" && value.response_policy.max_reply_tokens === 0) {
      context.addIssue({
        code: "custom",
        path: ["response_policy", "max_reply_tokens"],
        message: "non-silent response policy must allocate a positive reply budget",
      });
    }
    const selected = new Set(value.context_decision.selected_page_ids);
    for (const candidate of value.context_decision.candidates) {
      if (candidate.selected !== selected.has(candidate.page_id)) {
        context.addIssue({
          code: "custom",
          path: ["context_decision", "candidates"],
          message: `candidate ${candidate.page_id} selection disagrees with selected_page_ids`,
        });
      }
    }
  });

export const AgentOutputEnvelopeSchema = z.object({
  run_id: z.string().uuid(),
  status: z.enum(["completed", "failed", "needs_review"]),
  intent: EntryIntentSchema,
  response_policy: ResponsePolicySchema,
  context_decision: ContextDecisionSchema,
  response: AgentResponseSchema.nullable(),
  summary: z.string().max(4_000),
  observations: z.array(ObservationSchema),
  artifacts: z.array(ArtifactDraftSchema),
  proposed_actions: z.array(ProposedActionSchema),
  proposed_memory_updates: z.array(MemoryProposalSchema),
  receipts: z.array(StepReceiptSchema),
});

export type SourceRef = z.infer<typeof SourceRefSchema>;
export type Observation = z.infer<typeof ObservationSchema>;
export type ArtifactDraft = z.infer<typeof ArtifactDraftSchema>;
export type ProposedAction = z.infer<typeof ProposedActionSchema>;
export type EntryIntent = z.infer<typeof EntryIntentSchema>;
export type ResponsePolicy = z.infer<typeof ResponsePolicySchema>;
export type ContextDecision = z.infer<typeof ContextDecisionSchema>;
export type AgentResponse = z.infer<typeof AgentResponseSchema>;
export type MemoryProposal = z.infer<typeof MemoryProposalSchema>;
export type StepReceipt = z.infer<typeof StepReceiptSchema>;
export type MemoUnderstanding = z.infer<typeof MemoUnderstandingSchema>;
export type AgentOutputEnvelope = z.infer<typeof AgentOutputEnvelopeSchema>;

export function stripJsonFence(raw: string): string {
  return raw
    .replace(/^```json\s*/i, "")
    .replace(/^```\s*/i, "")
    .replace(/```\s*$/i, "")
    .trim();
}

export function parseMemoUnderstanding(raw: string): MemoUnderstanding {
  return MemoUnderstandingSchema.parse(JSON.parse(stripJsonFence(raw)));
}

export function assertSourceRefsWithinMemo(
  result: MemoUnderstanding,
  memoId: string,
  memoLength: number,
): void {
  const refs = [
    ...result.observations.flatMap((item) => item.source_refs),
    ...result.artifacts.flatMap((item) => item.source_refs),
    ...result.proposed_memory_updates.flatMap((item) => item.source_refs),
    ...(result.response?.claims.flatMap((item) => item.source_refs) ?? []),
  ];
  for (const ref of refs) {
    if (ref.memo_id !== memoId) {
      throw new Error(`source_ref memo_id ${ref.memo_id} does not match input memo`);
    }
    if (ref.end > memoLength) {
      throw new Error(`source_ref end ${ref.end} exceeds memo length ${memoLength}`);
    }
  }
}

export function assertContextDecisionWithinCandidates(
  result: MemoUnderstanding,
  candidatePageIds: string[],
): void {
  const allowed = new Set(candidatePageIds);
  const seen = new Set<string>();
  for (const candidate of result.context_decision.candidates) {
    if (!allowed.has(candidate.page_id)) {
      throw new Error(`context candidate ${candidate.page_id} was not supplied to the model`);
    }
    if (seen.has(candidate.page_id)) {
      throw new Error(`context candidate ${candidate.page_id} was returned more than once`);
    }
    seen.add(candidate.page_id);
  }
  if (seen.size !== allowed.size) {
    const missing = candidatePageIds.filter((pageId) => !seen.has(pageId));
    throw new Error(`context decision omitted supplied candidates: ${missing.join(", ")}`);
  }
  for (const pageId of result.context_decision.selected_page_ids) {
    if (!allowed.has(pageId)) {
      throw new Error(`selected context ${pageId} was not supplied to the model`);
    }
    if (!seen.has(pageId)) {
      throw new Error(`selected context ${pageId} is missing from context candidates`);
    }
  }
}
