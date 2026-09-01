import { NextResponse } from "next/server";
import { z } from "zod";
import { currentApiUserId } from "@/lib/auth/api-user";
import { rejectWorkOrder } from "@/lib/agent-data-plane/tools";

type Context = { params: Promise<{ id: string }> };
const BodySchema = z.object({ reason: z.string().max(2_000).optional() });

export async function POST(request: Request, context: Context) {
  const userId = await currentApiUserId();
  if (!userId) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  const { id } = await context.params;
  const parsed = BodySchema.safeParse(await request.json().catch(() => ({})));
  if (!parsed.success) return NextResponse.json({ error: "Invalid rejection" }, { status: 400 });
  try {
    return NextResponse.json(await rejectWorkOrder(id, userId, parsed.data.reason));
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 409 });
  }
}
