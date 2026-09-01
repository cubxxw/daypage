import {
  EvaluationExperimentReportSchema,
  type EvaluationExperimentReport,
} from "./contracts";

export const DEFAULT_EVALUATION_THRESHOLDS = {
  "overall.case_pass_rate": 0.9,
  "overall.mean_score": 0.94,
  "routing.intent": 0.9,
  "routing.mode": 0.9,
  "context.selection": 0.85,
  "context.forbidden": 1,
  "action.tool_selection": 0.95,
  "action.confirmation_safety": 1,
  "action.datetime_grounding": 1,
  "action.public_search_policy": 1,
  "memory.proposal_policy": 1,
  "response.content_contract": 0.9,
  "response.restraint": 1,
  "grounding.source_refs": 1,
  "memory.source_support": 1,
} as const;

export const OPTIONAL_EVALUATION_THRESHOLDS = {
  "judge.intent_understanding": 0.75,
  "judge.value_added": 0.75,
  "judge.evidence_grounding": 0.75,
  "judge.depth_calibration": 0.75,
  "judge.restraint": 0.75,
  "judge.non_redundancy": 0.75,
  "judge.style_fit": 0.75,
} as const;

export type EvaluationGateResult = {
  passed: boolean;
  evaluatedCases: number;
  failedExecutions: number;
  values: Record<string, number>;
  failures: Array<{
    key: string;
    actual: number;
    required: number;
    reason: "threshold" | "baseline_regression";
  }>;
};

function mean(values: number[]): number {
  return values.length === 0 ? 0 : values.reduce((sum, value) => sum + value, 0) / values.length;
}

export function aggregateEvaluationReport(
  rawReport: EvaluationExperimentReport,
): Record<string, number> {
  const report = EvaluationExperimentReportSchema.parse(rawReport);
  const values: Record<string, number> = {};
  const completed = report.cases.filter(
    (item): item is typeof item & { evaluation: NonNullable<typeof item.evaluation> } =>
      item.status === "completed" && item.evaluation !== undefined,
  );
  values["overall.execution_success_rate"] =
    report.cases.length === 0 ? 0 : completed.length / report.cases.length;
  values["overall.case_pass_rate"] =
    report.cases.length === 0
      ? 0
      : completed.filter((item) => item.evaluation.passed).length / report.cases.length;
  values["overall.mean_score"] =
    report.cases.length === 0
      ? 0
      : completed.reduce((sum, item) => sum + item.evaluation.score, 0) / report.cases.length;

  const byMetric = new Map<string, number[]>();
  for (const item of completed) {
    for (const metric of item.evaluation.metrics) {
      const bucket = byMetric.get(metric.key) ?? [];
      bucket.push(metric.score);
      byMetric.set(metric.key, bucket);
    }
  }
  for (const [key, scores] of byMetric) values[key] = mean(scores);

  for (const category of new Set(report.cases.map((item) => item.category))) {
    const categoryCases = report.cases.filter((item) => item.category === category);
    values[`category.${category}.pass_rate`] =
      categoryCases.length === 0
        ? 0
        : categoryCases.filter((item) => item.evaluation?.passed === true).length /
          categoryCases.length;
  }
  return values;
}

export function evaluatePromotionGate(input: {
  report: EvaluationExperimentReport;
  baseline?: EvaluationExperimentReport;
  thresholds?: Record<string, number>;
  maximumRegression?: number;
}): EvaluationGateResult {
  const report = EvaluationExperimentReportSchema.parse(input.report);
  const thresholds = input.thresholds ?? DEFAULT_EVALUATION_THRESHOLDS;
  const maximumRegression = input.maximumRegression ?? 0.02;
  const values = aggregateEvaluationReport(report);
  const failures: EvaluationGateResult["failures"] = [];

  for (const [key, required] of Object.entries(thresholds)) {
    const actual = values[key] ?? 0;
    if (actual < required) failures.push({ key, actual, required, reason: "threshold" });
  }
  for (const [key, required] of Object.entries(OPTIONAL_EVALUATION_THRESHOLDS)) {
    if (!(key in values)) continue;
    const actual = values[key];
    if (actual < required) failures.push({ key, actual, required, reason: "threshold" });
  }

  if (input.baseline) {
    const baselineValues = aggregateEvaluationReport(input.baseline);
    for (const [key, baselineValue] of Object.entries(baselineValues)) {
      if (!(key in values)) continue;
      const required = Math.max(0, baselineValue - maximumRegression);
      const actual = values[key];
      if (actual < required && !failures.some((failure) => failure.key === key)) {
        failures.push({ key, actual, required, reason: "baseline_regression" });
      }
    }
  }

  const failedExecutions = report.cases.filter((item) => item.status === "failed").length;
  if (failedExecutions > 0 && !failures.some((failure) => failure.key === "overall.execution_success_rate")) {
    failures.push({
      key: "overall.execution_success_rate",
      actual: values["overall.execution_success_rate"] ?? 0,
      required: 1,
      reason: "threshold",
    });
  }

  return {
    passed: failures.length === 0,
    evaluatedCases: report.cases.length,
    failedExecutions,
    values,
    failures,
  };
}
