import type { AuthInfo } from "@modelcontextprotocol/sdk/server/auth/types.js";
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { AuthenticationError, createCredentialVerifier } from "../../../packages/mcp-server/src/auth.ts";
import type { DayPageMcpConfig } from "../../../packages/mcp-server/src/config.ts";
import { createDayPageMcpServer } from "../../../packages/mcp-server/src/mcp.ts";
import { createDayPageRepository } from "../../../packages/mcp-server/src/repository.ts";

declare const Deno: {
  env: { get(name: string): string | undefined };
};

const supabaseUrl = required("SUPABASE_URL").replace(/\/$/, "");
const resource = `${supabaseUrl}/functions/v1/daypage-mcp`;
const appBaseUrl = Deno.env.get("DAYPAGE_APP_URL")?.replace(/\/$/, "")
  ?? `${supabaseUrl}/functions/v1/daypage-oauth`;

const config: DayPageMcpConfig = {
  host: "0.0.0.0",
  port: 0,
  supabaseUrl,
  supabaseAnonKey: required("SUPABASE_ANON_KEY"),
  issuer: `${supabaseUrl}/auth/v1`,
  authorizationServer: `${supabaseUrl}/auth/v1`,
  resource,
  appBaseUrl,
  requestBodyLimitBytes: 1_048_576,
  requestsPerMinute: 60,
};

const verifyToken = createCredentialVerifier(config);
const rateBuckets = new Map<string, { count: number; resetAt: number }>();

function required(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function commonHeaders(extra: Record<string, string> = {}): Headers {
  return new Headers({
    "Access-Control-Allow-Headers": "authorization, content-type, mcp-protocol-version",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Origin": "*",
    "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    ...extra,
  });
}

function json(status: number, body: unknown, extra: Record<string, string> = {}): Response {
  const headers = commonHeaders({ "Content-Type": "application/json; charset=utf-8", ...extra });
  return new Response(JSON.stringify(body), { status, headers });
}

function metadataUrl(): string {
  return `${resource}/.well-known/oauth-protected-resource`;
}

function challenge(): string {
  return `Bearer resource_metadata="${metadataUrl()}", scope="openid email profile"`;
}

function protectedResourceMetadata() {
  return {
    resource,
    resource_name: "DayPage Cloud MCP",
    authorization_servers: [config.authorizationServer],
    bearer_methods_supported: ["header"],
    scopes_supported: ["openid", "email", "profile"],
    resource_documentation: `${appBaseUrl}/docs/mcp`,
  };
}

function bearerToken(request: Request): string | null {
  const value = request.headers.get("authorization")?.trim();
  const match = value ? /^Bearer\s+(.+)$/i.exec(value) : null;
  return match?.[1]?.trim() || null;
}

function takeRateLimit(key: string): { allowed: boolean; retryAfter: number } {
  const now = Date.now();
  const bucket = rateBuckets.get(key);
  if (!bucket || bucket.resetAt <= now) {
    rateBuckets.set(key, { count: 1, resetAt: now + 60_000 });
    return { allowed: true, retryAfter: 0 };
  }
  if (bucket.count >= config.requestsPerMinute) {
    return { allowed: false, retryAfter: Math.max(1, Math.ceil((bucket.resetAt - now) / 1000)) };
  }
  bucket.count += 1;
  return { allowed: true, retryAfter: 0 };
}

async function handle(request: Request): Promise<Response> {
  const url = new URL(request.url);
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: commonHeaders() });
  if (request.method === "GET" && url.pathname.endsWith("/daypage-mcp/healthz")) {
    return json(200, { status: "ok", service: "daypage-cloud-mcp", runtime: "supabase-edge" });
  }
  if (request.method === "GET" && url.pathname.endsWith("/daypage-mcp/.well-known/oauth-protected-resource")) {
    return json(200, protectedResourceMetadata());
  }
  // Supabase's edge runtime may expose the original gateway path or the
  // function-relative path depending on runtime generation.
  if (!url.pathname.endsWith("/daypage-mcp")) return json(404, { error: "Not found" });

  const token = bearerToken(request);
  if (!token) return json(401, { error: "Bearer access token required" }, { "WWW-Authenticate": challenge() });

  let auth;
  try {
    auth = await verifyToken(token);
  } catch (error) {
    const message = error instanceof AuthenticationError ? error.message : "Invalid access token";
    return json(401, { error: message }, { "WWW-Authenticate": challenge() });
  }

  const rate = takeRateLimit(`${auth.subject}:${auth.clientId}`);
  if (!rate.allowed) return json(429, { error: "Rate limit exceeded" }, { "Retry-After": String(rate.retryAfter) });

  const repository = createDayPageRepository(config, auth);
  let grant;
  try {
    grant = await repository.getGrant(auth.clientId);
  } catch {
    return json(503, { error: "Authorization grant lookup unavailable" });
  }
  if (!grant.canRead) return json(403, { error: "This credential has no active DayPage read permission" });
  if (request.method !== "POST") return json(405, { error: "Method not allowed" }, { Allow: "POST" });

  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(contentLength) && contentLength > config.requestBodyLimitBytes) {
    return json(413, { jsonrpc: "2.0", id: null, error: { code: -32700, message: "Request body too large" } });
  }

  let parsedBody: unknown;
  try {
    const bytes = new Uint8Array(await request.arrayBuffer());
    if (bytes.byteLength === 0 || bytes.byteLength > config.requestBodyLimitBytes) throw new Error("invalid body");
    parsedBody = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return json(400, { jsonrpc: "2.0", id: null, error: { code: -32700, message: "Invalid JSON body" } });
  }

  const authInfo: AuthInfo = {
    token,
    clientId: auth.clientId,
    scopes: auth.grantedScopes,
    expiresAt: auth.expiresAt,
    resource: new URL(resource),
    extra: { subject: auth.subject, canWrite: grant.canWrite },
  };
  const server = createDayPageMcpServer(config, auth, grant, repository);
  const transport = new WebStandardStreamableHTTPServerTransport({
    sessionIdGenerator: undefined,
    enableJsonResponse: true,
  });

  try {
    await server.connect(transport);
    const response = await transport.handleRequest(request, { parsedBody, authInfo });
    const headers = commonHeaders();
    response.headers.forEach((value, key) => headers.set(key, value));
    return new Response(response.body, { status: response.status, headers });
  } catch (error) {
    console.error("[daypage-mcp] request failed", error instanceof Error ? error.message : "unknown error");
    return json(500, { jsonrpc: "2.0", id: null, error: { code: -32603, message: "Internal MCP server error" } });
  } finally {
    await transport.close().catch(() => undefined);
    await server.close().catch(() => undefined);
  }
}

export default { fetch: handle };
