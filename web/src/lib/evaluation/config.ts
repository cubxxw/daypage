import "server-only";
import { z } from "zod";

export const EvaluationExportModeSchema = z.enum([
  "off",
  "metadata_only",
  "redacted",
  "full_content_opt_in",
]);

export type EvaluationExportMode = z.infer<typeof EvaluationExportModeSchema>;

export type EvaluationConfig = {
  exportMode: EvaluationExportMode;
  provider: "opik";
  apiKey: string;
  apiUrl?: string;
  projectName: string;
  workspaceName: string;
  environment: string;
  pseudonymSalt: string;
  configured: boolean;
};

export function evaluationConfig(): EvaluationConfig {
  const exportMode = EvaluationExportModeSchema.catch("off").parse(
    process.env.EVALUATION_EXPORT_MODE,
  );
  const apiKey = process.env.OPIK_API_KEY?.trim() ?? "";
  const apiUrl = process.env.OPIK_URL_OVERRIDE?.trim() || undefined;
  const projectName = process.env.OPIK_PROJECT_NAME?.trim() || "daypage-agent";
  const workspaceName = process.env.OPIK_WORKSPACE?.trim() || "default";
  const environment = process.env.OPIK_ENVIRONMENT?.trim() || process.env.NODE_ENV || "development";
  const pseudonymSalt = process.env.EVALUATION_PSEUDONYM_SALT?.trim() ?? "";
  const selfHosted = Boolean(apiUrl && !/comet\.com/i.test(apiUrl));
  const configured =
    exportMode !== "off" &&
    Boolean(projectName) &&
    Boolean(workspaceName) &&
    Boolean(pseudonymSalt) &&
    (selfHosted || Boolean(apiKey));
  return {
    exportMode,
    provider: "opik",
    apiKey,
    apiUrl,
    projectName,
    workspaceName,
    environment,
    pseudonymSalt,
    configured,
  };
}
