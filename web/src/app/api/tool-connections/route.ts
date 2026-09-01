import { NextResponse } from "next/server";
import { desc, eq } from "drizzle-orm";
import { z } from "zod";
import { currentApiUserId } from "@/lib/auth/api-user";
import { db } from "@/lib/db/client";
import { tool_connections } from "@/lib/db/schema";

const CreateSchema = z.object({
  provider: z.string().min(1).max(100),
  auth_ref: z
    .string()
    .min(3)
    .max(500)
    .regex(/^[a-z][a-z0-9+.-]*:/i, "auth_ref must be a secure backend reference")
    .refine((value) => !/bearer|access[_-]?token|refresh[_-]?token|password/i.test(value), "raw credentials are forbidden"),
  scopes: z.array(z.string().min(1).max(200)).max(100),
  metadata: z.record(z.string(), z.unknown()).optional(),
});

export async function GET() {
  const userId = await currentApiUserId();
  if (!userId) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  const rows = await db
    .select({
      id: tool_connections.id,
      provider: tool_connections.provider,
      scopes: tool_connections.scopes,
      status: tool_connections.status,
      metadata: tool_connections.metadata,
      revoked_at: tool_connections.revoked_at,
      created_at: tool_connections.created_at,
      updated_at: tool_connections.updated_at,
    })
    .from(tool_connections)
    .where(eq(tool_connections.user_id, userId))
    .orderBy(desc(tool_connections.created_at));
  return NextResponse.json({ items: rows });
}

export async function POST(request: Request) {
  const userId = await currentApiUserId();
  if (!userId) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  const parsed = CreateSchema.safeParse(await request.json().catch(() => null));
  if (!parsed.success) {
    return NextResponse.json({ error: "Invalid connection reference", details: parsed.error.flatten() }, { status: 400 });
  }
  const [created] = await db
    .insert(tool_connections)
    .values({ user_id: userId, ...parsed.data, metadata: parsed.data.metadata ?? {} })
    .onConflictDoUpdate({
      target: [tool_connections.user_id, tool_connections.provider, tool_connections.auth_ref],
      set: {
        scopes: parsed.data.scopes,
        metadata: parsed.data.metadata ?? {},
        status: "active",
        revoked_at: null,
        updated_at: new Date(),
      },
    })
    .returning({
      id: tool_connections.id,
      provider: tool_connections.provider,
      scopes: tool_connections.scopes,
      status: tool_connections.status,
    });
  return NextResponse.json(created, { status: 201 });
}
