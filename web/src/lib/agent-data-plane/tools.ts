import "server-only";
import { randomUUID } from "node:crypto";
import { and, asc, eq, inArray, isNull, lte, or, sql } from "drizzle-orm";
import { db } from "@/lib/db/client";
import {
  agent_tool_bindings,
  tool_connections,
  tool_definitions,
  tool_execution_outbox,
  work_orders,
  type WorkOrder,
} from "@/lib/db/schema";
import type { ProposedAction } from "./contracts";
import { hashJson } from "./hash";

// Tool definitions permit timeouts up to 300 seconds. The lease must outlive
// that bound so another worker cannot dispatch the same external action while
// the first request is still legitimately in flight.
const OUTBOX_LEASE_MS = 330_000;
const MAX_SAFE_ATTEMPTS = 3;
const RETRY_SAFE_EXTERNAL_TOOLS = new Set([
  "calendar.create_event",
  "email.create_draft",
]);

export interface ProposalResult {
  action: ProposedAction;
  workOrder: WorkOrder | null;
  decision: "auto" | "confirm" | "forbidden" | "unknown_tool" | "effect_mismatch";
}

export function decideToolApproval(input: {
  effect: "read" | "internal_write" | "external_write" | "destructive";
  defaultApproval: "auto" | "confirm" | "forbidden";
  requested: "auto" | "required" | "forbidden";
  bindingRequired: boolean;
  bindingPresent: boolean;
  override?: "auto" | "confirm" | "forbidden" | null;
}): "auto" | "confirm" | "forbidden" {
  let approval = input.defaultApproval;
  if (input.bindingRequired && !input.bindingPresent) approval = "forbidden";
  else if (input.override) approval = input.override;
  if (input.requested === "forbidden") approval = "forbidden";
  if (input.requested === "required" && approval === "auto") approval = "confirm";
  if (
    (input.effect === "external_write" || input.effect === "destructive") &&
    approval === "auto"
  ) {
    approval = "confirm";
  }
  return approval;
}

export async function createActionProposals(input: {
  userId: string;
  runId: string;
  agentId?: string | null;
  actions: ProposedAction[];
}): Promise<ProposalResult[]> {
  const results: ProposalResult[] = [];
  for (const action of input.actions) {
    const [definition] = await db
      .select()
      .from(tool_definitions)
      .where(and(eq(tool_definitions.key, action.tool), eq(tool_definitions.enabled, true)))
      .limit(1);
    if (!definition) {
      results.push({ action, workOrder: null, decision: "unknown_tool" });
      continue;
    }
    if (definition.effect !== action.effect) {
      results.push({ action, workOrder: null, decision: "effect_mismatch" });
      continue;
    }

    let override: "auto" | "confirm" | "forbidden" | null = null;
    let bindingPresent = !input.agentId;
    let connectionId: string | null = null;
    if (input.agentId) {
      const [binding] = await db
        .select()
        .from(agent_tool_bindings)
        .where(
          and(
            eq(agent_tool_bindings.agent_id, input.agentId),
            eq(agent_tool_bindings.tool_key, action.tool),
            eq(agent_tool_bindings.enabled, true),
          ),
        )
        .limit(1);
      if (binding) {
        bindingPresent = true;
        connectionId = binding.connection_id;
        override = binding.approval_override;
      }
    }
    const approval = decideToolApproval({
      effect: definition.effect,
      defaultApproval: definition.default_approval,
      requested: action.approval,
      bindingRequired: Boolean(input.agentId),
      bindingPresent,
      override,
    });

    const idempotencyKey = `tool:${input.userId}:${input.runId}:${action.tool}:${hashJson(action.arguments)}`;
    const [created] = await db
      .insert(work_orders)
      .values({
        user_id: input.userId,
        run_id: input.runId,
        intent: action.rationale ?? `Proposed ${action.tool}`,
        context: { source: "agent_output", connection_id: connectionId },
        output_spec: JSON.stringify(definition.output_schema),
        gate: approval === "auto" ? "auto" : "approve-first",
        status: approval === "forbidden" ? "rejected" : approval === "confirm" ? "gated" : "approved",
        tool_key: action.tool,
        arguments: action.arguments,
        effect: definition.effect,
        approval_required: approval !== "auto",
        approved_at: approval === "auto" ? new Date() : null,
        approved_by: approval === "auto" ? input.userId : null,
        rejected_at: approval === "forbidden" ? new Date() : null,
        rejection_reason: approval === "forbidden" ? "Tool policy forbids this action" : null,
        provider_idempotency_key: idempotencyKey,
      })
      .onConflictDoNothing({ target: work_orders.provider_idempotency_key })
      .returning();

    const workOrder = created ??
      (await db
        .select()
        .from(work_orders)
        .where(eq(work_orders.provider_idempotency_key, idempotencyKey))
        .limit(1))[0] ??
      null;
    if (workOrder?.status === "approved") await enqueueApprovedWorkOrder(workOrder.id, input.userId);
    results.push({ action, workOrder, decision: approval });
  }
  return results;
}

