import { NextResponse } from "next/server";
import { and, eq, inArray, isNull } from "drizzle-orm";
import { z } from "zod";
import { currentApiUserId } from "@/lib/auth/api-user";
import { db } from "@/lib/db/client";
import {
  agent_skill_bindings,
  agent_tool_bindings,
  agents,
  skill_versions,
  tool_connections,
  tool_definitions,
} from "@/lib/db/schema";
import { ensureBuiltInRegistry } from "@/lib/agent-data-plane/registry";

type Context = { params: Promise<{ id: string }> };

const BodySchema = z.object({
  skills: z
    .array(
      z.object({
        key: z.string().min(1).max(100),
        version: z.string().min(1).max(50),
        enabled: z.boolean().optional(),
        priority: z.number().int().min(-100).max(100).optional(),
        config: z.record(z.string(), z.unknown()).optional(),
      }),
    )
    .max(100),
  tools: z
    .array(
      z.object({
        key: z.string().min(1).max(200),
        connection_id: z.string().uuid().nullable().optional(),
        approval: z.enum(["auto", "confirm", "forbidden"]).nullable().optional(),
        enabled: z.boolean().optional(),
      }),
    )
    .max(100),
});

async function ownAgent(userId: string, id: string) {
  return (
    await db
      .select({ id: agents.id })
      .from(agents)
      .where(and(eq(agents.id, id), eq(agents.user_id, userId)))
      .limit(1)
  )[0];
}

export async function GET(_request: Request, context: Context) {
  const userId = await currentApiUserId();
  if (!userId) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  const { id } = await context.params;
  if (!(await ownAgent(userId, id))) return NextResponse.json({ error: "Agent not found" }, { status: 404 });
  const [skills, tools] = await Promise.all([
    db
      .select({ binding: agent_skill_bindings, key: skill_versions.key, version: skill_versions.version })
      .from(agent_skill_bindings)
      .innerJoin(skill_versions, eq(agent_skill_bindings.skill_version_id, skill_versions.id))
      .where(eq(agent_skill_bindings.agent_id, id)),
    db
      .select({ binding: agent_tool_bindings, definition: tool_definitions })
      .from(agent_tool_bindings)
      .innerJoin(tool_definitions, eq(agent_tool_bindings.tool_key, tool_definitions.key))
      .where(eq(agent_tool_bindings.agent_id, id)),
  ]);
  return NextResponse.json({ skills, tools });
}

export async function PUT(request: Request, context: Context) {
  const userId = await currentApiUserId();
  if (!userId) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  const { id } = await context.params;
  if (!(await ownAgent(userId, id))) return NextResponse.json({ error: "Agent not found" }, { status: 404 });
  const parsed = BodySchema.safeParse(await request.json().catch(() => null));
  if (!parsed.success) {
    return NextResponse.json({ error: "Invalid bindings", details: parsed.error.flatten() }, { status: 400 });
  }
  await ensureBuiltInRegistry();
  const skills = parsed.data.skills.length
    ? await db
        .select()
        .from(skill_versions)
        .where(
          and(
            inArray(skill_versions.key, parsed.data.skills.map((item) => item.key)),
            eq(skill_versions.status, "active"),
          ),
        )
    : [];
  const skillByKeyVersion = new Map(skills.map((skill) => [`${skill.key}@${skill.version}`, skill]));
  if (parsed.data.skills.some((item) => !skillByKeyVersion.has(`${item.key}@${item.version}`))) {
    return NextResponse.json({ error: "One or more Skill versions do not exist" }, { status: 400 });
  }
  const definitions = parsed.data.tools.length
    ? await db
        .select()
        .from(tool_definitions)
        .where(inArray(tool_definitions.key, parsed.data.tools.map((item) => item.key)))
    : [];
  const definitionKeys = new Set(definitions.map((definition) => definition.key));
  if (parsed.data.tools.some((item) => !definitionKeys.has(item.key))) {
    return NextResponse.json({ error: "One or more Tools do not exist" }, { status: 400 });
  }
  const connectionIds = parsed.data.tools.flatMap((item) => (item.connection_id ? [item.connection_id] : []));
  if (connectionIds.length) {
    const owned = await db
      .select({ id: tool_connections.id })
      .from(tool_connections)
      .where(
        and(
          eq(tool_connections.user_id, userId),
          eq(tool_connections.status, "active"),
          isNull(tool_connections.revoked_at),
          inArray(tool_connections.id, connectionIds),
        ),
      );
    if (owned.length !== new Set(connectionIds).size) {
      return NextResponse.json({ error: "A Tool connection is missing or revoked" }, { status: 400 });
    }
  }

  await db.transaction(async (tx) => {
    await tx.delete(agent_skill_bindings).where(eq(agent_skill_bindings.agent_id, id));
    await tx.delete(agent_tool_bindings).where(eq(agent_tool_bindings.agent_id, id));
    if (parsed.data.skills.length) {
      await tx.insert(agent_skill_bindings).values(
        parsed.data.skills.map((item) => ({
          agent_id: id,
          skill_version_id: skillByKeyVersion.get(`${item.key}@${item.version}`)!.id,
          enabled: item.enabled ?? true,
          priority: item.priority ?? 0,
          config: item.config ?? {},
        })),
      );
    }
    if (parsed.data.tools.length) {
      await tx.insert(agent_tool_bindings).values(
        parsed.data.tools.map((item) => ({
          agent_id: id,
          tool_key: item.key,
          connection_id: item.connection_id ?? null,
          approval_override: item.approval ?? null,
          enabled: item.enabled ?? true,
        })),
      );
    }
  });
  return GET(request, context);
}
