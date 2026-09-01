import "server-only";
import fs from "node:fs";
import path from "node:path";
import { and, desc, eq, ne } from "drizzle-orm";
import { db } from "@/lib/db/client";
import { skill_versions, tool_definitions } from "@/lib/db/schema";
import { hashJson, sha256 } from "./hash";

export type BuiltInSkillKey =
  | "memo-understand"
  | "page-reconcile"
  | "daily-synthesize"
  | "weekly-review"
  | "action-plan";

const SKILLS = [
  {
    key: "memo-understand",
    version: "2.0.0",
    description: "Route and understand one accepted memo revision, select context, emit a calibrated response, grounded observations, Memory proposals, and actions.",
    requiredTools: ["daypage.get_memo"],
    optionalTools: ["daypage.search"],
    defaultRisk: "internal_write" as const,
    implementationRef: "checked-in:agent-data-plane/memo-understand@2",
    promptPath: "src/lib/ai/prompts/memo-understand-v1.md",
    inputSchema: { type: "object", required: ["memo_id", "accepted_revision"] },
    outputSchema: { $ref: "daypage://schemas/agent-output-envelope-v2" },
  },
  {
    key: "page-reconcile",
    version: "1.0.0",
    description: "Apply grounded page patches with optimistic concurrency.",
    requiredTools: ["daypage.get_page", "daypage.write_artifact"],
    optionalTools: ["daypage.search"],
    defaultRisk: "internal_write" as const,
    implementationRef: "checked-in:agent-data-plane/page-reconcile@1",
    promptPath: null,
    inputSchema: { type: "object", required: ["artifact_id"] },
    outputSchema: { $ref: "daypage://schemas/page-reconcile-v1" },
  },
  {
    key: "daily-synthesize",
    version: "1.0.0",
    description: "Reduce memo contributions into a timezone-aware living or finalized Daily Page.",
    requiredTools: ["daypage.write_artifact"],
    optionalTools: ["daypage.get_memo"],
    defaultRisk: "internal_write" as const,
    implementationRef: "checked-in:agent-data-plane/daily-synthesize@1",
    promptPath: "src/lib/ai/prompts/daily-synthesize-v1.md",
    inputSchema: { type: "object", required: ["local_date", "timezone"] },
    outputSchema: { $ref: "daypage://schemas/daily-page-artifact-v1" },
  },
  {
    key: "weekly-review",
    version: "1.0.0",
    description: "Reduce seven bounded Daily artifacts into a review and action proposals.",
    requiredTools: ["daypage.search", "daypage.write_artifact"],
    optionalTools: ["calendar.list_events"],
    defaultRisk: "internal_write" as const,
    implementationRef: "checked-in:agent-data-plane/weekly-review@1",
    promptPath: "src/lib/ai/prompts/weekly-review-v1.md",
    inputSchema: { type: "object", required: ["week_start", "timezone"] },
    outputSchema: { $ref: "daypage://schemas/weekly-review-artifact-v1" },
  },
  {
    key: "action-plan",
    version: "1.0.0",
    description: "Turn user intent or review output into explicit work-order proposals.",
    requiredTools: [],
    optionalTools: ["calendar.create_event", "email.create_draft", "email.send"],
    defaultRisk: "external_write" as const,
    implementationRef: "checked-in:agent-data-plane/action-plan@1",
    promptPath: "src/lib/ai/prompts/action-plan-v1.md",
    inputSchema: { type: "object" },
    outputSchema: { $ref: "daypage://schemas/action-plan-v1" },
  },
] as const;

const TOOLS = [
  ["daypage.search", "daypage", "read", "auto", []],
  ["daypage.get_memo", "daypage", "read", "auto", []],
  ["daypage.get_page", "daypage", "read", "auto", []],
  ["daypage.write_artifact", "daypage", "internal_write", "auto", []],
  ["calendar.list_events", "connector", "read", "auto", ["calendar.read"]],
  ["calendar.create_event", "connector", "external_write", "confirm", ["calendar.write"]],
  ["email.search", "connector", "read", "auto", ["email.read"]],
  ["email.create_draft", "connector", "external_write", "confirm", ["email.draft"]],
  ["email.send", "connector", "external_write", "confirm", ["email.send"]],
] as const;

export async function ensureBuiltInRegistry(): Promise<void> {
  for (const definition of TOOLS) {
    const [key, source, effect, approval, scopes] = definition;
    await db
      .insert(tool_definitions)
      .values({
        key,
        source,
        effect,
        default_approval: approval,
        required_scopes: scopes,
        input_schema: { type: "object" },
        output_schema: { type: "object" },
      })
      .onConflictDoUpdate({
        target: tool_definitions.key,
        set: {
          source,
          effect,
          default_approval: approval,
          required_scopes: scopes,
          updated_at: new Date(),
        },
      });
  }

  for (const skill of SKILLS) {
    const promptChecksum = skill.promptPath
      ? sha256(fs.readFileSync(path.join(process.cwd(), skill.promptPath), "utf8"))
      : null;
    const manifest = {
      key: skill.key,
      version: skill.version,
      description: skill.description,
      inputSchema: skill.inputSchema,
      outputSchema: skill.outputSchema,
      requiredTools: skill.requiredTools,
      optionalTools: skill.optionalTools,
      defaultRisk: skill.defaultRisk,
      implementationRef: skill.implementationRef,
      promptChecksum,
    };
    const checksum = hashJson(manifest);
    await db
      .insert(skill_versions)
      .values({
        key: skill.key,
        version: skill.version,
        description: skill.description,
        manifest,
        input_schema: skill.inputSchema,
        output_schema: skill.outputSchema,
        required_tools: [...skill.requiredTools],
        optional_tools: [...skill.optionalTools],
        default_risk: skill.defaultRisk,
        implementation_ref: skill.implementationRef,
        checksum,
      })
      .onConflictDoUpdate({
        target: [skill_versions.key, skill_versions.version],
        set: {
          description: skill.description,
          manifest,
          input_schema: skill.inputSchema,
          output_schema: skill.outputSchema,
          required_tools: [...skill.requiredTools],
          optional_tools: [...skill.optionalTools],
          default_risk: skill.defaultRisk,
          implementation_ref: skill.implementationRef,
          checksum,
          status: "active",
        },
      });
    await db
      .update(skill_versions)
      .set({ status: "deprecated" })
      .where(and(eq(skill_versions.key, skill.key), ne(skill_versions.version, skill.version)));
  }
}

export async function getActiveSkill(key: BuiltInSkillKey) {
  await ensureBuiltInRegistry();
  const [skill] = await db
    .select()
    .from(skill_versions)
    .where(and(eq(skill_versions.key, key), eq(skill_versions.status, "active")))
    .orderBy(desc(skill_versions.created_at))
    .limit(1);
  if (!skill || skill.status !== "active") {
    throw new Error(`Active skill not found: ${key}`);
  }
  return skill;
}
