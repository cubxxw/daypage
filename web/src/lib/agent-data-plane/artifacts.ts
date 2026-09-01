import "server-only";
import { and, desc, eq, inArray, sql } from "drizzle-orm";
import { db } from "@/lib/db/client";
import {
  agent_artifacts,
  artifact_sources,
  change_log,
  pages,
  user_settings,
  work_orders,
  type AgentArtifact,
} from "@/lib/db/schema";
import type { ArtifactDraft, Observation, SourceRef } from "./contracts";
import { hashJson } from "./hash";
import { normalizeTimeZone } from "./time";
import { retractPagePatchArtifact } from "./page-reconcile";

export async function readUserTimezone(userId: string): Promise<string> {
  const [row] = await db
    .select({ settings: user_settings.settings })
    .from(user_settings)
    .where(eq(user_settings.user_id, userId))
    .limit(1);
  const settings = (row?.settings ?? {}) as Record<string, unknown>;
  const capture = settings.capture as Record<string, unknown> | undefined;
  return normalizeTimeZone(
    settings.timezone ?? settings.preferred_timezone ?? capture?.timezone,
  );
}

export interface ArtifactRevisionInput {
  userId: string;
  runId: string;
  kind: string;
  logicalKey: string;
  payload: Record<string, unknown>;
  bodyMd?: string | null;
  sourceRefs: SourceRef[];
  status?: "draft" | "live" | "needs_review";
  localDate?: string;
  timezone?: string;
  perspectiveKey?: string;
  finalizedAt?: Date | null;
}

