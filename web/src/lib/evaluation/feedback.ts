import "server-only";
import { and, eq } from "drizzle-orm";
import { db } from "@/lib/db/client";
import {
  agent_artifacts,
  agent_feedback_events,
  agent_runs,
  evaluation_case_candidates,
  work_orders,
  type AgentFeedbackEvent,
} from "@/lib/db/schema";
import {
  RecordFeedbackSchema,
  type FeedbackEventType,
  type RecordFeedbackInput,
} from "./contracts";
import { enqueueEvaluationExport } from "./outbox";

const HIGH_SIGNAL_FAILURES = new Set<FeedbackEventType>([
  "response.edited",
  "response.not_relevant",
  "response.style_blocked",
  "action.modified",
  "memory.corrected",
  "memory.rejected",
]);

export function feedbackScoreProjection(event: {
  event_type: FeedbackEventType;
  value?: number | null;
  reason_code?: string | null;
}): Array<{ name: string; value: number; reason?: string }> {
  const reason = event.reason_code ?? undefined;
  const exact = [{ name: `user.${event.event_type}`, value: 1, reason }];
  const explicit = event.value === null || event.value === undefined
    ? []
    : [{ name: "user.explicit_value", value: event.value, reason }];
  switch (event.event_type) {
    case "response.saved":
      return [...exact, ...explicit, { name: "user.response_durable_value", value: 1, reason }];
    case "response.not_relevant":
      return [...exact, ...explicit, { name: "user.context_relevance", value: 0, reason }];
    case "response.style_blocked":
      return [...exact, ...explicit, { name: "user.style_acceptance", value: 0, reason }];
    case "action.accepted":
      return [...exact, ...explicit, { name: "user.action_adoption", value: 1, reason }];
    case "action.rejected":
      return [...exact, ...explicit, { name: "user.action_adoption", value: 0, reason }];
    case "memory.confirmed":
      return [...exact, ...explicit, { name: "user.memory_acceptance", value: 1, reason }];
    case "memory.rejected":
      return [...exact, ...explicit, { name: "user.memory_acceptance", value: 0, reason }];
    case "followup.continued":
      return [...exact, ...explicit, { name: "user.cognitive_momentum", value: 1, reason }];
    default:
      return [...exact, ...explicit];
  }
}

function assertTargetForEvent(input: RecordFeedbackInput): void {
  if (input.event_type.startsWith("action.") && !input.work_order_id) {
    throw new Error("Action feedback requires work_order_id");
  }
  if (input.event_type.startsWith("memory.") && !input.artifact_id) {
    throw new Error("Memory feedback requires artifact_id");
  }
  if (input.artifact_id && input.work_order_id) {
    throw new Error("Feedback may target an artifact or a work order, not both");
  }
}

export async function recordAgentFeedback(input: {
  userId: string;
  runId: string;
  feedback: RecordFeedbackInput;
}): Promise<AgentFeedbackEvent> {
  const feedback = RecordFeedbackSchema.parse(input.feedback);
  assertTargetForEvent(feedback);

  const [run] = await db
    .select({ id: agent_runs.id })
    .from(agent_runs)
    .where(and(eq(agent_runs.id, input.runId), eq(agent_runs.user_id, input.userId)))
    .limit(1);
  if (!run) throw new Error("Agent Run not found");

  if (feedback.artifact_id) {
    const [artifact] = await db
      .select({ id: agent_artifacts.id, kind: agent_artifacts.kind })
      .from(agent_artifacts)
      .where(
        and(
          eq(agent_artifacts.id, feedback.artifact_id),
          eq(agent_artifacts.run_id, run.id),
          eq(agent_artifacts.user_id, input.userId),
        ),
      )
      .limit(1);
    if (!artifact) throw new Error("Feedback artifact does not belong to the Agent Run");
    if (feedback.event_type.startsWith("response.") && artifact.kind !== "agent_response") {
      throw new Error("Response feedback must target an agent_response artifact");
    }
    if (feedback.event_type.startsWith("memory.") && artifact.kind !== "memory_proposal") {
      throw new Error("Memory feedback must target a memory_proposal artifact");
    }
  }

  if (feedback.work_order_id) {
    const [workOrder] = await db
      .select({ id: work_orders.id })
      .from(work_orders)
      .where(
        and(
          eq(work_orders.id, feedback.work_order_id),
          eq(work_orders.run_id, run.id),
          eq(work_orders.user_id, input.userId),
        ),
      )
      .limit(1);
    if (!workOrder) throw new Error("Feedback Work Order does not belong to the Agent Run");
  }

  const event = await db.transaction(async (tx) => {
    const [created] = await tx
      .insert(agent_feedback_events)
      .values({
        user_id: input.userId,
        run_id: run.id,
        artifact_id: feedback.artifact_id ?? null,
        work_order_id: feedback.work_order_id ?? null,
        event_type: feedback.event_type,
        value: feedback.value ?? null,
        reason_code: feedback.reason_code ?? null,
        correction: feedback.correction ?? null,
        metadata: feedback.metadata ?? {},
        idempotency_key: feedback.idempotency_key,
      })
      .onConflictDoNothing({ target: agent_feedback_events.idempotency_key })
      .returning();
    if (created) return created;
    const [existing] = await tx
      .select()
      .from(agent_feedback_events)
      .where(eq(agent_feedback_events.idempotency_key, feedback.idempotency_key))
      .limit(1);
    if (!existing || existing.user_id !== input.userId || existing.run_id !== run.id) {
      throw new Error("Feedback idempotency key is already used by another target");
    }
    return existing;
  });

  if (HIGH_SIGNAL_FAILURES.has(feedback.event_type)) {
    await db
      .insert(evaluation_case_candidates)
      .values({
        user_id: input.userId,
        run_id: run.id,
        feedback_event_id: event.id,
        reason: feedback.event_type,
      })
      .onConflictDoNothing({ target: evaluation_case_candidates.feedback_event_id });
  }

  await enqueueEvaluationExport({
    userId: input.userId,
    runId: run.id,
    entityType: "feedback",
    entityId: event.id,
    operation: "score",
    payload: { scores: feedbackScoreProjection(event as typeof event & { event_type: FeedbackEventType }) },
    idempotencyKey: `opik:feedback:${event.id}:v1`,
  });
  return event;
}
