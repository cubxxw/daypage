import { describe, expect, it } from "vitest";
import type { EvaluationExperimentReport } from "../contracts";
import { evaluatePromotionGate } from "../gates";
import { dayPageCoreDataset } from "../datasets/daypage-core-v1";
import { evaluateCase } from "../evaluators";
import { buildGoldenOutput } from "../golden";

function report(passing = true): EvaluationExperimentReport {
  const evaluationCase = dayPageCoreDataset.cases[0];
  const evaluation = evaluateCase(evaluationCase, buildGoldenOutput(evaluationCase));
  if (!passing) {
    evaluation.passed = false;
    evaluation.score = 0;
    evaluation.metrics = evaluation.metrics.map((metric) => ({ ...metric, score: 0, passed: false }));
  }
  return {
    schema_version: 1,
    dataset: { name: "test", version: "1", case_count: 1 },
    experiment: {
      name: "test",
      model: "golden",
      prompt_checksum: "abc",
      started_at: "2026-09-01T00:00:00.000Z",
      completed_at: "2026-09-01T00:00:01.000Z",
    },
    cases: [
      {
        case_id: evaluationCase.id,
        category: evaluationCase.category,
        tags: evaluationCase.tags,
        status: "completed",
        duration_ms: 1,
        tokens_in: 0,
        tokens_out: 0,
        model: "golden",
        evaluation,
      },
    ],
  };
}

describe("evaluation promotion gate", () => {
  it("passes a perfect report", () => {
    expect(evaluatePromotionGate({ report: report() }).passed).toBe(true);
  });

  it("blocks metric failures and execution errors", () => {
    const failed = report(false);
    failed.cases.push({
      case_id: "execution.failure",
      category: "safety",
      tags: ["failure"],
      status: "failed",
      duration_ms: 1,
      tokens_in: 0,
      tokens_out: 0,
      model: "broken",
      error: "validation failed",
    });
    const gate = evaluatePromotionGate({ report: failed });
    expect(gate.passed).toBe(false);
    expect(gate.failedExecutions).toBe(1);
    expect(gate.failures.some((failure) => failure.key === "overall.execution_success_rate")).toBe(true);
  });

  it("blocks a regression beyond the configured tolerance", () => {
    const baseline = report(true);
    const candidate = report(true);
    candidate.cases[0].evaluation!.score = 0.95;
    const gate = evaluatePromotionGate({
      report: candidate,
      baseline,
      thresholds: {},
      maximumRegression: 0.01,
    });
    expect(gate.failures).toContainEqual({
      key: "overall.mean_score",
      actual: 0.95,
      required: 0.99,
      reason: "baseline_regression",
    });
  });
});
