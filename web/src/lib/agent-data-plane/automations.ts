import "server-only";
import { and, asc, eq, lte, sql } from "drizzle-orm";
import { z } from "zod";
import { db } from "@/lib/db/client";
import { automations, gateway_jobs, skill_versions, type Automation } from "@/lib/db/schema";
import { readUserTimezone } from "./artifacts";
import { enqueueCoalescedDataPlaneJob } from "./jobs";
import { getActiveSkill } from "./registry";
import {
  addCalendarDays,
  isoWeekStart,
  localDate,
  normalizeTimeZone,
  zonedLocalDateTimeToUtc,
} from "./time";

const WeekdaySchema = z.enum([
  "sunday",
  "monday",
  "tuesday",
  "wednesday",
  "thursday",
  "friday",
  "saturday",
]);

export const EventTriggerSchema = z.object({
  type: z.literal("event").default("event"),
  event: z.string().min(1).max(200),
});

export const ScheduleTriggerSchema = z.object({
  type: z.literal("schedule").default("schedule"),
  local_time: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/),
  weekdays: z.array(WeekdaySchema).min(1).max(7).optional(),
});

export const ManualTriggerSchema = z.object({ type: z.literal("manual").default("manual") });
export const AutomationTriggerSchema = z.discriminatedUnion("type", [
  EventTriggerSchema,
  ScheduleTriggerSchema,
  ManualTriggerSchema,
]);

const WEEKDAYS = [
  "sunday",
  "monday",
  "tuesday",
  "wednesday",
  "thursday",
  "friday",
  "saturday",
] as const;

export function nextScheduleOccurrence(
  trigger: z.infer<typeof ScheduleTriggerSchema>,
  timezone: string,
  after: Date,
): Date {
  const zone = normalizeTimeZone(timezone);
  const today = localDate(after, zone);
  for (let offset = 0; offset <= 14; offset += 1) {
    const date = addCalendarDays(today, offset);
    const candidate = zonedLocalDateTimeToUtc(date, trigger.local_time, zone);
    const actualWeekday = WEEKDAYS[new Date(`${date}T12:00:00Z`).getUTCDay()];
    if (trigger.weekdays && !trigger.weekdays.includes(actualWeekday)) continue;
    if (candidate.getTime() > after.getTime()) return candidate;
  }
  throw new Error("Could not calculate the next automation occurrence");
}