export async function approveWorkOrder(workOrderId: string, userId: string): Promise<WorkOrder> {
  const order = await db.transaction(async (tx) => {
    const [current] = await tx
      .select()
      .from(work_orders)
      .where(and(eq(work_orders.id, workOrderId), eq(work_orders.user_id, userId)))
      .limit(1)
      .for("update");
    if (!current) throw new Error("Work order not found");
    if (current.status === "rejected") throw new Error("Rejected work order cannot be approved");
    if (current.status === "done") return current;
    if (!current.tool_key || !current.provider_idempotency_key) {
      throw new Error("Work order is not an executable tool proposal");
    }
    if (!isToolExecutorAvailable(current.tool_key)) {
      throw new Error("No executor is configured for this tool");
    }
    const context = (current.context ?? {}) as Record<string, unknown>;
    const connectionId = typeof context.connection_id === "string" ? context.connection_id : null;
    const [definition] = await tx
      .select()
      .from(tool_definitions)
      .where(and(eq(tool_definitions.key, current.tool_key), eq(tool_definitions.enabled, true)))
      .limit(1);
    if (!definition) throw new Error("Tool definition is missing or disabled");
    if (definition.source === "connector" && !connectionId) {
      throw new Error("This tool requires an active user connection");
    }
    if (connectionId) {
      const [connection] = await tx
        .select()
        .from(tool_connections)
        .where(
          and(
            eq(tool_connections.id, connectionId),
            eq(tool_connections.user_id, userId),
            eq(tool_connections.status, "active"),
            isNull(tool_connections.revoked_at),
          ),
        )
        .limit(1);
      if (!connection) throw new Error("Tool connection is missing, revoked, or inactive");
      const required = Array.isArray(definition.required_scopes)
        ? (definition.required_scopes as string[])
        : [];
      const scopes = Array.isArray(connection.scopes) ? (connection.scopes as string[]) : [];
      if (!required.every((scope) => scopes.includes(scope))) {
        throw new Error("Tool connection does not grant all required scopes");
      }
    }
    const [updated] = await tx
      .update(work_orders)
      .set({
        status: "approved",
        approved_at: new Date(),
        approved_by: userId,
        rejected_at: null,
        rejection_reason: null,
        updated_at: new Date(),
      })
      .where(eq(work_orders.id, current.id))
      .returning();
    if (!updated) throw new Error("Failed to approve work order");
    await tx
      .insert(tool_execution_outbox)
      .values({
        user_id: userId,
        work_order_id: updated.id,
        tool_key: updated.tool_key!,
        connection_id: connectionId,
        arguments: (updated.arguments ?? {}) as Record<string, unknown>,
        idempotency_key: updated.provider_idempotency_key!,
      })
      .onConflictDoNothing({ target: tool_execution_outbox.idempotency_key });
    return updated;
  });
  return order;
}

export async function rejectWorkOrder(
  workOrderId: string,
  userId: string,
  reason?: string,
): Promise<WorkOrder> {
  const [order] = await db
    .update(work_orders)
    .set({
      status: "rejected",
      rejected_at: new Date(),
      rejection_reason: reason?.slice(0, 2_000) || "Rejected by user",
      updated_at: new Date(),
    })
    .where(
      and(
        eq(work_orders.id, workOrderId),
        eq(work_orders.user_id, userId),
        inArray(work_orders.status, ["pending", "gated"]),
      ),
    )
    .returning();
  if (!order) throw new Error("Work order not found or no longer rejectable");
  return order;
}

async function enqueueApprovedWorkOrder(workOrderId: string, userId: string): Promise<void> {
  const [order] = await db
    .select()
    .from(work_orders)
    .where(and(eq(work_orders.id, workOrderId), eq(work_orders.user_id, userId)))
    .limit(1);
  if (!order || order.status !== "approved" || !order.tool_key || !order.provider_idempotency_key) {
    return;
  }
  const context = (order.context ?? {}) as Record<string, unknown>;
  const connectionId = typeof context.connection_id === "string" ? context.connection_id : null;
  const [definition] = await db
    .select({ source: tool_definitions.source })
    .from(tool_definitions)
    .where(eq(tool_definitions.key, order.tool_key))
    .limit(1);
  if (definition?.source === "connector" && !connectionId) {
    throw new Error("This tool requires an active user connection");
  }
  if (connectionId) await assertUsableConnection(userId, connectionId, order.tool_key);
  await db
    .insert(tool_execution_outbox)
    .values({
      user_id: userId,
      work_order_id: order.id,
      tool_key: order.tool_key,
      connection_id: connectionId,
      arguments: (order.arguments ?? {}) as Record<string, unknown>,
      idempotency_key: order.provider_idempotency_key,
    })
    .onConflictDoNothing({ target: tool_execution_outbox.idempotency_key });
}

