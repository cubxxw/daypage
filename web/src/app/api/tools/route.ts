import { NextResponse } from "next/server";
import { and, asc, eq } from "drizzle-orm";
import { currentApiUserId } from "@/lib/auth/api-user";
import { db } from "@/lib/db/client";
import { tool_connections, tool_definitions } from "@/lib/db/schema";
import { ensureBuiltInRegistry } from "@/lib/agent-data-plane/registry";
import { isToolExecutorAvailable } from "@/lib/agent-data-plane/tools";

export async function GET() {
  const userId = await currentApiUserId();
  if (!userId) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  await ensureBuiltInRegistry();
  const [definitions, connections] = await Promise.all([
    db
      .select()
      .from(tool_definitions)
      .where(eq(tool_definitions.enabled, true))
      .orderBy(asc(tool_definitions.key)),
    db
      .select({
        id: tool_connections.id,
        provider: tool_connections.provider,
        scopes: tool_connections.scopes,
        status: tool_connections.status,
        revoked_at: tool_connections.revoked_at,
      })
      .from(tool_connections)
      .where(and(eq(tool_connections.user_id, userId), eq(tool_connections.status, "active"))),
  ]);
  return NextResponse.json({
    definitions: definitions.map((definition) => ({
      ...definition,
      executor_available:
        definition.source !== "connector" || isToolExecutorAvailable(definition.key),
    })),
    connections,
  });
}
