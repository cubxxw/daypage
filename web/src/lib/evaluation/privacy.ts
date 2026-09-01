import { sha256 } from "@/lib/agent-data-plane/hash";
import type { EvaluationExportMode } from "./config";

const EMAIL = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi;
const PHONE = /(?<!\d)(?:\+?\d[\d\s().-]{6,}\d)(?!\d)/g;
const URL_CREDENTIALS = /(https?:\/\/)([^\s/@:]+):([^\s/@]+)@/gi;
const SECRET_KEYS = /(?:authorization|api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|cookie|credential)/i;

export function pseudonymizeUser(userId: string, salt: string): string {
  return sha256(`${salt}:${userId}`).slice("sha256:".length, "sha256:".length + 24);
}
export function redactText(value: string): string {
  return value
    .replace(URL_CREDENTIALS, "$1[REDACTED]@")
    .replace(EMAIL, "[EMAIL]")
    .replace(PHONE, "[PHONE]");
}

export function scrubEvaluationValue(value: unknown, mode: EvaluationExportMode): unknown {
  if (mode === "metadata_only") return undefined;
  if (typeof value === "string") {
    return mode === "redacted" ? redactText(value).slice(0, 20_000) : value.slice(0, 100_000);
  }
  if (Array.isArray(value)) {
    return value.slice(0, 100).map((item) => scrubEvaluationValue(item, mode));
  }
  if (value && typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>)
      .filter(([key]) => !SECRET_KEYS.test(key))
      .slice(0, 200)
      .map(([key, child]) => [key, scrubEvaluationValue(child, mode)]);
    return Object.fromEntries(entries);
  }
  return value;
}
