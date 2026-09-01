import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { Opik } from "opik";
import type { ChatMessage, ChatResponse } from "../src/lib/ai/provider";
import {
  assertContextDecisionWithinCandidates,
  assertSourceRefsWithinMemo,
} from "../src/lib/agent-data-plane/contracts";
import {
  buildMemoProcessingPrompt,
  MEMO_PROCESSING_PROMPT,
  runMemoProcessingModel,
} from "../src/lib/agent-data-plane/memo-processing-model";
import {
  EvaluationExperimentReportSchema,
  type EvaluationCase,
  type EvaluationExperimentReport,
  type ExperimentCaseResult,
} from "../src/lib/evaluation/contracts";
import { dayPageCoreDataset } from "../src/lib/evaluation/datasets/daypage-core-v1";
import { evaluateCase } from "../src/lib/evaluation/evaluators";
import {
  aggregateEvaluationReport,
  DEFAULT_EVALUATION_THRESHOLDS,
  evaluatePromotionGate,
  type EvaluationGateResult,
} from "../src/lib/evaluation/gates";
import { buildGoldenOutput } from "../src/lib/evaluation/golden";
import { judgeResponseQuality } from "../src/lib/evaluation/llm-judge";

type Arguments = { _: string[]; [key: string]: string | boolean | string[] };

function parseArguments(argv: string[]): Arguments {
  const result: Arguments = { _: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (!value.startsWith("--")) {
      result._.push(value);
      continue;
    }
    const [rawKey, inlineValue] = value.slice(2).split("=", 2);
    if (inlineValue !== undefined) {
      result[rawKey] = inlineValue;
    } else if (argv[index + 1] && !argv[index + 1].startsWith("--")) {
      result[rawKey] = argv[index + 1];
      index += 1;
    } else {
      result[rawKey] = true;
    }
  }
  return result;
}

function stringArgument(args: Arguments, key: string, fallback?: string): string | undefined {
  const value = args[key];
  return typeof value === "string" ? value : fallback;
}

function integerArgument(args: Arguments, key: string, fallback: number): number {
  const value = stringArgument(args, key);
  if (value === undefined) return fallback;
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) throw new Error(`--${key} must be a positive integer`);
  return parsed;
}

function promptChecksum(): string {
  return `sha256:${createHash("sha256").update(MEMO_PROCESSING_PROMPT).digest("hex")}`;
}

function reportName(model: string): string {
  const timestamp = new Date().toISOString().replace(/[.:]/g, "-");
  return `daypage-core-${model.replace(/[^a-z0-9._-]+/gi, "-")}-${timestamp}`;
}

function selectCases(args: Arguments): EvaluationCase[] {
  let cases = dayPageCoreDataset.cases;
  const casePattern = stringArgument(args, "case");
  const tag = stringArgument(args, "tag");
  const category = stringArgument(args, "category");
  if (casePattern) cases = cases.filter((item) => item.id.includes(casePattern));
  if (tag) cases = cases.filter((item) => item.tags.includes(tag));
  if (category) cases = cases.filter((item) => item.category === category);
  const limit = integerArgument(args, "limit", cases.length);
  cases = cases.slice(0, limit);
  if (cases.length === 0) throw new Error("No evaluation cases matched the supplied filters");
  return cases;
}

function apiBaseUrl(): string {
  return (
    process.env.OPENAI_BASE_URL ||
    process.env.OPENROUTER_BASE_URL ||
    "https://api.openai.com/v1"
  ).replace(/\/$/, "");
}

function apiKey(): string {
  const value = process.env.OPENROUTER_API_KEY || process.env.OPENAI_API_KEY;
  if (!value) throw new Error("Set OPENAI_API_KEY or OPENROUTER_API_KEY before running model evaluations");
  return value;
}