export async function createArtifactRevision(
  input: ArtifactRevisionInput,
): Promise<{ artifact: AgentArtifact; created: boolean }> {
  const perspectiveKey = input.perspectiveKey ?? "canonical";
  const sourceSetHash = hashJson(
    input.sourceRefs
      .map((ref) => ({ memo_id: ref.memo_id, start: ref.start, end: ref.end }))
      .sort((a, b) => `${a.memo_id}:${a.start}`.localeCompare(`${b.memo_id}:${b.start}`)),
  );
  const contentHash = hashJson({
    kind: input.kind,
    payload: input.payload,
    bodyMd: input.bodyMd ?? null,
    sourceSetHash,
    status: input.status ?? "live",
    finalizedAt: input.finalizedAt?.toISOString() ?? null,
  });

  const result = await db.transaction(async (tx) => {
    const lockKey = `${input.userId}:${input.logicalKey}:${perspectiveKey}`;
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${lockKey}, 1618))`);
    const [latest] = await tx
      .select()
      .from(agent_artifacts)
      .where(
        and(
          eq(agent_artifacts.user_id, input.userId),
          eq(agent_artifacts.logical_key, input.logicalKey),
          eq(agent_artifacts.perspective_key, perspectiveKey),
        ),
      )
      .orderBy(desc(agent_artifacts.revision))
      .limit(1)
      .for("update");

    const latestContentHash = latest
      ? hashJson({
          kind: latest.kind,
          payload: latest.payload,
          bodyMd: latest.body_md,
          sourceSetHash: latest.source_set_hash,
          status: latest.status,
          finalizedAt: latest.finalized_at?.toISOString() ?? null,
        })
      : null;
    if (latest && latestContentHash === contentHash) {
      return { artifact: latest, created: false };
    }

    if (latest && latest.status !== "archived") {
      await tx
        .update(agent_artifacts)
        .set({ status: "superseded", updated_at: new Date() })
        .where(eq(agent_artifacts.id, latest.id));
    }

    const [artifact] = await tx
      .insert(agent_artifacts)
      .values({
        user_id: input.userId,
        run_id: input.runId,
        kind: input.kind,
        schema_version: 1,
        logical_key: input.logicalKey,
        payload: input.payload,
        body_md: input.bodyMd ?? null,
        status: input.status ?? "live",
        revision: (latest?.revision ?? 0) + 1,
        source_set_hash: sourceSetHash,
        local_date: input.localDate ?? null,
        timezone: input.timezone ?? null,
        perspective_key: perspectiveKey,
        supersedes_id: latest?.id ?? null,
        finalized_at: input.finalizedAt ?? null,
      })
      .returning();
    if (!artifact) throw new Error("Failed to create Agent Artifact revision");
    return { artifact, created: true };
  });

  if (result.created) {
    for (const ref of input.sourceRefs) {
      await db
        .insert(artifact_sources)
        .values({
          artifact_id: result.artifact.id,
          memo_id: ref.memo_id,
          span_start: ref.start,
          span_end: ref.end,
          provenance: "direct",
        })
        .onConflictDoNothing();
    }
  }
  return result;
}

export async function persistMemoArtifacts(input: {
  userId: string;
  runId: string;
  memoId: string;
  memoRevision: number;
  observations: Observation[];
  artifacts: ArtifactDraft[];
  shadow: boolean;
  localDate?: string;
  timezone?: string;
}): Promise<AgentArtifact[]> {
  const perspectiveKey = input.shadow ? `shadow:${input.runId}` : "canonical";
  const persisted: AgentArtifact[] = [];

  for (const observation of input.observations) {
    const logicalKey = `observation:${input.memoId}:${input.memoRevision}:${hashJson(observation)}`;
    const result = await createArtifactRevision({
      userId: input.userId,
      runId: input.runId,
      kind: "observation",
      logicalKey,
      payload: observation as unknown as Record<string, unknown>,
      sourceRefs: observation.source_refs,
      status: input.shadow ? "draft" : "live",
      perspectiveKey,
    });
    persisted.push(result.artifact);
  }

  for (const draft of input.artifacts) {
    const logicalKey =
      (draft.logical_key
        ? `${draft.kind}:${input.memoId}:${input.memoRevision}:${draft.logical_key}`
        : null) ??
      `${draft.kind}:${input.memoId}:${input.memoRevision}:${hashJson(draft.payload)}`;
    const result = await createArtifactRevision({
      userId: input.userId,
      runId: input.runId,
      kind: draft.kind,
      logicalKey,
      payload: draft.payload,
      bodyMd: draft.body_md,
      sourceRefs: draft.source_refs,
      status: input.shadow || draft.kind === "memory_proposal" ? "draft" : "live",
      perspectiveKey,
      localDate: draft.kind === "daily_contribution" ? input.localDate : undefined,
      timezone: draft.kind === "daily_contribution" ? input.timezone : undefined,
    });
    persisted.push(result.artifact);
  }
  return persisted;
}

export async function currentArtifactsByKind(
  userId: string,
  kinds: string[],
): Promise<AgentArtifact[]> {
  if (kinds.length === 0) return [];
  return db
    .select()
    .from(agent_artifacts)
    .where(
      and(
        eq(agent_artifacts.user_id, userId),
        inArray(agent_artifacts.kind, kinds),
        inArray(agent_artifacts.status, ["draft", "live", "needs_review"]),
        eq(agent_artifacts.perspective_key, "canonical"),
      ),
    );
}

/** Archive canonical outputs from older accepted revisions of one memo only
 * after the replacement run has completed all persistence/reconcile steps. */
export async function archiveMemoArtifactsExcept(input: {
  userId: string;
  memoId: string;
  keepArtifactIds: string[];
}): Promise<{ needsReview: boolean }> {
  const sourced = await db
    .select({ artifact: agent_artifacts })
    .from(artifact_sources)
    .innerJoin(agent_artifacts, eq(artifact_sources.artifact_id, agent_artifacts.id))
    .where(
      and(
        eq(artifact_sources.memo_id, input.memoId),
        eq(agent_artifacts.user_id, input.userId),
        eq(agent_artifacts.perspective_key, "canonical"),
        inArray(agent_artifacts.kind, [
          "observation",
          "daily_contribution",
          "page_patch",
          "processing_decision",
          "agent_response",
          "memory_proposal",
        ]),
        inArray(agent_artifacts.status, ["live", "needs_review"]),
      ),
    );
  const stale = Array.from(
    new Map(sourced.map((row) => [row.artifact.id, row.artifact])).values(),
  ).filter((artifact) => !input.keepArtifactIds.includes(artifact.id));
  if (stale.length === 0) return { needsReview: false };

  const safeToArchive: string[] = [];
  let needsReview = false;
  for (const artifact of stale) {
    if (artifact.kind !== "page_patch") {
      safeToArchive.push(artifact.id);
      continue;
    }
    const retracted = await retractPagePatchArtifact(artifact);
    if (retracted.status === "needs_review") {
      needsReview = true;
      await db
        .update(agent_artifacts)
        .set({
          status: "needs_review",
          payload: sql`${agent_artifacts.payload} || ${JSON.stringify({ review_reason: "superseded page contribution was edited and could not be safely retracted" })}::jsonb`,
          updated_at: new Date(),
        })
        .where(eq(agent_artifacts.id, artifact.id));
    } else {
      safeToArchive.push(artifact.id);
    }
  }
  if (safeToArchive.length === 0) return { needsReview };
  await db
    .update(agent_artifacts)
    .set({ status: "archived", updated_at: new Date() })
    .where(inArray(agent_artifacts.id, safeToArchive));
  return { needsReview };
}

/**
 * Compensates artifact publication when a Run fails after creating a revision.
 * External/page side effects retain their own receipts/markers, but failed Run
 * artifacts cannot remain in reducer inputs and a superseded last-known-good
 * revision is restored.
 */
export async function rollbackRunArtifacts(runId: string): Promise<void> {
  const created = await db
    .select()
    .from(agent_artifacts)
    .where(eq(agent_artifacts.run_id, runId));
  if (created.length === 0) return;

  const blocked = new Set<string>();
  for (const artifact of created) {
    if (artifact.perspective_key !== "canonical") continue;
    if (artifact.kind === "page_patch") {
      const retracted = await retractPagePatchArtifact(artifact);
      if (retracted.status === "needs_review") blocked.add(artifact.id);
    } else if (artifact.kind === "daily_page" || artifact.kind === "weekly_review") {
      if (!(await rollbackReducerPage(artifact))) blocked.add(artifact.id);
    }
  }

  const archivable = created.filter((artifact) => !blocked.has(artifact.id));
  await db.transaction(async (tx) => {
    if (archivable.length) {
      await tx
        .update(agent_artifacts)
        .set({ status: "archived", updated_at: new Date() })
        .where(inArray(agent_artifacts.id, archivable.map((artifact) => artifact.id)));
    }
    if (blocked.size) {
      await tx
        .update(agent_artifacts)
        .set({
          status: "needs_review",
          payload: sql`${agent_artifacts.payload} || ${JSON.stringify({ review_reason: "failed Run side effect could not be safely compensated after a concurrent edit" })}::jsonb`,
          updated_at: new Date(),
        })
        .where(inArray(agent_artifacts.id, [...blocked]));
    }
    for (const artifact of archivable) {
      if (!artifact.supersedes_id) continue;
      await tx
        .update(agent_artifacts)
        .set({
          status:
            artifact.perspective_key !== "canonical"
              ? "draft"
              : artifact.kind === "action_plan"
                ? "needs_review"
                : "live",
          updated_at: new Date(),
        })
        .where(
          and(
            eq(agent_artifacts.id, artifact.supersedes_id),
            eq(agent_artifacts.status, "superseded"),
          ),
        );
    }
    await tx
      .update(work_orders)
      .set({
        status: "rejected",
        rejected_at: new Date(),
        rejection_reason: "Originating Agent Run failed before publication completed",
        updated_at: new Date(),
      })
      .where(
        and(
          eq(work_orders.run_id, runId),
          inArray(work_orders.status, ["pending", "gated"]),
        ),
      );
  });
}

async function rollbackReducerPage(artifact: AgentArtifact): Promise<boolean> {
  if (!artifact.local_date) return true;
  const slug = artifact.kind === "daily_page"
    ? `daily/${artifact.local_date}`
    : `weekly/${artifact.local_date}`;
  const [current] = await db
    .select()
    .from(pages)
    .where(and(eq(pages.user_id, artifact.user_id), eq(pages.slug, slug)))
    .limit(1);
  if (!current) return true;
  const metadata = (current.metadata ?? {}) as Record<string, unknown>;
  if (metadata.canonical_artifact_id !== artifact.id) return true;

  const [previous] = artifact.supersedes_id
    ? await db
        .select()
        .from(agent_artifacts)
        .where(
          and(
            eq(agent_artifacts.id, artifact.supersedes_id),
            eq(agent_artifacts.user_id, artifact.user_id),
          ),
        )
        .limit(1)
    : [];
  const previousPayload = (previous?.payload ?? {}) as Record<string, unknown>;
  const previousTitle = typeof previousPayload.title === "string" ? previousPayload.title : current.title;
  const nextMetadata = previous
    ? { ...metadata, canonical_artifact_id: previous.id }
    : { ...metadata, canonical_artifact_id: null };
  const [updated] = await db
    .update(pages)
    .set({
      title: previousTitle,
      body_md: previous ? `<!-- daypage-artifact:${previous.id} -->\n\n${previous.body_md ?? ""}` : current.body_md,
      status: previous ? "live" : "archived",
      metadata: nextMetadata,
      version: sql`${pages.version} + 1`,
      updated_at: new Date(),
    })
    .where(
      and(
        eq(pages.id, current.id),
        eq(pages.user_id, artifact.user_id),
        eq(pages.version, current.version),
      ),
    )
    .returning();
  if (!updated) return false;
  await db.insert(change_log).values({
    user_id: artifact.user_id,
    action_kind: "compensate_failed_agent_page",
    target_type: "page",
    target_id: current.id,
    before: {
      version: current.version,
      artifact_id: artifact.id,
      status: current.status,
    },
    after: {
      version: updated.version,
      artifact_id: previous?.id ?? null,
      status: updated.status,
    },
    reason: "Agent Run failed after reducer page materialization",
    performed_by: "agent",
    agent_action_id: artifact.run_id,
  });
  return true;
}
