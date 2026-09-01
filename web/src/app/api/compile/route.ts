import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth/session";
import { db } from "@/lib/db/client";
import { users, memos, pages } from "@/lib/db/schema";
import { eq, and, gte, lt, inArray, sql } from "drizzle-orm";
import { z } from "zod";
import { sendEvent } from "@/lib/inngest/client";
import { authenticateApiKey, hasScope } from "@/lib/api-auth";
import { checkRateLimit } from "@/lib/ratelimit";
import { randomUUID } from "node:crypto";
import { readUserTimezone } from "@/lib/agent-data-plane/artifacts";
import { addCalendarDays, zonedLocalDateTimeToUtc } from "@/lib/agent-data-plane/time";
import { enqueueUniqueDataPlaneJob } from "@/lib/agent-data-plane/jobs";
import { isAgentDataPlaneEnabled, shouldRunLegacyCompiler } from "@/lib/agent-data-plane/feature-flags";

// NOTE: iOS BackgroundCompilationService.swift is deprecated in favour of this endpoint.
// The iOS client should call POST /api/compile instead of running its own BGAppRefreshTask
// compilation pipeline (BGTaskScheduler identifier: com.daypage.daily-compilation).

function unauthorized() {
  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

function forbidden(message: string) {
  return NextResponse.json({ error: message }, { status: 403 });
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

const CompileSchema = z.union([
  z.object({ memo_ids: z.array(z.string().uuid()).min(1).max(50) }),
  z.object({
    date: z
      .string()
      .regex(/^\d{4}-\d{2}-\d{2}$/, "date must be YYYY-MM-DD"),
  }),
]);

// POST /api/compile — trigger compilation for specific memos or a day's memos
export async function POST(req: NextRequest) {
  let userId: string | null = null;

  const apiAuth = await authenticateApiKey(req);
  if (apiAuth) {
    // /api/compile mutates memos.compile_status — require the "write" scope.
    if (!hasScope(apiAuth, "write")) {
      return forbidden("API key lacks 'write' scope");
    }
    userId = apiAuth.userId;
  } else {
    const session = await auth();
    if (session?.user?.email) {
      userId = await resolveUserId(session.user.email);
    }
  }

  if (!userId) return unauthorized();

  // Rate limit per authenticated user — compile resets memo status and fans out
  // an LLM compile event per memo; cap it so it can't be driven as a cost/DoS lever.
  const rl = checkRateLimit(`compile:${userId}`, 60, 60_000);
  if (!rl.success) {
    return NextResponse.json(
      { error: "Rate limit exceeded" },
      {
        status: 429,
        headers: {
          "Retry-After": Math.ceil((rl.reset - Date.now()) / 1000).toString(),
          "X-RateLimit-Remaining": "0",
        },
      }
    );
  }

  const raw: unknown = await req.json().catch(() => null);
  if (!raw) return badRequest("Invalid JSON body");

  const parsed = CompileSchema.safeParse(raw);
  if (!parsed.success) {
    return badRequest(parsed.error.issues[0]?.message ?? "Validation error");
  }

  let memoIds: string[];

  if ("memo_ids" in parsed.data) {
    // Verify all IDs belong to this user
    const rows = await db
      .select({ id: memos.id })
      .from(memos)
      .where(
        and(
          eq(memos.user_id, userId),
          inArray(memos.id, parsed.data.memo_ids)
        )
      );
    memoIds = rows.map((r) => r.id);

    if (memoIds.length === 0) {
      return badRequest("No matching memos found for the provided IDs");
    }
  } else {
    // Resolve by the user's IANA timezone; UTC calendar slicing is incorrect for
    // most users and across DST transitions.
    const timezone = await readUserTimezone(userId);
    const date = zonedLocalDateTimeToUtc(parsed.data.date, "00:00", timezone);
    const nextDay = zonedLocalDateTimeToUtc(addCalendarDays(parsed.data.date, 1), "00:00", timezone);

    const rows = await db
      .select({ id: memos.id })
      .from(memos)
      .where(
        and(
          eq(memos.user_id, userId),
          gte(memos.created_at, date),
          lt(memos.created_at, nextDay)
        )
      );
    memoIds = rows.map((r) => r.id);

    if (memoIds.length === 0) {
      return NextResponse.json(
        { triggered: 0, memo_ids: [], message: "No memos found for that date" },
        { status: 200 }
      );
    }
  }

  // Reset compile_status to pending and fire memo/created event for each
  await db
    .update(memos)
    .set({ compile_status: "pending", compile_error: null })
    .where(inArray(memos.id, memoIds));

  const memoRows = await db
    .select({ id: memos.id, sync_revision: memos.sync_revision, sync_change_sequence: memos.sync_change_sequence })
    .from(memos)
    .where(and(eq(memos.user_id, userId), inArray(memos.id, memoIds)));
  for (const memo of memoRows) {
    if (isAgentDataPlaneEnabled()) {
      await enqueueUniqueDataPlaneJob({
        userId,
        type: "memo.synced",
        payload: {
          memo_id: memo.id,
          accepted_revision: memo.sync_revision > 0 ? memo.sync_revision : memo.sync_change_sequence,
          explicit_retry: true,
        },
        idempotencyKey: `manual-recompile:${userId}:${memo.id}:${randomUUID()}`,
      });
    }
    if (shouldRunLegacyCompiler()) {
      await sendEvent({ name: "memo/created", data: { memo_id: memo.id } });
    }
  }

  // Return the associated compiled pages if they already exist
  const compiledPages = await db
    .select({
      id: pages.id,
      slug: pages.slug,
      title: pages.title,
      type: pages.type,
      status: pages.status,
      last_compiled_at: pages.last_compiled_at,
    })
    .from(pages)
    .where(
      and(
        eq(pages.user_id, userId),
        sql`${pages.metadata}->>'source_memo_id' = ANY(${sql`ARRAY[${sql.join(memoIds.map((id) => sql`${id}`), sql`, `)}]::text[]`})`
      )
    )
    .limit(50);

  return NextResponse.json(
    {
      triggered: memoIds.length,
      memo_ids: memoIds,
      pages: compiledPages,
    },
    { status: 202 }
  );
}
