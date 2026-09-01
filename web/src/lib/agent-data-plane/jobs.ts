import "server-only";
import { randomUUID } from "node:crypto";
import { and, asc, eq, inArray, isNull, lte, or, sql } from "drizzle-orm";
import { db } from "@/lib/db/client";
import { gateway_jobs, type GatewayJob } from "@/lib/db/schema";
import { hashJson } from "./hash";

export const DATA_PLANE_JOB_TYPES = [
  "memo.synced",
  "memo.deleted",
  "daily.synthesize",
  "daily.finalize",
  "weekly.review",
  "automation.due",
] as const;

export type DataPlaneJobType = (typeof DATA_PLANE_JOB_TYPES)[number];

// A reducer includes a bounded LLM call. Keep the lease comfortably above the
// 120-second default Run budget while still allowing crash recovery.
const LEASE_MS = 10 * 60_000;
const MAX_ATTEMPTS = 5;

export async function enqueueUniqueDataPlaneJob(input: {
  userId: string;
  type: DataPlaneJobType;
  payload: Record<string, unknown>;
  idempotencyKey: string;
  availableAt?: Date;
  coalesceKey?: string;
}): Promise<GatewayJob> {
  const [inserted] = await db
    .insert(gateway_jobs)
    .values({
      user_id: input.userId,
      type: input.type,
      payload: input.payload,
      idempotency_key: input.idempotencyKey,
      available_at: input.availableAt ?? new Date(),
      coalesce_key: input.coalesceKey ?? null,
    })
    .onConflictDoNothing({ target: gateway_jobs.idempotency_key })
    .returning();
  if (inserted) return inserted;

  const [existing] = await db
    .select()
    .from(gateway_jobs)
    .where(eq(gateway_jobs.idempotency_key, input.idempotencyKey))
    .limit(1);
  if (!existing) throw new Error("Data-plane enqueue conflicted without an existing job");
  return existing;
}

export async function enqueueCoalescedDataPlaneJob(input: {
  userId: string;
  type: "daily.synthesize" | "daily.finalize" | "weekly.review";
  payload: Record<string, unknown>;
  coalesceKey: string;
  availableAt: Date;
}): Promise<GatewayJob> {
  return db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${input.coalesceKey}, 2718))`);
    const [queued] = await tx
      .select()
      .from(gateway_jobs)
      .where(
        and(
          eq(gateway_jobs.user_id, input.userId),
          eq(gateway_jobs.type, input.type),
          eq(gateway_jobs.coalesce_key, input.coalesceKey),
          inArray(gateway_jobs.status, ["queued", "running"]),
        ),
      )
      .orderBy(asc(gateway_jobs.created_at))
      .limit(1)
      .for("update");

    if (queued) {
      const [updated] = await tx
        .update(gateway_jobs)
        .set({
          payload: input.payload,
          available_at: input.availableAt,
          updated_at: new Date(),
        })
        .where(eq(gateway_jobs.id, queued.id))
        .returning();
      if (!updated) throw new Error("Failed to update coalesced data-plane job");
      return updated;
    }

    const idempotencyKey = `${input.coalesceKey}:${hashJson(input.payload)}:${randomUUID()}`;
    const [created] = await tx
      .insert(gateway_jobs)
      .values({
        user_id: input.userId,
        type: input.type,
        payload: input.payload,
        idempotency_key: idempotencyKey,
        coalesce_key: input.coalesceKey,
        available_at: input.availableAt,
      })
      .returning();
    if (!created) throw new Error("Failed to create coalesced data-plane job");
    return created;
  });
}

export type LeasedDataPlaneJob = GatewayJob & { lease_token: string };

export async function claimDataPlaneJob(now = new Date()): Promise<LeasedDataPlaneJob | null> {
  return db.transaction(async (tx) => {
    const [candidate] = await tx
      .select({ id: gateway_jobs.id })
      .from(gateway_jobs)
      .where(
        and(
          inArray(gateway_jobs.type, [...DATA_PLANE_JOB_TYPES]),
          eq(gateway_jobs.status, "queued"),
          lte(gateway_jobs.available_at, now),
          or(isNull(gateway_jobs.lease_expires_at), lte(gateway_jobs.lease_expires_at, now)),
        ),
      )
      .orderBy(asc(gateway_jobs.available_at), asc(gateway_jobs.created_at))
      .limit(1)
      .for("update", { skipLocked: true });
    if (!candidate) return null;

    const leaseToken = randomUUID();
    const [claimed] = await tx
      .update(gateway_jobs)
      .set({
        status: "running",
        attempts: sql`${gateway_jobs.attempts} + 1`,
        lease_token: leaseToken,
        lease_expires_at: new Date(now.getTime() + LEASE_MS),
        updated_at: now,
      })
      .where(
        and(
          eq(gateway_jobs.id, candidate.id),
          inArray(gateway_jobs.status, ["queued", "running"]),
          or(isNull(gateway_jobs.lease_expires_at), lte(gateway_jobs.lease_expires_at, now)),
        ),
      )
      .returning();
    return claimed ? ({ ...claimed, lease_token: leaseToken } as LeasedDataPlaneJob) : null;
  });
}

export async function completeDataPlaneJob(job: LeasedDataPlaneJob): Promise<void> {
  const [updated] = await db
    .update(gateway_jobs)
    .set({
      status: "done",
      lease_token: null,
      lease_expires_at: null,
      last_error: null,
      updated_at: new Date(),
    })
    .where(
      and(
        eq(gateway_jobs.id, job.id),
        eq(gateway_jobs.status, "running"),
        eq(gateway_jobs.lease_token, job.lease_token),
      ),
    )
    .returning({ id: gateway_jobs.id });
  if (!updated) throw new Error(`Lost lease while completing data-plane job ${job.id}`);
}

export async function failDataPlaneJob(job: LeasedDataPlaneJob, error: unknown): Promise<void> {
  const dead = job.attempts >= MAX_ATTEMPTS;
  const delayMs = Math.min(60_000, 1_000 * 2 ** Math.max(0, job.attempts - 1));
  await db
    .update(gateway_jobs)
    .set({
      status: dead ? "dead" : "queued",
      available_at: dead ? new Date() : new Date(Date.now() + delayMs),
      lease_token: null,
      lease_expires_at: null,
      last_error: error instanceof Error ? error.message.slice(0, 4_000) : String(error).slice(0, 4_000),
      updated_at: new Date(),
    })
    .where(
      and(eq(gateway_jobs.id, job.id), eq(gateway_jobs.lease_token, job.lease_token)),
    );
}
