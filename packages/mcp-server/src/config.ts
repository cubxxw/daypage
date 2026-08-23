export interface DayPageMcpConfig {
  host: string;
  port: number;
  supabaseUrl: string;
  supabaseAnonKey: string;
  issuer: string;
  authorizationServer: string;
  resource: string;
  appBaseUrl: string;
  requestBodyLimitBytes: number;
  requestsPerMinute: number;
}

function required(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function normalizedUrl(value: string, name: string): string {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error(`${name} must be an absolute URL`);
  }
  if (url.hash || url.username || url.password) {
    throw new Error(`${name} must not contain credentials or a fragment`);
  }
  return url.toString().replace(/\/$/, "");
}

function positiveInteger(value: string | undefined, fallback: number, name: string): number {
  if (!value?.trim()) return fallback;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  return parsed;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): DayPageMcpConfig {
  const supabaseUrl = normalizedUrl(required(env, "SUPABASE_URL"), "SUPABASE_URL");
  const resource = normalizedUrl(required(env, "DAYPAGE_MCP_RESOURCE"), "DAYPAGE_MCP_RESOURCE");
  const resourceUrl = new URL(resource);
  if (resourceUrl.protocol !== "https:" && resourceUrl.hostname !== "127.0.0.1" && resourceUrl.hostname !== "localhost") {
    throw new Error("DAYPAGE_MCP_RESOURCE must use https outside localhost");
  }

  return {
    host: env.HOST?.trim() || "0.0.0.0",
    port: positiveInteger(env.PORT, 43119, "PORT"),
    supabaseUrl,
    supabaseAnonKey: required(env, "SUPABASE_ANON_KEY"),
    issuer: normalizedUrl(env.DAYPAGE_MCP_ISSUER?.trim() || `${supabaseUrl}/auth/v1`, "DAYPAGE_MCP_ISSUER"),
    authorizationServer: normalizedUrl(
      env.DAYPAGE_AUTHORIZATION_SERVER?.trim() || `${supabaseUrl}/auth/v1`,
      "DAYPAGE_AUTHORIZATION_SERVER",
    ),
    resource,
    appBaseUrl: normalizedUrl(env.DAYPAGE_APP_URL?.trim() || resourceUrl.origin, "DAYPAGE_APP_URL"),
    requestBodyLimitBytes: positiveInteger(env.DAYPAGE_MCP_BODY_LIMIT_BYTES, 1_048_576, "DAYPAGE_MCP_BODY_LIMIT_BYTES"),
    requestsPerMinute: positiveInteger(env.DAYPAGE_MCP_REQUESTS_PER_MINUTE, 60, "DAYPAGE_MCP_REQUESTS_PER_MINUTE"),
  };
}
