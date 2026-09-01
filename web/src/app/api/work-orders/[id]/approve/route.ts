import { NextResponse } from "next/server";
import { currentApiUserId } from "@/lib/auth/api-user";
import { approveWorkOrder } from "@/lib/agent-data-plane/tools";

type Context = { params: Promise<{ id: string }> };

export async function POST(_request: Request, context: Context) {
  const userId = await currentApiUserId();
  if (!userId) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  const { id } = await context.params;
  try {
    return NextResponse.json(await approveWorkOrder(id, userId));
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 409 });
  }
}
