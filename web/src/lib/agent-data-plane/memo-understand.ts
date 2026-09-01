import "server-only";
import { and, desc, eq, ne } from "drizzle-orm";
import { db } from "@/lib/db/client";
import { llm, type LLMProvider } from "@/lib/ai";
import { memos, pages, type AgentRun } from "@/lib/db/schema";
import {
  MemoUnderstandingSchema,
  assertContextDecisionWithinCandidates,
  assertSourceRefsWithinMemo,
  type AgentOutputEnvelope,
  type StepReceipt,
} from "./contracts";
import {
  buildMemoProcessingPrompt,
  runMemoProcessingModel,
} from "./memo-processing-model";
import {
  archiveMemoArtifactsExcept,
  persistMemoArtifacts,
  readUserTimezone,
  rollbackRunArtifacts,
} from "./artifacts";
import { emitAutomationEvent } from "./automations";
import { agentDataPlaneMode } from "./feature-flags";
import { reconcilePagePatch } from "./page-reconcile";
import { getActiveSkill } from "./registry";
import {
  completeRun,
  failRun,
  markRunRunning,
  runAuditedStep,
  startRun,
} from "./runs";
import { createActionProposals } from "./tools";
import { localDate } from "./time";
import { persistProductionEvaluations } from "@/lib/evaluation/online";

const MAX_CANDIDATE_PAGES = 8;

export interface UnderstandMemoInput {
  memoId: string;
  userId?: string;
  acceptedRevision?: number;
  acceptedContentHash?: string;
  explicitRetry?: boolean;
  forceShadow?: boolean;
  agentId?: string;
}

export interface UnderstandMemoResult {
  run?: AgentRun;
  executed: boolean;
  skipped?: "stale_revision" | "content_hash_mismatch";
  envelope?: AgentOutputEnvelope;
}

function readBudget(snapshot: unknown) {
  const value = (snapshot ?? {}) as Record<string, unknown>;
  return {
    maxOutputTokens:
      typeof value.maxOutputTokens === "number" ? Math.max(256, value.maxOutputTokens) : 2_048,
    timeoutSeconds:
      typeof value.timeoutSeconds === "number" ? Math.max(5, value.timeoutSeconds) : 120,
  };
}

function readModel(snapshot: unknown): string | undefined {
  const value = (snapshot ?? {}) as Record<string, unknown>;
  return typeof value.preferredModel === "string" ? value.preferredModel : undefined;
}

