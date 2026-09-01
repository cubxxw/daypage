import { NextResponse } from "next/server";
import { and, asc, eq } from "drizzle-orm";
import { currentApiUserId } from "@/lib/auth/api-user";
import { db } from "@/lib/db/client";
import {
  agent_artifacts,
  agent_feedback_events,
  agent_run_steps,
  agent_runs,
  artifact_sources,
  evaluation_results,
  work_orders,
} from "@/lib/db/schema";

type Context = { params: Promise<{ id: string }> };

export async function GET(_request: Request, context: Context) {
  const userId = await currentApiUserId();
  if (!userId) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  const { id } = await context.params;
  const [run] = await db
    .select()
    .from(agent_runs)
    .where(and(eq(agent_runs.id, id), eq(agent_runs.user_id, userId)))
    .limit(1);
  if (!run) return NextResponse.json({ error: "Run not found" }, { status: 404 });

  const [steps, artifacts, proposals, feedback, evaluations] = await Promise.all([
    db.select().from(agent_run_steps).where(eq(agent_run_steps.run_id, run.id)).orderBy(asc(agent_run_steps.ordinal)),
    db.select().from(agent_artifacts).where(eq(agent_artifacts.run_id, run.id)).orderBy(asc(agent_artifacts.created_at)),
    db.select().from(work_orders).where(and(eq(work_orders.run_id, run.id), eq(work_orders.user_id, userId))),
    db
      .select()
      .from(agent_feedback_events)
      .where(and(eq(agent_feedback_events.run_id, run.id), eq(agent_feedback_events.user_id, userId)))
      .orderBy(asc(agent_feedback_events.created_at)),
    db
      .select()
      .from(evaluation_results)
      .where(and(eq(evaluation_results.run_id, run.id), eq(evaluation_results.user_id, userId)))
      .orderBy(asc(evaluation_results.created_at)),
  ]);
  // Return source rows per artifact without exposing raw memo text.
  const allSources = artifacts.length
    ? await Promise.all(
        artifacts.map((artifact) =>
          db.select().from(artifact_sources).where(eq(artifact_sources.artifact_id, artifact.id)),
        ),
      )
    : [];
  return NextResponse.json({
    run,
    steps,
    artifacts: artifacts.map((artifact, index) => ({ ...artifact, sources: allSources[index] })),
    proposed_actions: proposals,
    feedback,
    evaluations,
  });
}
