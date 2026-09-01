import { NextResponse } from "next/server";
import { z } from "zod";
import { currentApiUserId } from "@/lib/auth/api-user";
import { db } from "@/lib/db/client";
import { memos } from "@/lib/db/schema";
import { and, eq } from "drizzle-orm";
import { understandMemo } from "@/lib/agent-data-plane/memo-understand";
import { synthesizeDaily } from "@/lib/agent-data-plane/daily";
import { synthesizeWeekly } from "@/lib/agent-data-plane/weekly";
import { normalizeTimeZone } from "@/lib/agent-data-plane/time";
import { createActionPlan } from "@/lib/agent-data-plane/action-plan";

export const runtime = "nodejs";

const RequestSchema = z.discriminatedUnion("skill", [
  z.object({
    skill: z.literal("memo-understand"),
    memo_id: z.string().uuid(),
    agent_id: z.string().uuid().optional(),
    retry: z.boolean().optional(),
  }),
  z.object({
    skill: z.literal("daily-synthesize"),
    local_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
    timezone: z.string().min(1).max(100),
    finalize: z.boolean().optional(),
    perspective: z.string().max(800).optional(),
    retry: z.boolean().optional(),
  }),
  z.object({
    skill: z.literal("weekly-review"),
    week_start: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
    timezone: z.string().min(1).max(100),
    agent_id: z.string().uuid().optional(),
    retry: z.boolean().optional(),
  }),
  z.object({
    skill: z.literal("action-plan"),
    intent: z.string().min(1).max(10_000),
    context: z.record(z.string(), z.unknown()).optional(),
    agent_id: z.string().uuid().optional(),
    retry: z.boolean().optional(),
  }),
]);

export async function POST(request: Request) {
  const userId = await currentApiUserId();
  if (!userId) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  const parsed = RequestSchema.safeParse(await request.json().catch(() => null));
  if (!parsed.success) {
    return NextResponse.json({ error: "Invalid Agent Run request", details: parsed.error.flatten() }, { status: 400 });
  }

  if (parsed.data.skill === "memo-understand") {
    const [memo] = await db
      .select({ id: memos.id })
      .from(memos)
      .where(and(eq(memos.id, parsed.data.memo_id), eq(memos.user_id, userId)))
      .limit(1);
    if (!memo) return NextResponse.json({ error: "Memo not found" }, { status: 404 });
    const result = await understandMemo({
      memoId: memo.id,
      userId,
      agentId: parsed.data.agent_id,
      explicitRetry: parsed.data.retry,
    });
    return NextResponse.json(result, { status: result.executed ? 201 : 200 });
  }
  if (parsed.data.skill === "daily-synthesize") {
    const timezone = normalizeTimeZone(parsed.data.timezone);
    if (timezone !== parsed.data.timezone) {
      return NextResponse.json({ error: "Invalid IANA timezone" }, { status: 400 });
    }
    const result = await synthesizeDaily({
      userId,
      localDate: parsed.data.local_date,
      timezone,
      finalize: parsed.data.finalize,
      perspectiveKey: parsed.data.perspective ? `manual:${crypto.randomUUID()}` : undefined,
      perspectivePrompt: parsed.data.perspective,
      explicitRetry: parsed.data.retry,
    });
    return NextResponse.json(result, { status: 201 });
  }
  if (parsed.data.skill === "weekly-review") {
    const timezone = normalizeTimeZone(parsed.data.timezone);
    if (timezone !== parsed.data.timezone) {
      return NextResponse.json({ error: "Invalid IANA timezone" }, { status: 400 });
    }
    const result = await synthesizeWeekly({
      userId,
      weekStart: parsed.data.week_start,
      timezone,
      agentId: parsed.data.agent_id,
      explicitRetry: parsed.data.retry,
    });
    return NextResponse.json(result, { status: 201 });
  }
  const result = await createActionPlan({
    userId,
    intent: parsed.data.intent,
    context: parsed.data.context,
    agentId: parsed.data.agent_id,
    explicitRetry: parsed.data.retry,
  });
  return NextResponse.json(result, { status: result.status === "idempotent" ? 200 : 201 });
}
