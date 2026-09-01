import { NextResponse } from "next/server";
import { and, desc, eq } from "drizzle-orm";
import { currentApiUserId } from "@/lib/auth/api-user";
import { db } from "@/lib/db/client";
import { agent_runs, memos } from "@/lib/db/schema";

type Context = { params: Promise<{ id: string }> };

export async function GET(_request: Request, context: Context) {
  const userId = await currentApiUserId();
  if (!userId) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  const { id } = await context.params;
  const [memo] = await db
    .select({ id: memos.id })
    .from(memos)
    .where(and(eq(memos.id, id), eq(memos.user_id, userId)))
    .limit(1);
  if (!memo) return NextResponse.json({ error: "Memo not found" }, { status: 404 });
  const runs = await db
    .select()
    .from(agent_runs)
    .where(and(eq(agent_runs.user_id, userId), eq(agent_runs.memo_id, id)))
    .orderBy(desc(agent_runs.created_at));
  return NextResponse.json({ items: runs });
}