export async function ensureDefaultAutomations(userId: string): Promise<void> {
  const timezone = await readUserTimezone(userId);
  const [dailySkill, weeklySkill] = await Promise.all([
    getActiveSkill("daily-synthesize"),
    getActiveSkill("weekly-review"),
  ]);
  const defaults = [
    {
      name: "Daily Page — living",
      trigger_type: "event" as const,
      trigger: { type: "event", event: "artifact.daily_contribution.changed" },
      skill_version_id: dailySkill.id,
      coalesce_policy: { debounceSeconds: 180, lockKeyTemplate: "daily:{user_id}:{local_date}" },
      next_due_at: null,
    },
    {
      name: "Daily Page — finalize",
      trigger_type: "schedule" as const,
      trigger: { type: "schedule", local_time: "04:00" },
      skill_version_id: dailySkill.id,
      coalesce_policy: { lockKeyTemplate: "daily:{user_id}:{local_date}" },
      next_due_at: nextScheduleOccurrence(
        { type: "schedule", local_time: "04:00" },
        timezone,
        new Date(),
      ),
    },
    {
      name: "Weekly Review — Monday",
      trigger_type: "schedule" as const,
      trigger: { type: "schedule", local_time: "09:00", weekdays: ["monday" as const] },
      skill_version_id: weeklySkill.id,
      coalesce_policy: { lockKeyTemplate: "weekly:{user_id}:{iso_week}:{timezone}" },
      next_due_at: nextScheduleOccurrence(
        { type: "schedule", local_time: "09:00", weekdays: ["monday"] },
        timezone,
        new Date(),
      ),
    },
  ];

  await db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`default-automations:${userId}`}, 577))`);
    for (const item of defaults) {
      const [existing] = await tx
        .select({ id: automations.id })
        .from(automations)
        .where(and(eq(automations.user_id, userId), eq(automations.name, item.name)))
        .limit(1);
      if (!existing) {
        await tx.insert(automations).values({
          user_id: userId,
          name: item.name,
          trigger_type: item.trigger_type,
          trigger: item.trigger,
          timezone,
          skill_version_id: item.skill_version_id,
          coalesce_policy: item.coalesce_policy,
          next_due_at: item.next_due_at,
        });
      }
    }
  });
}

export async function emitAutomationEvent(input: {
  userId: string;
  event: string;
  payload: Record<string, unknown>;
}): Promise<number> {
  await ensureDefaultAutomations(input.userId);
  const rows = await db
    .select({ automation: automations, skill_key: skill_versions.key })
    .from(automations)
    .innerJoin(skill_versions, eq(automations.skill_version_id, skill_versions.id))
    .where(
      and(
        eq(automations.user_id, input.userId),
        eq(automations.trigger_type, "event"),
        eq(automations.enabled, true),
      ),
    );
  let emitted = 0;
  for (const row of rows) {
    const trigger = EventTriggerSchema.safeParse(row.automation.trigger);
    if (!trigger.success || trigger.data.event !== input.event) continue;
    if (row.skill_key === "daily-synthesize") {
      const localDateValue = String(input.payload.local_date);
      const policy = row.automation.coalesce_policy as Record<string, unknown>;
      const debounceSeconds =
        typeof policy.debounceSeconds === "number" ? Math.max(0, policy.debounceSeconds) : 180;
      await enqueueCoalescedDataPlaneJob({
        userId: input.userId,
        type: "daily.synthesize",
        payload: {
          ...input.payload,
          automation_id: row.automation.id,
          timezone: row.automation.timezone,
        },
        coalesceKey: `daily:${input.userId}:${localDateValue}:${row.automation.timezone}:${input.payload.shadow ? "shadow" : "canonical"}`,
        availableAt: new Date(Date.now() + debounceSeconds * 1_000),
      });
      emitted += 1;
    }
  }
  return emitted;
}

export async function enqueueDueAutomations(now = new Date()): Promise<number> {
  let count = 0;
  for (;;) {
    const due = await db.transaction(async (tx) => {
      const [candidate] = await tx
        .select()
        .from(automations)
        .where(
          and(
            eq(automations.enabled, true),
            eq(automations.trigger_type, "schedule"),
            lte(automations.next_due_at, now),
          ),
        )
        .orderBy(asc(automations.next_due_at))
        .limit(1)
        .for("update", { skipLocked: true });
      if (!candidate || !candidate.next_due_at) return null;
      const parsed = ScheduleTriggerSchema.parse(candidate.trigger);
      const scheduledFor = candidate.next_due_at;
      const nextDueAt = nextScheduleOccurrence(parsed, candidate.timezone, scheduledFor);
      await tx
        .insert(gateway_jobs)
        .values({
          user_id: candidate.user_id,
          type: "automation.due",
          payload: { automation_id: candidate.id, scheduled_for: scheduledFor.toISOString() },
          idempotency_key: `automation:${candidate.id}:${scheduledFor.toISOString()}`,
        })
        .onConflictDoNothing({ target: gateway_jobs.idempotency_key });
      await tx
        .update(automations)
        .set({ next_due_at: nextDueAt, last_enqueued_at: now, updated_at: now })
        .where(eq(automations.id, candidate.id));
      return { ...candidate, next_due_at: scheduledFor };
    });
    if (!due || !due.next_due_at) break;
    count += 1;
    if (count >= 100) break;
  }
  return count;
}

export async function automationJobInput(automation: Automation, scheduledFor: Date) {
  const [skill] = await db
    .select({ key: skill_versions.key })
    .from(skill_versions)
    .where(eq(skill_versions.id, automation.skill_version_id))
    .limit(1);
  if (!skill) throw new Error("Automation skill is missing");
  const date = localDate(scheduledFor, automation.timezone);
  if (skill.key === "daily-synthesize") {
    return {
      kind: "daily" as const,
      localDate: addCalendarDays(date, -1),
      timezone: automation.timezone,
      finalize: true,
    };
  }
  if (skill.key === "weekly-review") {
    return {
      kind: "weekly" as const,
      // Monday 09:00 closes the week that ended the previous day; never
      // generate an almost-empty review for the new week that just started.
      weekStart: addCalendarDays(isoWeekStart(date), -7),
      timezone: automation.timezone,
    };
  }
  return { kind: "generic" as const };
}