async function assertUsableConnection(userId: string, connectionId: string, toolKey: string) {
  const [connection] = await db
    .select()
    .from(tool_connections)
    .where(
      and(
        eq(tool_connections.id, connectionId),
        eq(tool_connections.user_id, userId),
        eq(tool_connections.status, "active"),
        isNull(tool_connections.revoked_at),
      ),
    )
    .limit(1);
  if (!connection) throw new Error("Tool connection is missing, revoked, or inactive");
  const [tool] = await db.select().from(tool_definitions).where(eq(tool_definitions.key, toolKey)).limit(1);
  const required = Array.isArray(tool?.required_scopes) ? (tool.required_scopes as string[]) : [];
  const scopes = Array.isArray(connection.scopes) ? (connection.scopes as string[]) : [];
  if (!required.every((scope) => scopes.includes(scope))) {
    throw new Error("Tool connection does not grant all required scopes");
  }
  return connection;
}

export interface ToolExecutorContext {
  userId: string;
  connectionId: string | null;
  authRef: string | null;
  idempotencyKey: string;
  signal: AbortSignal;
}

export type ToolExecutor = (
  args: Record<string, unknown>,
  context: ToolExecutorContext,
) => Promise<Record<string, unknown>>;

const executors = new Map<string, ToolExecutor>();
let configuredExecutorsLoaded = false;

export function registerToolExecutor(toolKey: string, executor: ToolExecutor): () => void {
  executors.set(toolKey, executor);
  return () => executors.delete(toolKey);
}

/**
 * Registers the optional server-side connector gateway. `auth_ref` remains an
 * opaque vault/connector reference; raw OAuth credentials never enter the
 * DayPage database or Agent output. In environments without a gateway,
 * approval fails before changing Work Order state.
 */
