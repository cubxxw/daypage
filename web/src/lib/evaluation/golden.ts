import {
  MemoUnderstandingSchema,
  type MemoUnderstanding,
  type ProposedAction,
} from "@/lib/agent-data-plane/contracts";
import type { EvaluationCase } from "./contracts";

function actionEffect(tool: string): ProposedAction["effect"] {
  if (/delete|destroy|purge/i.test(tool)) return "destructive";
  if (/^(calendar|email|publish|web\.upload)/.test(tool)) return "external_write";
  return "internal_write";
}
/**
 * Creates the minimal contract-satisfying output for a dataset item. This is
 * intentionally plain: it validates the dataset/evaluator handshake and gives
 * experiment runners a deterministic baseline, not a production response.
 */
export function buildGoldenOutput(evaluationCase: EvaluationCase): MemoUnderstanding {
  const ref = {
    memo_id: evaluationCase.input.memo_id,
    start: 0,
    end: evaluationCase.input.entry.length,
  };
  const selected = new Set(evaluationCase.expected.required_context_ids);
  const mode = evaluationCase.expected.response_modes[0];
  const intent = evaluationCase.expected.intent_kinds[0];
  const responseBody = evaluationCase.expected.response_required_terms.length
    ? evaluationCase.expected.response_required_terms.join("；")
    : "已按这条记录选择了最合适的下一步处理。";
  const actions = evaluationCase.expected.required_action_tools.map((tool) => {
    const effect = actionEffect(tool);
    return {
      tool,
      arguments: {},
      effect,
      approval: effect === "external_write" || effect === "destructive" ? "required" as const : "auto" as const,
      rationale: "The evaluation case explicitly requires this proposal.",
    };
  });
  const memory = evaluationCase.expected.memory_proposal === "required"
    ? [
        {
          kind: "working_context" as const,
          subject: "entry",
          predicate: "records",
          value: evaluationCase.input.entry,
          confidence: 1,
          source_refs: [ref],
          requires_confirmation: true as const,
          rationale: "The evaluation case requires a proposal-only Memory update.",
        },
      ]
    : [];
  return MemoUnderstandingSchema.parse({
    intent: {
      kind: intent,
      confidence: 1,
      rationale: "Golden dataset expectation",
    },
    response_policy: {
      mode,
      reason_codes: ["golden_case"],
      uncertainty: 0,
      max_reply_tokens: mode === "silent" ? 0 : 1_024,
    },
    context_decision: {
      strategy: selected.size ? "semantic" : "none",
      query_terms: selected.size ? ["golden context"] : [],
      candidates: evaluationCase.input.context.map((candidate) => ({
        page_id: candidate.id,
        selected: selected.has(candidate.id),
        reason: selected.has(candidate.id) ? "Required by the golden case" : "Not needed",
      })),
      selected_page_ids: [...selected],
    },
    response:
      mode === "silent"
        ? null
        : {
            body_md: responseBody,
            claims: [
              {
                text: "Response is grounded in the current entry",
                source_refs: [ref],
                inference: false,
              },
            ],
            suggested_followups: [],
          },
    summary: "Golden evaluation output",
    observations: [],
    artifacts: [
      {
        kind: "daily_contribution",
        schema_version: 1,
        payload: { headline: "Golden evaluation output", details: evaluationCase.input.entry, open_loops: [] },
        source_refs: [ref],
      },
    ],
    proposed_actions: actions,
    proposed_memory_updates: memory,
  });
}
