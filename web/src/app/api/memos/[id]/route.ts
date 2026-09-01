import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { memos, users } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";
import { PatchMemoSchema } from "@/lib/schemas/memo";
import { checkMutationRateLimit } from "@/lib/ratelimit";
import { sanitizeMemoBody } from "@/lib/sanitize";
import { memoContentHash } from "@/lib/memo-revision";

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

function notFound() {
  return NextResponse.json({ error: "Not found" }, { status: 404 });
}

function badRequest(message: string) {
  return NextResponse.json({ error: message }, { status: 400 });
}

async function resolveUserId(email: string): Promise<string | null> {
  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email))
    .limit(1);
  return rows[0]?.id ?? null;
}

type RouteContext = { params: Promise<{ id: string }> };

// GET /api/memos/:id
export async function GET(_req: NextRequest, ctx: RouteContext) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const { id } = await ctx.params;
  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const rows = await db
    .select()
    .from(memos)
    .where(and(eq(memos.id, id), eq(memos.user_id, userId)))
    .limit(1);

  if (!rows.length) return notFound();
  return NextResponse.json(rows[0]);
}

// PATCH /api/memos/:id — partial update
export async function PATCH(req: NextRequest, ctx: RouteContext) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const rl = await checkMutationRateLimit(session.user.email);
  if (!rl.success) {
    return NextResponse.json(
      { error: "Rate limit exceeded" },
      {
        status: 429,
        headers: { "Retry-After": Math.ceil((rl.reset - Date.now()) / 1000).toString() },
      }
    );
  }

  const { id } = await ctx.params;
  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const body: unknown = await req.json().catch(() => null);
  if (!body) return badRequest("Invalid JSON body");

  const parsed = PatchMemoSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }

  const input = parsed.data;
  const [current] = await db
    .select()
    .from(memos)
    .where(and(eq(memos.id, id), eq(memos.user_id, userId)))
    .limit(1);
  if (!current) return notFound();
  const updateData: Record<string, unknown> = {};

  if (input.type !== undefined) updateData.type = input.type;
  if (input.body !== undefined) updateData.body = sanitizeMemoBody(input.body);
  if (input.location !== undefined) updateData.location = input.location;
  if (input.weather !== undefined) updateData.weather = input.weather;
  if (input.device !== undefined) updateData.device = input.device;
  if (input.source_url !== undefined) updateData.source_url = input.source_url;
  if (input.ingest_mode !== undefined) updateData.ingest_mode = input.ingest_mode;
  if (input.compile_status !== undefined) updateData.compile_status = input.compile_status;
  if (input.pinned_at !== undefined) {
    updateData.pinned_at = input.pinned_at ? new Date(input.pinned_at) : null;
  }

  if (Object.keys(updateData).length === 0) {
    return badRequest("No fields to update");
  }

  const rawRevisionFields = [
    "type",
    "body",
    "location",
    "weather",
    "device",
    "source_url",
    "ingest_mode",
  ] as const;
  const rawChanged = rawRevisionFields.some((field) => input[field] !== undefined);
  if (rawChanged) {
    const nextBody = typeof updateData.body === "string" ? updateData.body : current.body;
    updateData.sync_revision = current.sync_revision + 1;
    updateData.source_modified_at = new Date();
    updateData.content_hash = memoContentHash(nextBody);
    updateData.compile_status = "pending";
    updateData.compile_error = null;
  }

  const rows = await db
    .update(memos)
    .set(updateData)
    .where(
      and(
        eq(memos.id, id),
        eq(memos.user_id, userId),
        eq(memos.sync_revision, current.sync_revision),
      ),
    )
    .returning();

  if (!rows.length) {
    return NextResponse.json({ error: "Memo changed concurrently; reload and retry" }, { status: 409 });
  }
  return NextResponse.json(rows[0]);
}

// DELETE /api/memos/:id — revisioned tombstone. Raw Vault deletion still follows
// the client sync contract; remote ingress never hard-deletes a memo row.
export async function DELETE(_req: NextRequest, ctx: RouteContext) {
  const session = await auth();
  if (!session?.user?.email) return unauthorized();

  const rl = await checkMutationRateLimit(session.user.email);
  if (!rl.success) {
    return NextResponse.json(
      { error: "Rate limit exceeded" },
      {
        status: 429,
        headers: { "Retry-After": Math.ceil((rl.reset - Date.now()) / 1000).toString() },
      }
    );
  }

  const { id } = await ctx.params;
  const userId = await resolveUserId(session.user.email);
  if (!userId) return unauthorized();

  const [current] = await db
    .select({ revision: memos.sync_revision })
    .from(memos)
    .where(and(eq(memos.id, id), eq(memos.user_id, userId)))
    .limit(1);
  if (!current) return notFound();
  const now = new Date();
  const rows = await db
    .update(memos)
    .set({
      deleted_at: now,
      source_modified_at: now,
      sync_revision: current.revision + 1,
      compile_status: "pending",
      compile_error: null,
    })
    .where(
      and(
        eq(memos.id, id),
        eq(memos.user_id, userId),
        eq(memos.sync_revision, current.revision),
      ),
    )
    .returning({ id: memos.id });

  if (!rows.length) {
    return NextResponse.json({ error: "Memo changed concurrently; reload and retry" }, { status: 409 });
  }
  return new NextResponse(null, { status: 204 });
}
