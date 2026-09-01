import { NextResponse } from "next/server";
import { ZodError } from "zod";
import { currentApiUserId } from "@/lib/auth/api-user";
import { RecordFeedbackSchema } from "@/lib/evaluation/contracts";
import { recordAgentFeedback } from "@/lib/evaluation/feedback";

export const runtime = "nodejs";

type Context = { params: Promise<{ id: string }> };

export async function POST(request: Request, context: Context) {
  const userId = await currentApiUserId();
  if (!userId) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  const { id } = await context.params;
  const parsed = RecordFeedbackSchema.safeParse(await request.json().catch(() => null));
  if (!parsed.success) {
    return NextResponse.json(
      { error: "Invalid feedback event", details: parsed.error.flatten() },
      { status: 400 },
    );
  }

  try {
    const feedback = await recordAgentFeedback({ userId, runId: id, feedback: parsed.data });
    return NextResponse.json({ feedback }, { status: 201 });
  } catch (error) {
    if (error instanceof ZodError) {
      return NextResponse.json(
        { error: "Invalid feedback event", details: error.flatten() },
        { status: 400 },
      );
    }
    const message = error instanceof Error ? error.message : String(error);
    const status = /not found|does not belong/i.test(message) ? 404 : 400;
    return NextResponse.json({ error: message }, { status });
  }
}
