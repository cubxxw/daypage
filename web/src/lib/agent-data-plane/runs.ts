import "server-only";
import { and, desc, eq, sql } from "drizzle-orm";
import { db } from "@/lib/db/client";
import {
  agent_run_steps,
  agent_runs,
  agents,
  type AgentRun,
  type SkillVersion,
} from "@/lib/db/schema";
import { hashJson, sha256 } from "./hash";
import type { StepReceipt } from "./contracts";
import { enqueueEvaluationExport } from "@/lib/evaluation/outbox";

const DEFAULT_AGENT_SNAPSHOT = {
  name: "DayPage Intelligence",
  instructions: "Ground every derived statement in the supplied user source.",
  modelPolicy: { preferredModel: "gpt-4o-mini" },
  knowledgeScope: { topK: 8, recencyDays: 3650 },
  budgetPolicy: {
    maxInputTokens: 16_000,
    maxOutputTokens: 2_048,
    maxToolCalls: 4,
    timeoutSeconds: 120,
  },
};

const STALE_RUN_MS = 9 * 60_000;

export interface StartRunInput {
  userId: string;
  skill: SkillVersion;
  triggerType: string;
  triggerRef?: string;
  triggerSnapshot: Record<string, unknown>;
  memoId?: string;
  memoRevision?: number;
  agentId?: string;
  shadow?: boolean;
  explicitRetry?: boolean;
}

export interface StartRunResult {
  run: AgentRun;
  shouldExecute: boolean;
}

async function loadAgentSnapshot(userId: string, agentId?: string) {
  if (!agentId) return DEFAULT_AGENT_SNAPSHOT;
  const [agent] = await db
    .select()
    .from(agents)
    .where(and(eq(agents.id, agentId), eq(agents.user_id, userId)))
    .limit(1);
  if (!agent) throw new Error(`Agent not found: ${agentId}`);
  return {
    id: agent.id,
    name: agent.name,
    instructions: agent.instructions || agent.persona_prompt,
    modelPolicy: agent.model_policy,
    knowledgeScope: agent.knowledge_scope,
    budgetPolicy: agent.budget_policy,
  };
}

export function memoRunIdempotencyKey(input: {
  userId: string;
  memoId: string;
  memoRevision: number;
  skillChecksum: string;
  shadow?: boolean;
}): string {
  const base = `${input.userId}:${input.memoId}:${input.memoRevision}:${input.skillChecksum}`;
  return input.shadow ? `${base}:shadow` : base;
}

