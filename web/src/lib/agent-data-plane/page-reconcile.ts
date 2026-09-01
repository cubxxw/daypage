import "server-only";
import { and, eq, sql } from "drizzle-orm";
import { db } from "@/lib/db/client";
import {
  agent_artifacts,
  artifact_sources,
  change_log,
  page_sources,
  pages,
  type AgentArtifact,
} from "@/lib/db/schema";

const MAX_PATCH_ATTEMPTS = 3;

type PagePatchPayload = {
  page_id?: string;
  slug?: string;
  type?: "concept" | "source" | "entity" | "synthesis" | "daily";
  title?: string;
  body_md?: string;
  contribution_md?: string;
  expected_version?: number;
  rationale?: string;
};

export interface ReconcileResult {
  status: "applied" | "idempotent" | "needs_review" | "skipped";
  pageId?: string;
  version?: number;
  attempts: number;
}

export function marker(artifactId: string): string {
  return `<!-- daypage-artifact:${artifactId} -->`;
}

export function endMarker(artifactId: string): string {
  return `<!-- /daypage-artifact:${artifactId} -->`;
}

export function artifactBlock(artifactId: string, contribution: string): string {
  return `${marker(artifactId)}\n\n${contribution.trim()}\n\n${endMarker(artifactId)}`;
}

export function removeArtifactBlock(
  body: string | null,
  artifactId: string,
  legacyContribution: string,
): { body: string; found: boolean; removed: boolean } {
  const current = body ?? "";
  const startMarker = marker(artifactId);
  const start = current.indexOf(startMarker);
  if (start < 0) return { body: current, found: false, removed: true };

  const boundedEndMarker = endMarker(artifactId);
  const boundedEnd = current.indexOf(boundedEndMarker, start + startMarker.length);
  if (boundedEnd >= 0) {
    const next = `${current.slice(0, start).trimEnd()}\n\n${current
      .slice(boundedEnd + boundedEndMarker.length)
      .trimStart()}`.trim();
    return { body: next, found: true, removed: true };
  }

  // Artifacts created before bounded markers used an exact start-marker + body
  // block. Only retract that exact text; an edited block requires human review.
  const legacyBlock = `${startMarker}\n\n${legacyContribution.trim()}`;
  if (!legacyContribution.trim() || !current.includes(legacyBlock)) {
    return { body: current, found: true, removed: false };
  }
  return {
    body: current.replace(legacyBlock, "").replace(/\n{3,}/g, "\n\n").trim(),
    found: true,
    removed: true,
  };
}

export function mergeAfterConflict(currentBody: string | null, patch: PagePatchPayload, artifactId: string): string {
  const contribution = (patch.contribution_md ?? patch.body_md ?? "").trim();
  if (!contribution) return currentBody ?? "";
  return [currentBody?.trim(), artifactBlock(artifactId, contribution)].filter(Boolean).join("\n\n");
}

export function applyPagePatchBody(
  currentBody: string | null,
  patch: PagePatchPayload,
  artifactId: string,
  conflictSeen: boolean,
): string {
  const contribution = patch.contribution_md?.trim();
  if (contribution) {
    return [currentBody?.trim(), artifactBlock(artifactId, contribution)].filter(Boolean).join("\n\n");
  }
  const replacement = patch.body_md?.trim();
  if (!replacement) return currentBody ?? "";
  if (conflictSeen) return mergeAfterConflict(currentBody, patch, artifactId);
  return artifactBlock(artifactId, replacement);
}

export async function reconcilePagePatch(
  artifact: AgentArtifact,
): Promise<ReconcileResult> {
  if (artifact.kind !== "page_patch") return { status: "skipped", attempts: 0 };
  const patch = artifact.payload as PagePatchPayload;
  if (!patch.page_id && !patch.slug) {
    await markNeedsReview(artifact.id, "page_patch requires page_id or slug");
    return { status: "needs_review", attempts: 0 };
  }

  const memoSources = await db
    .select({ memo_id: artifact_sources.memo_id })
    .from(artifact_sources)
    .where(eq(artifact_sources.artifact_id, artifact.id));
  const memoIds = memoSources.flatMap((source) => (source.memo_id ? [source.memo_id] : []));

  if (!patch.page_id && patch.slug) {
    const [created] = await db
      .insert(pages)
      .values({
        user_id: artifact.user_id,
        slug: patch.slug,
        type: patch.type ?? "concept",
        title: patch.title?.trim() || patch.slug,
        status: "draft",
        body_md: artifactBlock(artifact.id, patch.body_md ?? patch.contribution_md ?? ""),
        version: 1,
        source_count: memoIds.length,
        last_compiled_at: new Date(),
      })
      .onConflictDoNothing({ target: [pages.user_id, pages.slug] })
      .returning();
    if (created) {
      await linkMemoSources(created.id, memoIds);
      await writeChangeLog(artifact, created.id, null, {
        title: created.title,
        body_md: created.body_md,
        version: created.version,
      });
      await markArtifactLive(artifact.id, created.id, created.version);
      return { status: "applied", pageId: created.id, version: created.version, attempts: 1 };
    }
  }

  let expectedVersion = patch.expected_version;
  let conflictSeen = false;
  for (let attempt = 1; attempt <= MAX_PATCH_ATTEMPTS; attempt += 1) {
    const [current] = await db
      .select()
      .from(pages)
      .where(
        patch.page_id
          ? and(eq(pages.id, patch.page_id), eq(pages.user_id, artifact.user_id))
          : and(eq(pages.slug, patch.slug!), eq(pages.user_id, artifact.user_id)),
      )
      .limit(1);
    if (!current) {
      await markNeedsReview(artifact.id, "target page was not found");
      return { status: "needs_review", attempts: attempt };
    }
    if (current.body_md?.includes(marker(artifact.id))) {
      await markArtifactLive(artifact.id, current.id, current.version);
      return { status: "idempotent", pageId: current.id, version: current.version, attempts: attempt };
    }

    const targetVersion = expectedVersion ?? current.version;
    const body = applyPagePatchBody(current.body_md, patch, artifact.id, conflictSeen);
    const [updated] = await db
      .update(pages)
      .set({
        title: patch.title?.trim() || current.title,
        body_md: body,
        version: sql`${pages.version} + 1`,
        last_compiled_at: new Date(),
        updated_at: new Date(),
      })
      .where(
        and(
          eq(pages.id, current.id),
          eq(pages.user_id, artifact.user_id),
          eq(pages.version, targetVersion),
        ),
      )
      .returning();

    if (updated) {
      await linkMemoSources(updated.id, memoIds);
      await writeChangeLog(artifact, updated.id, current, {
        title: updated.title,
        body_md: updated.body_md,
        version: updated.version,
      });
      await markArtifactLive(artifact.id, updated.id, updated.version);
      return { status: "applied", pageId: updated.id, version: updated.version, attempts: attempt };
    }

    conflictSeen = true;
    expectedVersion = undefined;
  }

  await markNeedsReview(artifact.id, "page changed during all optimistic update attempts");
  return { status: "needs_review", attempts: MAX_PATCH_ATTEMPTS };
}

