import "server-only";
import { randomUUID } from "node:crypto";
import { and, asc, eq, inArray, isNull, lte, or, sql } from "drizzle-orm";
import { db } from "@/lib/db/client";
import {
  evaluation_export_outbox,
  type EvaluationExportOutboxItem,
} from "@/lib/db/schema";
import { evaluationConfig } from "./config";

const LEASE_MS = 5 * 60_000;
const MAX_ATTEMPTS = 8;

export type EvaluationExportEntityType =
  | "trace"
  | "feedback"
  | "evaluation_result"
  | "dataset_item"
  | "experiment";

export type LeasedEvaluationExport = EvaluationExportOutboxItem & { lease_token: string };

export async function enqueueEvaluationExport(input: {
  userId: string;
  runId?: string;
  entityType: EvaluationExportEntityType;
  entityId: string;
  operation: "upsert" | "score" | "insert" | "delete";
  payload?: Record<string, unknown>;
  idempotencyKey: string;
}): Promise<EvaluationExportOutboxItem | null> {
  const config = evaluationConfig();
  if (config.exportMode === "off") return null;
  const [created] = await db
    .insert(evaluation_export_outbox)
    .values({
      user_id: input.userId,
      run_id: input.runId ?? null,
      entity_type: input.entityType,
      entity_id: input.entityId,
      operation: input.operation,
      privacy_mode: config.exportMode,
      payload: input.payload ?? {},
      idempotency_key: input.idempotencyKey,
    })
    .onConflictDoNothing({ target: evaluation_export_outbox.idempotency_key })
    .returning();
  if (created) return created;
  const [existing] = await db
    .select()
    .from(evaluation_export_outbox)
    .where(eq(evaluation_export_outbox.idempotency_key, input.idempotencyKey))
    .limit(1);
  return existing ?? null;
}
export async function claimEvaluationExport(
  now = new Date(),
): Promise<LeasedEvaluationExport | null> {
  return db.transaction(async (tx) => {
    const [candidate] = await tx
      .select({ id: evaluation_export_outbox.id })
      .from(evaluation_export_outbox)
      .where(
        and(
          inArray(evaluation_export_outbox.status, ["pending", "running"]),
          lte(evaluation_export_outbox.available_at, now),
          or(
            isNull(evaluation_export_outbox.lease_expires_at),
            lte(evaluation_export_outbox.lease_expires_at, now),
          ),
        ),
      )
      .orderBy(asc(evaluation_export_outbox.available_at), asc(evaluation_export_outbox.created_at))
      .limit(1)
      .for("update", { skipLocked: true });
    if (!candidate) return null;

    const leaseToken = randomUUID();
    const [claimed] = await tx
      .update(evaluation_export_outbox)
      .set({
        status: "running",
        attempts: sql`${evaluation_export_outbox.attempts} + 1`,
        lease_token: leaseToken,
        lease_expires_at: new Date(now.getTime() + LEASE_MS),
        updated_at: now,
      })
      .where(eq(evaluation_export_outbox.id, candidate.id))
      .returning();
    return claimed ? ({ ...claimed, lease_token: leaseToken } as LeasedEvaluationExport) : null;
  });
}

export async function completeEvaluationExport(
  item: LeasedEvaluationExport,
  externalId?: string,
): Promise<void> {
  const [updated] = await db
    .update(evaluation_export_outbox)
    .set({
      status: "completed",
      external_id: externalId ?? item.entity_id,
      lease_token: null,
      lease_expires_at: null,
      last_error: null,
      updated_at: new Date(),
    })
    .where(
      and(
        eq(evaluation_export_outbox.id, item.id),
        eq(evaluation_export_outbox.status, "running"),
        eq(evaluation_export_outbox.lease_token, item.lease_token),
      ),
    )
    .returning({ id: evaluation_export_outbox.id });
  if (!updated) throw new Error(`Lost lease while completing evaluation export ${item.id}`);
}

export async function failEvaluationExport(
  item: LeasedEvaluationExport,
  error: unknown,
): Promise<void> {
  const dead = item.attempts >= MAX_ATTEMPTS;
  const delayMs = Math.min(15 * 60_000, 2_000 * 2 ** Math.max(0, item.attempts - 1));
  await db
    .update(evaluation_export_outbox)
    .set({
      status: dead ? "dead" : "pending",
      available_at: dead ? new Date() : new Date(Date.now() + delayMs),
      lease_token: null,
      lease_expires_at: null,
      last_error: error instanceof Error ? error.message.slice(0, 4_000) : String(error).slice(0, 4_000),
      updated_at: new Date(),
    })
    .where(
      and(
        eq(evaluation_export_outbox.id, item.id),
        eq(evaluation_export_outbox.lease_token, item.lease_token),
      ),
    );
}
