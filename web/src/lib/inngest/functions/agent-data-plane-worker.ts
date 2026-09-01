import { and, eq, inArray, sql } from "drizzle-orm";
import { inngest } from "@/lib/inngest/client";
import { db } from "@/lib/db/client";
import { agent_artifacts, artifact_sources, automations } from "@/lib/db/schema";
import { isAgentDataPlaneEnabled } from "@/lib/agent-data-plane/feature-flags";
import {
  claimDataPlaneJob,
  completeDataPlaneJob,
  failDataPlaneJob,
  type LeasedDataPlaneJob,
} from "@/lib/agent-data-plane/jobs";
import { understandMemo } from "@/lib/agent-data-plane/memo-understand";
import { synthesizeDaily } from "@/lib/agent-data-plane/daily";
import { synthesizeWeekly } from "@/lib/agent-data-plane/weekly";
import {
  automationJobInput,
  emitAutomationEvent,
  enqueueDueAutomations,
} from "@/lib/agent-data-plane/automations";
import { processOneToolExecution } from "@/lib/agent-data-plane/tools";
import { archiveMemoArtifactsExcept } from "@/lib/agent-data-plane/artifacts";
import { drainEvaluationExports } from "@/lib/evaluation/opik-exporter";

const MAX_JOBS_PER_TICK = 20;
const MAX_TOOL_EXECUTIONS_PER_TICK = 10;

async function handleJob(job: LeasedDataPlaneJob): Promise<void> {
  const payload = job.payload as Record<string, unknown>;
  if (job.type === "memo.synced") {
    await understandMemo({
      memoId: String(payload.memo_id),
      userId: job.user_id,
      acceptedRevision: Number(payload.accepted_revision),
      acceptedContentHash:
        typeof payload.content_hash === "string" ? payload.content_hash : undefined,
      explicitRetry: payload.explicit_retry === true,
    });
    return;
  }
  if (job.type === "memo.deleted") {
    await handleMemoDeleted(job.user_id, String(payload.memo_id));
    return;
  }
  if (job.type === "daily.synthesize" || job.type === "daily.finalize") {
    await synthesizeDaily({
      userId: job.user_id,
      localDate: String(payload.local_date),
      timezone: String(payload.timezone ?? "UTC"),
      finalize: job.type === "daily.finalize" || payload.finalize === true,
      shadow: typeof payload.shadow === "boolean" ? payload.shadow : undefined,
      explicitRetry: payload.explicit_retry === true,
    });
    return;
  }
  if (job.type === "weekly.review") {
    await synthesizeWeekly({
      userId: job.user_id,
      weekStart: String(payload.week_start),
      timezone: String(payload.timezone ?? "UTC"),
      shadow: typeof payload.shadow === "boolean" ? payload.shadow : undefined,
      explicitRetry: payload.explicit_retry === true,
    });
    return;
  }
  if (job.type === "automation.due") {
    const [automation] = await db
      .select()
      .from(automations)
      .where(
        and(
          eq(automations.id, String(payload.automation_id)),
          eq(automations.user_id, job.user_id),
          eq(automations.enabled, true),
        ),
      )
      .limit(1);
    if (!automation) return;
    const input = await automationJobInput(
      automation,
      new Date(String(payload.scheduled_for)),
    );
    if (input.kind === "daily") {
      await synthesizeDaily({
        userId: job.user_id,
        localDate: input.localDate,
        timezone: input.timezone,
        finalize: input.finalize,
        agentId: automation.agent_id ?? undefined,
      });
    } else if (input.kind === "weekly") {
      await synthesizeWeekly({
        userId: job.user_id,
        weekStart: input.weekStart,
        timezone: input.timezone,
        agentId: automation.agent_id ?? undefined,
      });
    }
  }
}

async function handleMemoDeleted(userId: string, memoId: string): Promise<void> {
  const affected = await db
    .select({
      artifact_id: agent_artifacts.id,
      kind: agent_artifacts.kind,
      local_date: agent_artifacts.local_date,
      timezone: agent_artifacts.timezone,
      shadow: sql<boolean>`${agent_artifacts.perspective_key} like 'shadow:%'`,
    })
    .from(artifact_sources)
    .innerJoin(agent_artifacts, eq(artifact_sources.artifact_id, agent_artifacts.id))
    .where(
      and(
        eq(artifact_sources.memo_id, memoId),
        eq(agent_artifacts.user_id, userId),
        inArray(agent_artifacts.kind, ["observation", "daily_contribution", "page_patch"]),
      ),
  );
  if (affected.length === 0) return;
  await archiveMemoArtifactsExcept({ userId, memoId, keepArtifactIds: [] });
  // Canonical page patches are archived by archiveMemoArtifactsExcept only
  // after their exact contribution is safely retracted. Shadow artifacts and
  // non-page artifacts have no materialized page side effect.
  const directlyArchivableIds = affected
    .filter((item) => item.kind !== "page_patch" || item.shadow)
    .map((item) => item.artifact_id);
  if (directlyArchivableIds.length) {
    await db
      .update(agent_artifacts)
      .set({ status: "archived", updated_at: new Date() })
      .where(inArray(agent_artifacts.id, directlyArchivableIds));
  }

  const dates = new Map<string, { localDate: string; timezone: string; shadow: boolean }>();
  for (const item of affected) {
    if (item.kind !== "daily_contribution" || !item.local_date || !item.timezone) continue;
    const key = `${item.local_date}:${item.timezone}:${item.shadow}`;
    dates.set(key, { localDate: item.local_date, timezone: item.timezone, shadow: item.shadow });
  }
  for (const value of dates.values()) {
    await emitAutomationEvent({
      userId,
      event: "artifact.daily_contribution.changed",
      payload: {
        local_date: value.localDate,
        timezone: value.timezone,
        shadow: value.shadow,
      },
    });
  }
}

export async function drainAgentDataPlane(): Promise<{
  jobs: number;
  failures: number;
  toolExecutions: number;
  evaluationExports: number;
  evaluationExportFailures: number;
}> {
  if (!isAgentDataPlaneEnabled()) {
    return {
      jobs: 0,
      failures: 0,
      toolExecutions: 0,
      evaluationExports: 0,
      evaluationExportFailures: 0,
    };
  }
  await enqueueDueAutomations();
  let jobs = 0;
  let failures = 0;
  for (; jobs < MAX_JOBS_PER_TICK; jobs += 1) {
    const job = await claimDataPlaneJob();
    if (!job) break;
    try {
      await handleJob(job);
      await completeDataPlaneJob(job);
    } catch (error) {
      failures += 1;
      await failDataPlaneJob(job, error);
    }
  }

  let toolExecutions = 0;
  for (; toolExecutions < MAX_TOOL_EXECUTIONS_PER_TICK; toolExecutions += 1) {
    if (!(await processOneToolExecution())) break;
  }
  const evaluation = await drainEvaluationExports(MAX_JOBS_PER_TICK);
  return {
    jobs,
    failures,
    toolExecutions,
    evaluationExports: evaluation.processed,
    evaluationExportFailures: evaluation.failures,
  };
}

export const agentDataPlaneWorker = inngest.createFunction(
  {
    id: "agent-data-plane-worker",
    name: "Agent Data Plane — durable queue worker",
    concurrency: { limit: 1 },
  },
  [{ cron: "* * * * *" }, { event: "agent/data-plane.drain" }],
  async () => drainAgentDataPlane(),
);
