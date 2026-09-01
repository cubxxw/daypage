import { NextRequest, NextResponse } from "next/server";
import { and, desc, eq, inArray } from "drizzle-orm";
import { z } from "zod";
import { currentApiUserId } from "@/lib/auth/api-user";
import { db } from "@/lib/db/client";
import { agent_artifacts } from "@/lib/db/schema";

const QuerySchema = z.object({
  kind: z.string().max(100).optional(),
  local_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
  status: z.enum(["draft", "live", "superseded", "archived", "needs_review"]).optional(),
  limit: z.coerce.number().int().min(1).max(100).default(50),
});

export async function GET(request: NextRequest) {
  const userId = await currentApiUserId();
  if (!userId) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  const parsed = QuerySchema.safeParse(Object.fromEntries(request.nextUrl.searchParams.entries()));
  if (!parsed.success) return NextResponse.json({ error: "Invalid query" }, { status: 400 });
  const conditions = [eq(agent_artifacts.user_id, userId)];
  if (parsed.data.kind) conditions.push(eq(agent_artifacts.kind, parsed.data.kind));
  if (parsed.data.local_date) conditions.push(eq(agent_artifacts.local_date, parsed.data.local_date));
  if (parsed.data.status) conditions.push(eq(agent_artifacts.status, parsed.data.status));
  else conditions.push(inArray(agent_artifacts.status, ["live", "needs_review"]));
  const items = await db
    .select()
    .from(agent_artifacts)
    .where(and(...conditions))
    .orderBy(desc(agent_artifacts.created_at))
    .limit(parsed.data.limit);
  return NextResponse.json({ items });
}