export function ensureConfiguredToolExecutors(): void {
  if (configuredExecutorsLoaded) return;
  configuredExecutorsLoaded = true;
  const rawUrl = process.env.DAYPAGE_TOOL_EXECUTOR_URL?.trim();
  const secret = process.env.DAYPAGE_TOOL_EXECUTOR_SECRET?.trim();
  if (!rawUrl || !secret) return;
  const url = new URL(rawUrl);
  if (
    url.protocol !== "https:" &&
    !(url.protocol === "http:" && ["127.0.0.1", "localhost", "::1"].includes(url.hostname))
  ) {
    throw new Error("DAYPAGE_TOOL_EXECUTOR_URL must use HTTPS outside loopback");
  }
  for (const toolKey of ["calendar.create_event", "email.create_draft", "email.send"]) {
    registerToolExecutor(toolKey, async (args, context) => {
      const response = await fetch(url, {
        method: "POST",
        signal: context.signal,
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${secret}`,
          "idempotency-key": context.idempotencyKey,
        },
        body: JSON.stringify({
          tool: toolKey,
          arguments: args,
          user_id: context.userId,
          connection_id: context.connectionId,
          auth_ref: context.authRef,
        }),
      });
      const data = (await response.json().catch(() => ({}))) as Record<string, unknown>;
      if (!response.ok) {
        throw new Error(`Tool gateway rejected ${toolKey} with HTTP ${response.status}`);
      }
      return data;
    });
  }
}

export function isToolExecutorAvailable(toolKey: string): boolean {
  ensureConfiguredToolExecutors();
  return executors.has(toolKey);
}

export async function processOneToolExecution(): Promise<boolean> {
  ensureConfiguredToolExecutors();
  const now = new Date();
  const leaseToken = randomUUID();
  const item = await db.transaction(async (tx) => {
    const [candidate] = await tx
      .select({ id: tool_execution_outbox.id })
      .from(tool_execution_outbox)
      .where(
        and(
          inArray(tool_execution_outbox.status, ["pending", "failed"]),
          lte(tool_execution_outbox.available_at, now),
          or(
            isNull(tool_execution_outbox.lease_expires_at),
            lte(tool_execution_outbox.lease_expires_at, now),
          ),
        ),
      )
      .orderBy(asc(tool_execution_outbox.available_at), asc(tool_execution_outbox.created_at))
      .limit(1)
      .for("update", { skipLocked: true });
    if (!candidate) return null;
    const [claimed] = await tx
      .update(tool_execution_outbox)
      .set({
        status: "running",
        attempts: sql`${tool_execution_outbox.attempts} + 1`,
        lease_token: leaseToken,
        lease_expires_at: new Date(now.getTime() + OUTBOX_LEASE_MS),
        updated_at: now,
      })
      .where(eq(tool_execution_outbox.id, candidate.id))
      .returning();
    return claimed ?? null;
  });
  if (!item) return false;

  const [order] = await db
    .select()
    .from(work_orders)
    .where(and(eq(work_orders.id, item.work_order_id), eq(work_orders.user_id, item.user_id)))
    .limit(1);
  if (!order || order.status !== "approved" || !order.approved_at) {
    await parkOutbox(item.id, leaseToken, "Approval is absent or was revoked", true);
    return true;
  }

  const [definition] = await db
    .select()
    .from(tool_definitions)
    .where(and(eq(tool_definitions.key, item.tool_key), eq(tool_definitions.enabled, true)))
    .limit(1);
  const executor = executors.get(item.tool_key);
  if (!definition || !executor) {
    await parkOutbox(item.id, leaseToken, "No enabled executor is registered for this tool", true);
    return true;
  }

  let authRef: string | null = null;
  if (item.connection_id) {
    const connection = await assertUsableConnection(item.user_id, item.connection_id, item.tool_key);
    authRef = connection.auth_ref;
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), definition.timeout_seconds * 1_000);
  try {
    const rawReceipt = await executor(item.arguments as Record<string, unknown>, {
      userId: item.user_id,
      connectionId: item.connection_id,
      authRef,
      idempotencyKey: item.idempotency_key,
      signal: controller.signal,
    });
    const receipt = sanitizeReceipt(rawReceipt, definition.max_result_bytes);
    await db.transaction(async (tx) => {
      const [completed] = await tx
        .update(tool_execution_outbox)
        .set({
          status: "completed",
          provider_receipt: receipt,
          lease_token: null,
          lease_expires_at: null,
          last_error: null,
          updated_at: new Date(),
        })
        .where(
          and(
            eq(tool_execution_outbox.id, item.id),
            eq(tool_execution_outbox.lease_token, leaseToken),
          ),
        )
        .returning({ id: tool_execution_outbox.id });
      if (!completed) return;
      await tx
        .update(work_orders)
        .set({ status: "done", provider_receipt: receipt, result_ref: item.id, updated_at: new Date() })
        .where(eq(work_orders.id, item.work_order_id));
    });
  } catch (error) {
    const retrySafe = RETRY_SAFE_EXTERNAL_TOOLS.has(item.tool_key);
    const dead = !retrySafe || item.attempts >= MAX_SAFE_ATTEMPTS;
    const parked = await parkOutbox(
      item.id,
      leaseToken,
      error instanceof Error ? error.message : String(error),
      dead,
    );
    if (parked) {
      await db
        .update(work_orders)
        .set({ status: dead ? "failed" : "approved", updated_at: new Date() })
        .where(eq(work_orders.id, item.work_order_id));
    }
  } finally {
    clearTimeout(timer);
  }
  return true;
}

async function parkOutbox(id: string, leaseToken: string, error: string, dead: boolean): Promise<boolean> {
  const [updated] = await db
    .update(tool_execution_outbox)
    .set({
      status: dead ? "dead" : "failed",
      available_at: new Date(Date.now() + 5_000),
      lease_token: null,
      lease_expires_at: null,
      last_error: error.slice(0, 4_000),
      updated_at: new Date(),
    })
    .where(
      and(eq(tool_execution_outbox.id, id), eq(tool_execution_outbox.lease_token, leaseToken)),
    )
    .returning({ id: tool_execution_outbox.id });
  return Boolean(updated);
}

export function sanitizeReceipt(value: Record<string, unknown>, maxBytes: number): Record<string, unknown> {
  const sensitive = /token|secret|authorization|cookie|password|credential/i;
  const scrub = (child: unknown, depth: number): unknown => {
    if (depth > 8) return "[depth-limited]";
    if (typeof child === "string") return child.slice(0, 8_000);
    if (Array.isArray(child)) return child.slice(0, 100).map((item) => scrub(item, depth + 1));
    if (child && typeof child === "object") {
      return Object.fromEntries(
        Object.entries(child as Record<string, unknown>)
          .slice(0, 100)
          .filter(([key]) => !sensitive.test(key))
          .map(([key, nested]) => [key, scrub(nested, depth + 1)]),
      );
    }
    return child;
  };
  const cleaned = scrub(value, 0) as Record<string, unknown>;
  const encoded = JSON.stringify(cleaned);
  if (Buffer.byteLength(encoded, "utf8") <= maxBytes) return cleaned;
  return {
    truncated: true,
    sha256: hashJson(cleaned),
    preview: encoded.slice(0, Math.max(0, maxBytes - 200)),
  };
}
