import { NextResponse } from "next/server";
import { and, eq } from "drizzle-orm";
import { z } from "zod";
import { currentApiUserId } from "@/lib/auth/api-user";
import { db } from "@/lib/db/client";
import { agents, automations, skill_versions } from "@/lib/db/schema";
import {
  AutomationTriggerSchema,
  ScheduleTriggerSchema,
  nextScheduleOccurrence,
} from "@/lib/agent-data-plane/automations";
import { normalizeTimeZone } from "@/lib/agent-data-plane/time";
import { ensureBuiltInRegistry } from "@/lib/agent-data-plane/registry";

type Context = { params: Promise<{ id: string }> };

const PatchSchema = z
  .object({
    name: z.string().min(1).max(120).optional(),
    trigger: AutomationTriggerSchema.optional(),
    timezone: z.string().min(1).max(100).optional(),
    agent_id: z.string().uuid().nullable().optional(),
    skill: z.object({ key: z.string(), version: z.string() }).optional(),
    input_selector: z.record(z.string(), z.unknown()).optional(),
    coalesce_policy: z.record(z.string(), z.unknown()).optional(),
    enabled: z.boolean().optional(),
  })
  .strict();

export async function PATCH(request: Request, context: Context) {
  const userId = await currentApiUserId();
  if (!userId) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  const { id } = await context.params;
  const parsed = PatchSchema.safeParse(await request.json().catch(() => null));
  if (!parsed.success) {
    return NextResponse.json({ error: "Invalid automation update", details: parsed.error.flatten() }, { status: 400 });
  }
  const [current] = await db
    .select()
    .from(automations)
    .where(and(eq(automations.id, id), eq(automations.user_id, userId)))
    .limit(1);
  if (!current) return NextResponse.json({ error: "Automation not found" }, { status: 404 });

  const timezone = parsed.data.timezone ?? current.timezone;
  if (normalizeTimeZone(timezone) !== timezone) {
    return NextResponse.json({ error: "Invalid IANA timezone" }, { status: 400 });
  }
  const trigger = AutomationTriggerSchema.parse(parsed.data.trigger ?? current.trigger);
  let skillVersionId = current.skill_version_id;
  let skillKey: string;
  await ensureBuiltInRegistry();
  if (parsed.data.skill) {
    const [skill] = await db
      .select({ id: skill_versions.id, key: skill_versions.key })
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
    skillVersionId = skill.id;
    skillKey = skill.key;
  } else {
    const [resolved] = await db
      .select({ key: skill_versions.key })
      .from(skill_versions)
      .where(eq(skill_versions.id, current.skill_version_id))
      .limit(1);
    if (!resolved) return NextResponse.json({ error: "Automation Skill is missing" }, { status: 409 });
    skillKey = resolved.key;
  }
  if (trigger.type === "schedule" && !["daily-synthesize", "weekly-review"].includes(skillKey)) {
    return NextResponse.json({ error: "Scheduled automations support Daily and Weekly reducers only" }, { status: 400 });
  }
  if (trigger.type === "event" && skillKey !== "daily-synthesize") {
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
    trigger.type === "schedule"
      ? nextScheduleOccurrence(ScheduleTriggerSchema.parse(trigger), timezone, new Date())
      : null;
  const [updated] = await db
    .update(automations)
    .set({
      name: parsed.data.name?.trim() ?? current.name,
      trigger_type: trigger.type,
      trigger,
      timezone,
      agent_id: parsed.data.agent_id === undefined ? current.agent_id : parsed.data.agent_id,
      skill_version_id: skillVersionId,
      input_selector: parsed.data.input_selector ?? current.input_selector,
      coalesce_policy: parsed.data.coalesce_policy ?? current.coalesce_policy,
      enabled: parsed.data.enabled ?? current.enabled,
      next_due_at: nextDueAt,
      updated_at: new Date(),
    })
    .where(and(eq(automations.id, id), eq(automations.user_id, userId)))
    .returning();
  return NextResponse.json(updated);
}