class OpenAICompatibleEvaluationProvider {
  async chat(
    messages: ChatMessage[],
    options: {
      model?: string;
      temperature?: number;
      maxTokens?: number;
      jsonMode?: boolean;
    } = {},
  ): Promise<ChatResponse> {
    const model = options.model || process.env.OPENAI_MODEL || "gpt-4o-mini";
    const response = await fetch(`${apiBaseUrl()}/chat/completions`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey()}`,
      },
      body: JSON.stringify({
        model,
        messages,
        temperature: options.temperature ?? 0,
        ...(options.maxTokens ? { max_tokens: options.maxTokens } : {}),
        ...(options.jsonMode ? { response_format: { type: "json_object" } } : {}),
      }),
      signal: AbortSignal.timeout(60_000),
    });
    const text = await response.text();
    if (!response.ok) throw new Error(`Model request failed with HTTP ${response.status}`);
    const payload = JSON.parse(text) as {
      model?: string;
      choices?: Array<{ message?: { content?: string } }>;
      usage?: { prompt_tokens?: number; completion_tokens?: number };
    };
    const content = payload.choices?.[0]?.message?.content;
    if (typeof content !== "string") throw new Error("Model response did not contain message content");
    return {
      content,
      model: payload.model ?? model,
      tokens_in: payload.usage?.prompt_tokens ?? 0,
      tokens_out: payload.usage?.completion_tokens ?? 0,
    };
  }
}

async function mapConcurrent<T, U>(
  items: T[],
  concurrency: number,
  worker: (item: T, index: number) => Promise<U>,
): Promise<U[]> {
  const output = new Array<U>(items.length);
  let cursor = 0;
  async function consume(): Promise<void> {
    while (cursor < items.length) {
      const index = cursor;
      cursor += 1;
      output[index] = await worker(items[index], index);
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, consume));
  return output;
}

function candidatePages(evaluationCase: EvaluationCase) {
  return evaluationCase.input.context.map((candidate) => ({
    id: candidate.id,
    slug: `eval/${evaluationCase.id}/${candidate.id}`,
    title: candidate.title,
    body_md: candidate.content,
    version: 1,
  }));
}

async function evaluateModelCase(
  evaluationCase: EvaluationCase,
  model: string,
  provider: OpenAICompatibleEvaluationProvider,
  judgeModel?: string,
): Promise<ExperimentCaseResult> {
  const startedAt = Date.now();
  try {
    const candidates = candidatePages(evaluationCase);
    const prompt = buildMemoProcessingPrompt(
      evaluationCase.input.memo_id,
      evaluationCase.input.entry,
      candidates,
    );
    const generation = await runMemoProcessingModel({
      provider,
      prompt,
      model,
      maxOutputTokens: 4_096,
      timeoutSeconds: 65,
    });
    assertSourceRefsWithinMemo(
      generation.result,
      evaluationCase.input.memo_id,
      evaluationCase.input.entry.length,
    );
    assertContextDecisionWithinCandidates(
      generation.result,
      evaluationCase.input.context.map((candidate) => candidate.id),
    );
    const evaluation = evaluateCase(evaluationCase, generation.result);
    let judgeTokensIn = 0;
    let judgeTokensOut = 0;
    if (judgeModel) {
      const judged = await judgeResponseQuality({
        provider,
        model: judgeModel,
        evaluationCase,
        output: generation.result,
      });
      judgeTokensIn = judged.tokensIn;
      judgeTokensOut = judged.tokensOut;
      evaluation.metrics.push(...judged.metrics);
      evaluation.score =
        evaluation.metrics.reduce((sum, metric) => sum + metric.score, 0) /
        evaluation.metrics.length;
      evaluation.passed =
        evaluation.hard_gate_failures.length === 0 &&
        evaluation.metrics.every((metric) => metric.passed);
    }
    return {
      case_id: evaluationCase.id,
      category: evaluationCase.category,
      tags: evaluationCase.tags,
      status: "completed",
      duration_ms: Date.now() - startedAt,
      tokens_in: generation.tokensIn + judgeTokensIn,
      tokens_out: generation.tokensOut + judgeTokensOut,
      model: generation.model,
      output: generation.result,
      evaluation,
    };
  } catch (error) {
    return {
      case_id: evaluationCase.id,
      category: evaluationCase.category,
      tags: evaluationCase.tags,
      status: "failed",
      duration_ms: Date.now() - startedAt,
      tokens_in: 0,
      tokens_out: 0,
      model,
      error: error instanceof Error ? error.message.slice(0, 2_000) : String(error).slice(0, 2_000),
    };
  }
}

function makeReport(input: {
  cases: ExperimentCaseResult[];
  name: string;
  model: string;
  startedAt: string;
}): EvaluationExperimentReport {
  return EvaluationExperimentReportSchema.parse({
    schema_version: 1,
    dataset: {
      name: dayPageCoreDataset.name,
      version: dayPageCoreDataset.version,
      case_count: input.cases.length,
    },
    experiment: {
      name: input.name,
      model: input.model,
      prompt_checksum: promptChecksum(),
      started_at: input.startedAt,
      completed_at: new Date().toISOString(),
    },
    cases: input.cases,
  });
}

async function loadReport(filePath: string): Promise<EvaluationExperimentReport> {
  return EvaluationExperimentReportSchema.parse(JSON.parse(await fs.readFile(filePath, "utf8")));
}

async function writeReport(report: EvaluationExperimentReport, requestedPath?: string): Promise<string> {
  const destination = path.resolve(
    requestedPath ?? path.join("..", "output", "evaluation", `${report.experiment.name}.json`),
  );
  await fs.mkdir(path.dirname(destination), { recursive: true });
  await fs.writeFile(destination, `${JSON.stringify(report, null, 2)}\n`, "utf8");
  return destination;
}

function printGate(
  report: EvaluationExperimentReport,
  baseline?: EvaluationExperimentReport,
): EvaluationGateResult {
  const gate = evaluatePromotionGate({ report, baseline });
  process.stdout.write(`${JSON.stringify(gate, null, 2)}\n`);
  return gate;
}

function opikClient(): Opik {
  const apiUrl = process.env.OPIK_URL_OVERRIDE?.trim();
  const selfHosted = Boolean(apiUrl && !/comet\.com/i.test(apiUrl));
  const apiKeyValue = process.env.OPIK_API_KEY?.trim() ?? "";
  if (!selfHosted && !apiKeyValue) throw new Error("Set OPIK_API_KEY, or OPIK_URL_OVERRIDE for self-hosted Opik");
  return new Opik({
    apiKey: apiKeyValue,
    ...(apiUrl ? { apiUrl } : {}),
    projectName: process.env.OPIK_PROJECT_NAME?.trim() || "daypage-agent",
    workspaceName: process.env.OPIK_WORKSPACE?.trim() || "default",
    holdUntilFlush: true,
  });
}

function opikDatasetName(): string {
  return `${dayPageCoreDataset.name}-${dayPageCoreDataset.version}`;
}

async function syncDataset(client: Opik) {
  const projectName = process.env.OPIK_PROJECT_NAME?.trim() || "daypage-agent";
  const dataset = await client.getOrCreateDataset(
    opikDatasetName(),
    dayPageCoreDataset.description,
    projectName,
  );
  await dataset.insert(
    dayPageCoreDataset.cases.map((item) => ({
      case_id: item.id,
      case_version: item.version,
      category: item.category,
      tags: item.tags,
      input: item.input,
      expected: item.expected,
      forbidden: item.forbidden,
      notes: item.notes ?? null,
    })),
  );
  await client.flush({ silent: true });
  return dataset;
}

async function uploadExperiment(
  report: EvaluationExperimentReport,
): Promise<{ id: string; url?: string }> {
  const client = opikClient();
  const dataset = await syncDataset(client);
  const datasetItems = await dataset.getItems();
  const ids = new Map(
    datasetItems.map((item) => [String(item.case_id), item.id]),
  );
  const projectName = process.env.OPIK_PROJECT_NAME?.trim() || "daypage-agent";
  const prompt = await client.createPrompt({
    name: "daypage.memo-understand",
    prompt: MEMO_PROCESSING_PROMPT,
    projectName,
  });
  const existingExperiments = await client.getExperimentsByName(report.experiment.name, projectName);
  const experiment = existingExperiments[0] ?? await client.createExperiment({
    datasetName: opikDatasetName(),
    name: report.experiment.name,
    projectName,
    prompts: [prompt],
    datasetVersionId: (await dataset.getVersionInfo())?.id,
    tags: [
      `dataset:${dayPageCoreDataset.version}`,
      `model:${report.experiment.model}`,
      `prompt:${report.experiment.prompt_checksum.slice(0, 12)}`,
    ],
    experimentConfig: {
      model: report.experiment.model,
      prompt_checksum: report.experiment.prompt_checksum,
      dataset_version: report.dataset.version,
    },
  });
  const items = report.cases.map((item) => {
    const datasetItemId = ids.get(item.case_id);
    if (!datasetItemId) throw new Error(`Opik dataset is missing case ${item.case_id}`);
    return {
      datasetItemId,
      evaluateTaskResult:
        item.status === "completed"
          ? ({ output: item.output, duration_ms: item.duration_ms } as Record<string, unknown>)
          : ({ error: item.error ?? "evaluation failed" } as Record<string, unknown>),
      feedbackScores: (item.evaluation?.metrics ?? []).map((metric) => ({
        name: metric.key,
        value: metric.score,
        reason: metric.reason,
        source: "sdk" as const,
      })),
    };
  });
  for (let index = 0; index < items.length; index += 25) {
    await client.api.experiments.experimentItemsBulk({
      experimentName: report.experiment.name,
      experimentId: experiment.id,
      datasetName: opikDatasetName(),
      projectName,
      items: items.slice(index, index + 25),
    });
  }
  await client.flush({ silent: true });
  const url = await experiment.getUrl().catch(() => undefined);
  return { id: experiment.id, ...(url ? { url } : {}) };
}

async function persistExperiment(input: {
  report: EvaluationExperimentReport;
  gate: EvaluationGateResult;
  opik?: { id: string; url?: string };
}): Promise<void> {
  const databaseUrl = process.env.DATABASE_URL?.trim();
  if (!databaseUrl) throw new Error("--persist requires DATABASE_URL");
  const { default: postgres } = await import("postgres");
  const sql = postgres(databaseUrl, { max: 1 });
  try {
    await sql`
      insert into evaluation_experiments (
        name, dataset_name, dataset_version, baseline_config, candidate_config,
        thresholds, results, git_sha, status, promotion_decision,
        opik_experiment_id, opik_url, started_at, completed_at
      ) values (
        ${input.report.experiment.name},
        ${input.report.dataset.name},
        ${input.report.dataset.version},
        ${sql.json({})},
        ${sql.json({
          model: input.report.experiment.model,
          prompt_checksum: input.report.experiment.prompt_checksum,
          case_count: input.report.dataset.case_count,
        })},
        ${sql.json(DEFAULT_EVALUATION_THRESHOLDS)},
        ${sql.json({
          passed: input.gate.passed,
          failed_executions: input.gate.failedExecutions,
          metrics: aggregateEvaluationReport(input.report),
          failures: input.gate.failures,
        })},
        ${process.env.GIT_SHA ?? null},
        'completed',
        ${input.gate.passed ? "promote" : "hold"},
        ${input.opik?.id ?? null},
        ${input.opik?.url ?? null},
        ${input.report.experiment.started_at},
        ${input.report.experiment.completed_at}
      )
      on conflict (name) do update set
        candidate_config = excluded.candidate_config,
        thresholds = excluded.thresholds,
        results = excluded.results,
        git_sha = excluded.git_sha,
        status = excluded.status,
        promotion_decision = excluded.promotion_decision,
        opik_experiment_id = coalesce(excluded.opik_experiment_id, evaluation_experiments.opik_experiment_id),
        opik_url = coalesce(excluded.opik_url, evaluation_experiments.opik_url),
        started_at = excluded.started_at,
        completed_at = excluded.completed_at,
        updated_at = now()
    `;
  } finally {
    await sql.end();
  }
}

async function validateCommand(args: Arguments): Promise<void> {
  const cases = selectCases(args);
  const startedAt = new Date().toISOString();
  const results = cases.map((evaluationCase) => {
    const output = buildGoldenOutput(evaluationCase);
    return {
      case_id: evaluationCase.id,
      category: evaluationCase.category,
      tags: evaluationCase.tags,
      status: "completed" as const,
      duration_ms: 0,
      tokens_in: 0,
      tokens_out: 0,
      model: "deterministic-golden",
      output,
      evaluation: evaluateCase(evaluationCase, output),
    };
  });
  const report = makeReport({ cases: results, name: "daypage-core-golden", model: "deterministic-golden", startedAt });
  if (stringArgument(args, "output")) await writeReport(report, stringArgument(args, "output"));
  if (!printGate(report).passed) process.exitCode = 1;
}

async function runCommand(args: Arguments): Promise<void> {
  const cases = selectCases(args);
  const model = stringArgument(args, "model", process.env.OPENAI_MODEL || "gpt-4o-mini")!;
  const startedAt = new Date().toISOString();
  const name = stringArgument(args, "name", reportName(model))!;
  const provider = new OpenAICompatibleEvaluationProvider();
  const judgeModel = stringArgument(args, "judge-model");
  const results = await mapConcurrent(cases, integerArgument(args, "concurrency", 4), (item) =>
    evaluateModelCase(item, model, provider, judgeModel),
  );
  const report = makeReport({ cases: results, name, model, startedAt });
  const destination = await writeReport(report, stringArgument(args, "output"));
  process.stdout.write(`Report: ${destination}\n`);
  const baselinePath = stringArgument(args, "baseline");
  const baseline = baselinePath ? await loadReport(path.resolve(baselinePath)) : undefined;
  const gate = printGate(report, baseline);
  const opik = args.opik === true ? await uploadExperiment(report) : undefined;
  if (args.persist === true) await persistExperiment({ report, gate, opik });
  if (!gate.passed) process.exitCode = 1;
}

async function gateCommand(args: Arguments): Promise<void> {
  const reportPath = stringArgument(args, "report");
  if (!reportPath) throw new Error("gate requires --report <path>");
  const baselinePath = stringArgument(args, "baseline");
  const report = await loadReport(path.resolve(reportPath));
  const baseline = baselinePath ? await loadReport(path.resolve(baselinePath)) : undefined;
  if (!printGate(report, baseline).passed) process.exitCode = 1;
}

async function syncOpikCommand(): Promise<void> {
  const client = opikClient();
  const dataset = await syncDataset(client);
  await client.createPrompt({
    name: "daypage.memo-understand",
    prompt: MEMO_PROCESSING_PROMPT,
    projectName: process.env.OPIK_PROJECT_NAME?.trim() || "daypage-agent",
  });
  process.stdout.write(
    `${JSON.stringify({
      dataset: dataset.name,
      items: await dataset.getItemsCount(),
      prompt: "daypage.memo-understand",
      prompt_checksum: promptChecksum(),
    }, null, 2)}\n`,
  );
}

async function uploadOpikCommand(args: Arguments): Promise<void> {
  const reportPath = stringArgument(args, "report");
  if (!reportPath) throw new Error("upload-opik requires --report <path>");
  await uploadExperiment(await loadReport(path.resolve(reportPath)));
}

async function annotationQueueCommand(args: Arguments): Promise<void> {
  const filter = stringArgument(args, "filter");
  if (!filter) throw new Error("annotation-queue requires --filter <Opik OQL expression>");
  const client = opikClient();
  const projectName = process.env.OPIK_PROJECT_NAME?.trim() || "daypage-agent";
  const name = stringArgument(args, "name", "daypage-agent-review")!;
  const existing = (await client.getTracesAnnotationQueues({ projectName })).find(
    (queue) => queue.name === name,
  );
  const queue = existing ?? await client.createTracesAnnotationQueue({
    name,
    projectName,
    description: "Human review queue for DayPage Agent routing, context, response, action, and Memory quality.",
    instructions:
      "Review the selected response policy, chosen context, grounded claims, proposed actions, and Memory proposals. Never copy private content into a shared dataset; promote only synthetic, consented, or approved redacted cases.",
    commentsEnabled: true,
  });
  const traces = await client.searchTraces({
    projectName,
    filterString: filter,
    maxResults: integerArgument(args, "limit", 100),
    truncate: true,
  });
  if (traces.length > 0) await queue.addTraces(traces);
  process.stdout.write(
    `${JSON.stringify({ queue: queue.name, matched: traces.length, queue_items: await queue.getItemsCount() }, null, 2)}\n`,
  );
}

async function main(): Promise<void> {
  const args = parseArguments(process.argv.slice(2));
  const command = args._[0] ?? "validate";
  if (command === "validate") return validateCommand(args);
  if (command === "run") return runCommand(args);
  if (command === "gate") return gateCommand(args);
  if (command === "sync-opik") return syncOpikCommand();
  if (command === "upload-opik") return uploadOpikCommand(args);
  if (command === "annotation-queue") return annotationQueueCommand(args);
  throw new Error(`Unknown command ${command}`);
}

main().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
});