export async function understandMemo(
  input: UnderstandMemoInput,
  provider: LLMProvider = llm,
): Promise<UnderstandMemoResult> {
  const [memo] = await db
    .select()
    .from(memos)
    .where(
      input.userId
        ? and(eq(memos.id, input.memoId), eq(memos.user_id, input.userId))
        : eq(memos.id, input.memoId),
    )
    .limit(1);
  if (!memo) throw new Error(`Memo not found: ${input.memoId}`);
  const currentRevision = memo.sync_revision > 0 ? memo.sync_revision : memo.sync_change_sequence;
  if (input.acceptedRevision !== undefined && input.acceptedRevision !== currentRevision) {
    return { executed: false, skipped: "stale_revision" };
  }
  if (
    input.acceptedContentHash &&
    memo.content_hash &&
    input.acceptedContentHash !== memo.content_hash
  ) {
    return { executed: false, skipped: "content_hash_mismatch" };
  }
  const revision = input.acceptedRevision ?? currentRevision;
  const shadow = input.forceShadow ?? agentDataPlaneMode() === "shadow";
  const skill = await getActiveSkill("memo-understand");
  const started = await startRun({
    userId: memo.user_id,
    skill,
    triggerType: "memo.synced",
    triggerRef: memo.id,
    triggerSnapshot: {
      memo_id: memo.id,
      accepted_revision: revision,
      content_hash: memo.content_hash,
      deleted: Boolean(memo.deleted_at),
    },
    memoId: memo.id,
    memoRevision: revision,
    agentId: input.agentId,
    shadow,
    explicitRetry: input.explicitRetry,
  });
  if (!started.shouldExecute) return { run: started.run, executed: false };
  const run = started.run;
  const receipts: StepReceipt[] = [];

  if (!shadow) {
    await db
      .update(memos)
      .set({ compile_status: "running", compile_step: "understand", compile_error: null })
      .where(and(eq(memos.id, memo.id), eq(memos.user_id, memo.user_id)));
  }
  await markRunRunning(run.id);

  try {
    if (memo.deleted_at || !memo.body.trim()) {
      await completeRun(run.id, memo.deleted_at ? "Memo was deleted; no intelligence generated." : "Empty memo; no intelligence generated.");
      if (!shadow) {
        await db.update(memos).set({ compile_status: "done", compile_step: "understood" }).where(eq(memos.id, memo.id));
      }
      return { run: { ...run, status: "completed" }, executed: true };
    }

    const recalled = await runAuditedStep({
      runId: run.id,
      ordinal: 0,
      stepKey: "recall",
      toolKey: "daypage.search",
      stepInput: { user_id: memo.user_id, top_k: MAX_CANDIDATE_PAGES },
      execute: async () => {
        const candidates = await db
          .select({
            id: pages.id,
            slug: pages.slug,
            title: pages.title,
            body_md: pages.body_md,
            version: pages.version,
          })
          .from(pages)
          .where(and(eq(pages.user_id, memo.user_id), ne(pages.status, "archived")))
          .orderBy(desc(pages.updated_at))
          .limit(MAX_CANDIDATE_PAGES);
        return { value: candidates };
      },
    });
    receipts.push(recalled.receipt);

    const agentSnapshot = run.agent_snapshot as Record<string, unknown>;
    const budget = readBudget(agentSnapshot.budgetPolicy);
    const prompt = buildMemoProcessingPrompt(memo.id, memo.body, recalled.value);
    const inferred = await runAuditedStep({
      runId: run.id,
      ordinal: 1,
      stepKey: "understand",
      stepInput: { memo_id: memo.id, revision, prompt_hash_only: true },
      execute: async () => {
        const response = await runMemoProcessingModel({
          provider,
          prompt,
          model: readModel(agentSnapshot.modelPolicy),
          maxOutputTokens: budget.maxOutputTokens,
          timeoutSeconds: budget.timeoutSeconds,
        });
        assertSourceRefsWithinMemo(response.result, memo.id, memo.body.length);
        assertContextDecisionWithinCandidates(
          response.result,
          recalled.value.map((candidate) => candidate.id),
        );
        return {
          value: response.result,
          tokensIn: response.tokensIn,
          tokensOut: response.tokensOut,
          details: { model: response.model },
        };
      },
    });
    receipts.push(inferred.receipt);

    const fullMemoRef = { memo_id: memo.id, start: 0, end: memo.body.length };
    const sidecarArtifacts = [
      {
        kind: "processing_decision",
        schema_version: 1,
        logical_key: "processing-decision",
        payload: {
          intent: inferred.value.intent,
          response_policy: inferred.value.response_policy,
          context_decision: inferred.value.context_decision,
        },
        source_refs: [fullMemoRef],
      },
      ...(inferred.value.response
        ? [
            {
              kind: "agent_response",
              schema_version: 1,
              logical_key: "agent-response",
              payload: {
                mode: inferred.value.response_policy.mode,
                claims: inferred.value.response.claims,
                suggested_followups: inferred.value.response.suggested_followups,
              },
              body_md: inferred.value.response.body_md,
              source_refs: [fullMemoRef],
            },
          ]
        : []),
      ...inferred.value.proposed_memory_updates.map((proposal, index) => ({
        kind: "memory_proposal",
        schema_version: 1,
        logical_key: `memory-proposal:${index}`,
        payload: proposal,
        source_refs: proposal.source_refs,
      })),
    ];
    const understanding = MemoUnderstandingSchema.parse({
      ...inferred.value,
      artifacts: [
        ...inferred.value.artifacts,
        ...sidecarArtifacts,
        ...(inferred.value.artifacts.some((artifact) => artifact.kind === "daily_contribution")
          ? []
          : [
              {
                kind: "daily_contribution",
                schema_version: 1,
                payload: { headline: inferred.value.summary, details: memo.body.slice(0, 2_000), open_loops: [] },
                source_refs: [fullMemoRef],
              },
            ]),
      ],
    });
    const timezone = await readUserTimezone(memo.user_id);
    const date = localDate(memo.created_at, timezone);

    const persisted = await runAuditedStep({
      runId: run.id,
      ordinal: 2,
      stepKey: "persist-artifacts",
      toolKey: "daypage.write_artifact",
      stepInput: understanding,
      execute: async () => ({
        value: await persistMemoArtifacts({
          userId: memo.user_id,
          runId: run.id,
          memoId: memo.id,
          memoRevision: revision,
          observations: understanding.observations,
          artifacts: understanding.artifacts,
          shadow,
          localDate: date,
          timezone,
        }),
      }),
    });
    receipts.push(persisted.receipt);

    let needsReview = false;
    if (!shadow) {
      const pagePatches = persisted.value.filter((artifact) => artifact.kind === "page_patch");
      const reconciled = await runAuditedStep({
        runId: run.id,
        ordinal: 3,
        stepKey: "page-reconcile",
        toolKey: "daypage.write_artifact",
        stepInput: { artifact_ids: pagePatches.map((artifact) => artifact.id) },
        execute: async () => ({
          value: await Promise.all(pagePatches.map(reconcilePagePatch)),
        }),
      });
      receipts.push(reconciled.receipt);
      needsReview = reconciled.value.some((result) => result.status === "needs_review");

      const proposals = await runAuditedStep({
        runId: run.id,
        ordinal: 4,
        stepKey: "propose-actions",
        stepInput: understanding.proposed_actions,
        execute: async () => ({
          value: await createActionProposals({
            userId: memo.user_id,
            runId: run.id,
            agentId: input.agentId,
            actions: understanding.proposed_actions,
          }),
        }),
      });
      receipts.push(proposals.receipt);
      const archived = await archiveMemoArtifactsExcept({
        userId: memo.user_id,
        memoId: memo.id,
        keepArtifactIds: persisted.value.map((artifact) => artifact.id),
      });
      needsReview ||= archived.needsReview;
    }

    await emitAutomationEvent({
      userId: memo.user_id,
      event: "artifact.daily_contribution.changed",
      payload: { local_date: date, timezone, shadow },
    });

    await completeRun(run.id, understanding.summary, needsReview ? "needs_review" : "completed");
    await persistProductionEvaluations({
      userId: memo.user_id,
      runId: run.id,
      output: understanding,
      memoId: memo.id,
      memoLength: memo.body.length,
    }).catch((evaluationError) => {
      console.error(`[evaluation] failed to persist deterministic scores for Run ${run.id}`, evaluationError);
    });
    if (!shadow) {
      await db
        .update(memos)
        .set({
          compile_status: needsReview ? "failed" : "done",
          compile_step: needsReview ? "needs_attention" : "understood",
          compile_error: needsReview ? "One or more page patches need review" : null,
        })
        .where(eq(memos.id, memo.id));
    }

    const envelope: AgentOutputEnvelope = {
      run_id: run.id,
      status: needsReview ? "needs_review" : "completed",
      intent: understanding.intent,
      response_policy: understanding.response_policy,
      context_decision: understanding.context_decision,
      response: understanding.response,
      summary: understanding.summary,
      observations: understanding.observations,
      artifacts: understanding.artifacts,
      proposed_actions: understanding.proposed_actions,
      proposed_memory_updates: understanding.proposed_memory_updates,
      receipts,
    };
    return { run: { ...run, status: needsReview ? "needs_review" : "completed" }, executed: true, envelope };
  } catch (error) {
    await rollbackRunArtifacts(run.id);
    await failRun(run.id, error);
    if (!shadow) {
      await db
        .update(memos)
        .set({ compile_status: "failed", compile_step: "needs_attention", compile_error: String(error).slice(0, 4_000) })
        .where(eq(memos.id, memo.id));
    }
    throw error;
  }
}
