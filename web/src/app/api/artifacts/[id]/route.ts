import { NextResponse } from "next/server";
import { and, eq } from "drizzle-orm";
import { currentApiUserId } from "@/lib/auth/api-user";
import { db } from "@/lib/db/client";
import { agent_artifacts, artifact_sources } from "@/lib/db/schema";

type Context = { params: Promise<{ id: string }> };

export async function GET(_request: Request, context: Context) {
  const userId = await currentApiUserId();
  if (!userId) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  const { id } = await context.params;
  const [artifact] = await db
    .select()
    .from(agent_artifacts)
    .where(and(eq(agent_artifacts.id, id), eq(agent_artifacts.user_id, userId)))
    .limit(1);
  if (!artifact) return NextResponse.json({ error: "Artifact not found" }, { status: 404 });
  const sources = await db
    .select()
    .from(artifact_sources)
    .where(eq(artifact_sources.artifact_id, artifact.id));
  return NextResponse.json({ artifact, sources });
}