export async function retractPagePatchArtifact(
  artifact: AgentArtifact,
): Promise<ReconcileResult> {
  if (artifact.kind !== "page_patch") return { status: "skipped", attempts: 0 };
  const patch = artifact.payload as PagePatchPayload & { applied_page_id?: string };
  if (!patch.applied_page_id) return { status: "skipped", attempts: 0 };
  const contribution = (patch.contribution_md ?? patch.body_md ?? "").trim();

  for (let attempt = 1; attempt <= MAX_PATCH_ATTEMPTS; attempt += 1) {
    const [current] = await db
      .select()
      .from(pages)
      .where(and(eq(pages.id, patch.applied_page_id), eq(pages.user_id, artifact.user_id)))
      .limit(1);
    if (!current) return { status: "skipped", pageId: patch.applied_page_id, attempts: attempt };

    const removal = removeArtifactBlock(current.body_md, artifact.id, contribution);
    if (!removal.found) {
      return { status: "idempotent", pageId: current.id, version: current.version, attempts: attempt };
    }
    if (!removal.removed) {
      return { status: "needs_review", pageId: current.id, version: current.version, attempts: attempt };
    }

    const [updated] = await db
      .update(pages)
      .set({
        body_md: removal.body,
        version: sql`${pages.version} + 1`,
        last_compiled_at: new Date(),
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
    if (!updated) continue;

    await writeChangeLog(artifact, updated.id, current, {
      title: updated.title,
      body_md: updated.body_md,
      version: updated.version,
      retracted_artifact_id: artifact.id,
    });
    return { status: "applied", pageId: updated.id, version: updated.version, attempts: attempt };
  }

  return { status: "needs_review", pageId: patch.applied_page_id, attempts: MAX_PATCH_ATTEMPTS };
}

async function linkMemoSources(pageId: string, memoIds: string[]): Promise<void> {
  for (const memoId of memoIds) {
    await db
      .insert(page_sources)
      .values({ page_id: pageId, memo_id: memoId, contribution: "agent_artifact", weight: 1 })
      .onConflictDoNothing();
  }
  const [{ count }] = await db
    .select({ count: sql<number>`count(*)::int` })
    .from(page_sources)
    .where(eq(page_sources.page_id, pageId));
  await db.update(pages).set({ source_count: count ?? 0 }).where(eq(pages.id, pageId));
}

async function writeChangeLog(
  artifact: AgentArtifact,
  pageId: string,
  before: unknown,
  after: unknown,
): Promise<void> {
  await db.insert(change_log).values({
    user_id: artifact.user_id,
    action_kind: before ? "update_page" : "create_page",
    target_type: "page",
    target_id: pageId,
    before: before as Record<string, unknown> | null,
    after: after as Record<string, unknown>,
    reason: (artifact.payload as PagePatchPayload).rationale ?? "Grounded Agent Artifact reconciliation",
    performed_by: "agent",
    agent_action_id: artifact.run_id,
  });
}

async function markArtifactLive(artifactId: string, pageId: string, version: number): Promise<void> {
  await db
    .update(agent_artifacts)
    .set({
      status: "live",
      payload: sql`${agent_artifacts.payload} || ${JSON.stringify({ applied_page_id: pageId, applied_page_version: version })}::jsonb`,
      updated_at: new Date(),
    })
    .where(eq(agent_artifacts.id, artifactId));
}

async function markNeedsReview(artifactId: string, reason: string): Promise<void> {
  await db
    .update(agent_artifacts)
    .set({
      status: "needs_review",
      payload: sql`${agent_artifacts.payload} || ${JSON.stringify({ review_reason: reason })}::jsonb`,
      updated_at: new Date(),
    })
    .where(eq(agent_artifacts.id, artifactId));
}
