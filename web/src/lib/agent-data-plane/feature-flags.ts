export type AgentDataPlaneMode = "off" | "shadow" | "primary";

export function agentDataPlaneMode(): AgentDataPlaneMode {
  const value = process.env.AGENT_DATA_PLANE_MODE?.trim().toLowerCase();
  if (value === "off" || value === "shadow" || value === "primary") return value;
  // Rollout-safe default: collect run/receipt/artifact evidence without changing
  // canonical pages until an environment explicitly opts into the primary path.
  return "shadow";
}

export function isAgentDataPlaneEnabled(): boolean {
  return agentDataPlaneMode() !== "off";
}

export function shouldRunLegacyCompiler(): boolean {
  const override = process.env.LEGACY_MEMO_COMPILER_ENABLED;
  if (override === "1" || override === "true") return true;
  if (override === "0" || override === "false") return false;
  return agentDataPlaneMode() !== "primary";
}

export function shouldWriteCanonicalArtifacts(): boolean {
  return agentDataPlaneMode() === "primary";
}