export async function startRun(input: StartRunInput): Promise<StartRunResult> {
  const agentSnapshot = await loadAgentSnapshot(input.userId, input.agentId);
  const key = input.memoId && input.memoRevision !== undefined
    ? memoRunIdempotencyKey({
        userId: input.userId,
        memoId: input.memoId,
        memoRevision: input.memoRevision,
        skillChecksum: input.skill.checksum,
        shadow: input.shadow,
      })
    : `${input.userId}:${input.triggerType}:${input.triggerRef ?? hashJson(input.triggerSnapshot)}:${input.skill.checksum}${input.shadow ? ":shadow" : ""}`;

  return db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${key}, 31415))`);
    const [current] = await tx
      .select()
      .from(agent_runs)
      .where(
        input.shadow
          ? and(eq(agent_runs.user_id, input.userId), eq(agent_runs.idempotency_key, key))
          : and(
              eq(agent_runs.user_id, input.userId),
              eq(agent_runs.idempotency_key, key),
              eq(agent_runs.is_canonical, true),
            ),
      )
      .orderBy(desc(agent_runs.attempt))
      .limit(1);

    if (current && !input.explicitRetry) {
      const recoverable =
        (current.status === "queued" || current.status === "running") &&
        current.updated_at.getTime() <= Date.now() - STALE_RUN_MS;
      if (!recoverable) return { run: current, shouldExecute: false };
      const [recovered] = await tx
        .update(agent_runs)
        .set({ status: "queued", error: null, updated_at: new Date() })
        .where(eq(agent_runs.id, current.id))
        .returning();
      return { run: recovered ?? current, shouldExecute: true };
    }
    if (current && !input.shadow) {
      await tx
        .update(agent_runs)
        .set({ is_canonical: false, updated_at: new Date() })
        .where(eq(agent_runs.id, current.id));
    }

    const [latest] = await tx
      .select({ attempt: agent_runs.attempt })
      .from(agent_runs)
      .where(and(eq(agent_runs.user_id, input.userId), eq(agent_runs.idempotency_key, key)))
      .orderBy(desc(agent_runs.attempt))
      .limit(1);
    const attempt = (latest?.attempt ?? 0) + 1;

    const [created] = await tx
      .insert(agent_runs)
      .values({
        user_id: input.userId,
        trigger_type: input.triggerType,
        trigger_ref: input.triggerRef ?? null,
        trigger_snapshot: input.triggerSnapshot,
        memo_id: input.memoId ?? null,
        memo_revision: input.memoRevision ?? null,
        agent_id: input.agentId ?? null,
        skill_version_id: input.skill.id,
        agent_snapshot: agentSnapshot,
        skill_snapshot: input.skill.manifest,
        tool_policy_snapshot: {
          requiredTools: input.skill.required_tools,
          optionalTools: input.skill.optional_tools,
          defaultRisk: input.skill.default_risk,
        },
        skill_checksum: input.skill.checksum,
        idempotency_key: key,
        attempt,
        is_canonical: !input.shadow,
        shadow: input.shadow ?? false,
        status: "queued",
        budget: (agentSnapshot.budgetPolicy ?? DEFAULT_AGENT_SNAPSHOT.budgetPolicy) as Record<string, unknown>,
      })
      .returning();
    if (!created) throw new Error("Failed to create Agent Run");
    return { run: created, shouldExecute: true };
  });
}

export async function markRunRunning(runId: string): Promise<void> {
  await db
    .update(agent_runs)
    .set({ status: "running", started_at: new Date(), updated_at: new Date(), error: null })
    .where(eq(agent_runs.id, runId));
}

export async function completeRun(
  runId: string,
  summary: string,
  status: "completed" | "needs_review" = "completed",
): Promise<void> {
  const [completed] = await db
    .update(agent_runs)
    .set({ status, summary, completed_at: new Date(), updated_at: new Date() })
    .where(eq(agent_runs.id, runId))
    .returning({ id: agent_runs.id, user_id: agent_runs.user_id });
  if (completed) {
    await enqueueEvaluationExport({
      userId: completed.user_id,
      runId: completed.id,
      entityType: "trace",
      entityId: completed.id,
      operation: "upsert",
      idempotencyKey: `opik:trace:${completed.id}:completed:v1`,
    }).catch((error) => {
      console.error(`[evaluation] failed to enqueue completed Run ${completed.id}`, error);
    });
  }
}

export async function failRun(runId: string, error: unknown): Promise<void> {
  const payload = {
    name: error instanceof Error ? error.name : "Error",
    message: error instanceof Error ? error.message : String(error),
  };
  const [failed] = await db
    .update(agent_runs)
    .set({
      status: "failed",
      error: payload,
      is_canonical: false,
      completed_at: new Date(),
      updated_at: new Date(),
    })
    .where(eq(agent_runs.id, runId))
    .returning({ id: agent_runs.id, user_id: agent_runs.user_id });
  if (failed) {
    await enqueueEvaluationExport({
      userId: failed.user_id,
      runId: failed.id,
      entityType: "trace",
      entityId: failed.id,
      operation: "upsert",
      idempotencyKey: `opik:trace:${failed.id}:failed:v1`,
    }).catch((exportError) => {
      console.error(`[evaluation] failed to enqueue failed Run ${failed.id}`, exportError);
    });
  }
}

export async function runAuditedStep<T>(input: {
  runId: string;
  ordinal: number;
  stepKey: string;
  toolKey?: string;
  stepInput: unknown;
  execute: () => Promise<{ value: T; tokensIn?: number; tokensOut?: number; details?: Record<string, unknown> }>;
}): Promise<{ value: T; receipt: StepReceipt }> {
  const startedAt = new Date();
  const inputHash = hashJson(input.stepInput);
  const [step] = await db
    .insert(agent_run_steps)
    .values({
      run_id: input.runId,
      ordinal: input.ordinal,
      step_key: input.stepKey,
      tool_key: input.toolKey ?? null,
      status: "running",
      input_hash: inputHash,
      started_at: startedAt,
    })
    .onConflictDoUpdate({
      target: [agent_run_steps.run_id, agent_run_steps.step_key],
      set: {
        status: "running",
        input_hash: inputHash,
        error: null,
        started_at: startedAt,
        completed_at: null,
      },
    })
    .returning();
  if (!step) throw new Error(`Failed to start run step ${input.stepKey}`);

  try {
    const result = await input.execute();
    const completedAt = new Date();
    const durationMs = completedAt.getTime() - startedAt.getTime();
    const outputHash = hashJson(result.value);
    const receipt: StepReceipt = {
      step: input.stepKey,
      status: "completed",
      input_hash: inputHash,
      output_hash: outputHash,
      tokens_in: result.tokensIn ?? 0,
      tokens_out: result.tokensOut ?? 0,
      duration_ms: durationMs,
      ...(input.toolKey ? { tool: input.toolKey } : {}),
      ...(result.details ? { details: result.details } : {}),
    };
    await db
      .update(agent_run_steps)
      .set({
        status: "completed",
        output_hash: outputHash,
        tokens_in: receipt.tokens_in,
        tokens_out: receipt.tokens_out,
        duration_ms: durationMs,
        receipt,
        completed_at: completedAt,
      })
      .where(eq(agent_run_steps.id, step.id));
    return { value: result.value, receipt };
  } catch (error) {
    const completedAt = new Date();
    await db
      .update(agent_run_steps)
      .set({
        status: "failed",
        duration_ms: completedAt.getTime() - startedAt.getTime(),
        error: {
          name: error instanceof Error ? error.name : "Error",
          message: error instanceof Error ? error.message : String(error),
        },
        completed_at: completedAt,
      })
      .where(eq(agent_run_steps.id, step.id));
    throw error;
  }
}

export function inputDigest(value: string): string {
  return sha256(value);
}
