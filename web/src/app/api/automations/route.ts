import { NextResponse } from "next/server";
import { and, desc, eq } from "drizzle-orm";
import { z } from "zod";
import { currentApiUserId } from "@/lib/auth/api-user";
import { db } from "@/lib/db/client";
import { agents, automations, skill_versions } from "@/lib/db/schema";
import {
  AutomationTriggerSchema,
  ScheduleTriggerSchema,
  ensureDefaultAutomations,
  nextScheduleOccurrence,
} from "@/lib/agent-data-plane/automations";
import { normalizeTimeZone } from "@/lib/agent-data-plane/time";
import { ensureBuiltInRegistry } from "@/lib/agent-data-plane/registry";

const CreateSchema = z.object({
  name: z.string().min(1).max(120),
  trigger: AutomationTriggerSchema,
  timezone: z.string().min(1).max(100),
  agent_id: z.string().uuid().nullable().optional(),
  skill: z.object({ key: z.string().min(1).max(100), version: z.string().min(1).max(50) }),
  input_selector: z.record(z.string(), z.unknown()).optional(),
  coalesce_policy: z
    .object({
      debounceSeconds: z.number().int().min(0).max(86_400).optional(),
      lockKeyTemplate: z.string().min(1).max(500),
    })
    .optional(),
  enabled: z.boolean().optional(),
});

export async function GET() {
  const userId = await currentApiUserId();
  if (!userId) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  await ensureDefaultAutomations(userId);
  const rows = await db
    .select({ automation: automations, skill_key: skill_versions.key, skill_version: skill_versions.version })
    .from(automations)
    .innerJoin(skill_versions, eq(automations.skill_version_id, skill_versions.id))
    .where(eq(automations.user_id, userId))
    .orderBy(desc(automations.created_at));
  return NextResponse.json({
    items: rows.map((row) => ({ ...row.automation, skill: { key: row.skill_key, version: row.skill_version } })),
  });
}

export async function POST(request: Request) {
  const userId = await currentApiUserId();
  if (!userId) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  const parsed = CreateSchema.safeParse(await request.json().catch(() => null));
  if (!parsed.success) {
    return NextResponse.json({ error: "Invalid automation", details: parsed.error.flatten() }, { status: 400 });
  }
  const timezone = normalizeTimeZone(parsed.data.timezone);
  if (timezone !== parsed.data.timezone) {
    return NextResponse.json({ error: "Invalid IANA timezone" }, { status: 400 });
  }
  await ensureBuiltInRegistry();
  const [skill] = await db
    .select()
    .from(skill_versions)
    .where(
      and(
        eq(skill_versions.key, parsed.data.skill.key),
        eq(skill_versions.version, parsed.data.skill.version),
        eq(skill_versions.status, "active"),
      ),
    )
    .limit(1);
  if (!skill) return NextResponse.json({ error: "Skill version not found" }, { status: 400 });
  if (
    parsed.data.trigger.type === "schedule" &&
    !["daily-synthesize", "weekly-review"].includes(skill.key)
  ) {
    return NextResponse.json({ error: "Scheduled automations support Daily and Weekly reducers only" }, { status: 400 });
  }
  if (parsed.data.trigger.type === "event" && skill.key !== "daily-synthesize") {
    return NextResponse.json({ error: "Event automations currently support the Daily reducer only" }, { status: 400 });
  }
  if (parsed.data.agent_id) {
    const [agent] = await db
      .select({ id: agents.id })
      .from(agents)
      .where(and(eq(agents.id, parsed.data.agent_id), eq(agents.user_id, userId)))
      .limit(1);
    if (!agent) return NextResponse.json({ error: "Agent not found" }, { status: 400 });
  }
  const nextDueAt =
    parsed.data.trigger.type === "schedule"
      ? nextScheduleOccurrence(ScheduleTriggerSchema.parse(parsed.data.trigger), timezone, new Date())
      : null;
  const [created] = await db
    .insert(automations)
    .values({
      user_id: userId,
      name: parsed.data.name.trim(),
      trigger_type: parsed.data.trigger.type,
      trigger: parsed.data.trigger,
      timezone,
      agent_id: parsed.data.agent_id ?? null,
      skill_version_id: skill.id,
      input_selector: parsed.data.input_selector ?? {},
      coalesce_policy: parsed.data.coalesce_policy ?? { lockKeyTemplate: `${skill.key}:{user_id}` },
      enabled: parsed.data.enabled ?? true,
      next_due_at: nextDueAt,
    })
    .returning();
  return NextResponse.json(created, { status: 201 });
}
