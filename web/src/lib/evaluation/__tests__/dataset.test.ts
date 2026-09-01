import { describe, expect, it } from "vitest";
import { dayPageCoreDataset } from "../datasets/daypage-core-v1";
import { evaluateCase } from "../evaluators";
import { buildGoldenOutput } from "../golden";

describe("DayPage core evaluation dataset", () => {
  it("contains a large, balanced, uniquely identified case set", () => {
    expect(dayPageCoreDataset.cases.length).toBeGreaterThanOrEqual(140);
    expect(new Set(dayPageCoreDataset.cases.map((item) => item.id)).size).toBe(
      dayPageCoreDataset.cases.length,
    );
    const categories = new Set(dayPageCoreDataset.cases.map((item) => item.category));
    expect(categories).toEqual(
      new Set(["routing", "context", "response", "action", "memory", "daily", "longitudinal", "safety"]),
    );
  });

  it("has valid deterministic golden outputs for every case", () => {
    for (const evaluationCase of dayPageCoreDataset.cases) {
      const result = evaluateCase(evaluationCase, buildGoldenOutput(evaluationCase));
      expect(result.hard_gate_failures, evaluationCase.id).toEqual([]);
      expect(result.passed, evaluationCase.id).toBe(true);
      expect(result.score, evaluationCase.id).toBe(1);
    }
  });
});
