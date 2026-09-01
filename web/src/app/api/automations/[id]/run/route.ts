import { and, eq } from "drizzle-orm";
import { NextResponse } from "next/server";
import { z } from "zod";
import { currentApiUserId } from "@/lib/auth/api-user";
import { db } from "@/lib/db/client";
import { automations, memos, skill_versions } from "@/lib/db/schema";
import { createActionPlan } from "@/lib/agent-data-plane/action-plan";
import { synthesizeDaily } from "@/lib/agent-data-plane/daily";
import { understandMemo } from "@/lib/agent-data-plane/memo-understand";
import { addCalendarDays, isoWeekStart, localDate } from "@/lib/agent-data-plane/time";
import { synthesizeWeekly } from "@/lib/agent-data-plane/weekly";

type Context = { params: Promise<{ id: string }> };

const BodySchema = z
  .object({
    memo_id: z.string().uuid().optional(),
    local_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
    week_start: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
    intent: z.string().min(1).max(10_000).optional(),
    context: z.record(z.string(), z.unknown()).optional(),
    retry: z.boolean().optional(),
  })
  .strict();

export async function POST(request: Request, context: Context) {
  const userId = await currentApiUserId();
  if (!userId) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  const { id } = await context.params;
  const parsed = BodySchema.safeParse(await request.json().catch(() => ({})));
  if (!parsed.success) {
    return NextResponse.json({ error: "Invalid manual Automation input", details: parsed.error.flatten() }, { status: 400 });
  }
  const [row] = await db
    .select({ automation: automations, skillKey: skill_versions.key })
    .from(automations)
    .innerJoin(skill_versions, eq(automations.skill_version_id, skill_versions.id))
    .where(and(eq(automations.id, id), eq(automations.user_id, userId)))
    .limit(1);
  if (!row) return NextResponse.json({ error: "Automation not found" }, { status: 404 });
  if (!row.automation.enabled) {
    return NextResponse.json({ error: "Automation is disabled" }, { status: 409 });
  }

  if (row.skillKey === "memo-understand") {
    if (!parsed.data.memo_id) return NextResponse.json({ error: "memo_id is required" }, { status: 400 });
    const [memo] = await db
      .select({ id: memos.id })
      .from(memos)
      .where(and(eq(memos.id, parsed.data.memo_id), eq(memos.user_id, userId)))
      .limit(1);
    if (!memo) return NextResponse.json({ error: "Memo not found" }, { status: 404 });
    return NextResponse.json(
      await understandMemo({
        memoId: memo.id,
        userId,
        agentId: row.automation.agent_id ?? undefined,
        explicitRetry: parsed.data.retry,
      }),
      { status: 201 },
    );
  }
  if (row.skillKey === "daily-synthesize") {
    return NextResponse.json(
      await synthesizeDaily({
        userId,
        localDate: parsed.data.local_date ?? localDate(new Date(), row.automation.timezone),
        timezone: row.automation.timezone,
        agentId: row.automation.agent_id ?? undefined,
        explicitRetry: parsed.data.retry,
      }),
      { status: 201 },
    );
  }
  if (row.skillKey === "weekly-review") {
    const currentDate = localDate(new Date(), row.automation.timezone);
    return NextResponse.json(
      await synthesizeWeekly({
        userId,
        weekStart:
          parsed.data.week_start ?? addCalendarDays(isoWeekStart(currentDate), -7),
        timezone: row.automation.timezone,
        agentId: row.automation.agent_id ?? undefined,
        explicitRetry: parsed.data.retry,
      }),
      { status: 201 },
    );
  }
  if (row.skillKey === "action-plan") {
    if (!parsed.data.intent) return NextResponse.json({ error: "intent is required" }, { status: 400 });
    return NextResponse.json(
      await createActionPlan({
        userId,
        intent: parsed.data.intent,
        context: parsed.data.context,
        agentId: row.automation.agent_id ?? undefined,
        explicitRetry: parsed.data.retry,
      }),
      { status: 201 },
    );
  }
  return NextResponse.json({ error: `Skill ${row.skillKey} has no manual runner` }, { status: 409 });
}
