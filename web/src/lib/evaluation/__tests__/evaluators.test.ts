import { describe, expect, it } from "vitest";
import type { MemoUnderstanding } from "@/lib/agent-data-plane/contracts";
import { dayPageCoreDataset } from "../datasets/daypage-core-v1";
import { evaluateCase } from "../evaluators";
import { buildGoldenOutput } from "../golden";
import { evaluateProductionOutput } from "../online";

function caseById(fragment: string) {
  const item = dayPageCoreDataset.cases.find((candidate) => candidate.id.includes(fragment));
  if (!item) throw new Error(`Missing test case ${fragment}`);
  return item;
}

function metric(output: ReturnType<typeof evaluateCase>, key: string) {
  const value = output.metrics.find((candidate) => candidate.key === key);
  if (!value) throw new Error(`Missing metric ${key}`);
  return value;
}

describe("deterministic case evaluators", () => {
  it("hard-fails cross-person context contamination", () => {
    const evaluationCase = caseById("context.pricing_same_person.1");
    const output = buildGoldenOutput(evaluationCase);
    const forbidden = evaluationCase.expected.forbidden_context_ids[0];
    output.context_decision.selected_page_ids.push(forbidden);
    output.context_decision.candidates.find((item) => item.page_id === forbidden)!.selected = true;
    const result = evaluateCase(evaluationCase, output);
    expect(metric(result, "context.forbidden").passed).toBe(false);
    expect(result.hard_gate_failures).toContain("context.forbidden");
  });

  it("hard-fails an external action that bypasses confirmation", () => {
    const evaluationCase = caseById("action.send_email.1");
    const output = buildGoldenOutput(evaluationCase);
    output.proposed_actions[0].approval = "auto";
    const result = evaluateCase(evaluationCase, output);
    expect(metric(result, "action.confirmation_safety").passed).toBe(false);
  });

  it("hard-fails a dangerous tool even when the model mislabels its effect", () => {
    const evaluationCase = caseById("action.send_email.1");
    const output = buildGoldenOutput(evaluationCase);
    output.proposed_actions[0].effect = "internal_write";
    output.proposed_actions[0].approval = "auto";
    expect(metric(evaluateCase(evaluationCase, output), "action.confirmation_safety").passed).toBe(false);
  });

  it("hard-fails an invented exact datetime", () => {
    const evaluationCase = caseById("action.relative_day.1");
    const output = buildGoldenOutput(evaluationCase);
    output.proposed_actions[0].arguments = { start_at: "2026-09-08T09:00:00+08:00" };
    expect(metric(evaluateCase(evaluationCase, output), "action.datetime_grounding").passed).toBe(false);
  });

  it("hard-fails invalid grounding spans", () => {
    const evaluationCase = caseById("memory.person_move.1");
    const output = buildGoldenOutput(evaluationCase);
    output.proposed_memory_updates[0].source_refs[0].end = evaluationCase.input.entry.length + 10;
    expect(metric(evaluateCase(evaluationCase, output), "grounding.source_refs").passed).toBe(false);
  });

  it("does not accept a hallucinated Memory value merely because the response repeats it", () => {
    const evaluationCase = caseById("memory.person_move.1");
    const output = buildGoldenOutput(evaluationCase);
    output.proposed_memory_updates[0].value = "王伟去了火星公司";
    output.response!.body_md = "王伟去了火星公司";
    expect(metric(evaluateCase(evaluationCase, output), "memory.source_support").passed).toBe(false);
  });
});

describe("production invariants", () => {
  it("checks response budget, action confirmation, memory confirmation and source bounds", () => {
    const evaluationCase = caseById("memory.person_move.1");
    const output = buildGoldenOutput(evaluationCase);
    output.response_policy.max_reply_tokens = 1;
    output.response!.body_md = "这是一个明显超过单个近似 token 的回复";
    output.proposed_memory_updates[0] = {
      ...output.proposed_memory_updates[0],
      requires_confirmation: false,
    } as unknown as MemoUnderstanding["proposed_memory_updates"][number];
    const metrics = evaluateProductionOutput({
      output,
      memoId: evaluationCase.input.memo_id,
      memoLength: evaluationCase.input.entry.length,
    });
    expect(metrics.find((item) => item.key === "safety.memory_confirmation")?.passed).toBe(false);
    expect(metrics.find((item) => item.key === "budget.response_length")?.passed).toBe(false);
  });
});
