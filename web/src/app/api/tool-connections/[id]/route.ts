import { NextResponse } from "next/server";
import { and, eq } from "drizzle-orm";
import { currentApiUserId } from "@/lib/auth/api-user";
import { db } from "@/lib/db/client";
import { agent_tool_bindings, tool_connections } from "@/lib/db/schema";

type Context = { params: Promise<{ id: string }> };

export async function DELETE(_request: Request, context: Context) {
  const userId = await currentApiUserId();
  if (!userId) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  const { id } = await context.params;
  const now = new Date();
  const [revoked] = await db
    .update(tool_connections)
    .set({ status: "revoked", revoked_at: now, updated_at: now })
    .where(and(eq(tool_connections.id, id), eq(tool_connections.user_id, userId)))
    .returning({ id: tool_connections.id });
  if (!revoked) return NextResponse.json({ error: "Connection not found" }, { status: 404 });
  await db
    .update(agent_tool_bindings)
    .set({ enabled: false })
    .where(eq(agent_tool_bindings.connection_id, id));
  return new NextResponse(null, { status: 204 });
}
