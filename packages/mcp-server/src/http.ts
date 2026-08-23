import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AuthInfo } from "@modelcontextprotocol/sdk/server/auth/types.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import type { DayPageAuthContext } from "./auth.js";
import { AuthenticationError, createTokenVerifier } from "./auth.js";
import type { DayPageMcpConfig } from "./config.js";
import { createDayPageMcpServer } from "./mcp.js";
import type { DayPageRepository } from "./repository.js";
import { createSupabaseRepository } from "./repository.js";

export interface HttpDependencies {
  verifyToken: (token: string) => Promise<DayPageAuthContext>;
  createRepository: (auth: DayPageAuthContext) => DayPageRepository;
}

class FixedWindowRateLimiter {
  private readonly buckets = new Map<string, { count: number; resetAt: number }>();

  constructor(private readonly limit: number) {}

  take(key: string, now = Date.now()): { allowed: boolean; retryAfterSeconds: number } {
    const existing = this.buckets.get(key);
    if (!existing || existing.resetAt <= now) {
      this.buckets.set(key, { count: 1, resetAt: now + 60_000 });
      return { allowed: true, retryAfterSeconds: 0 };
    }
    if (existing.count >= this.limit) {
      return { allowed: false, retryAfterSeconds: Math.max(1, Math.ceil((existing.resetAt - now) / 1000)) };
    }
    existing.count += 1;
    return { allowed: true, retryAfterSeconds: 0 };
  }
}

function setCommonHeaders(response: ServerResponse): void {
  response.setHeader("Cache-Control", "no-store");
  response.setHeader("X-Content-Type-Options", "nosniff");
  response.setHeader("Referrer-Policy", "no-referrer");
}

function sendJson(response: ServerResponse, status: number, body: unknown, headers: Record<string, string> = {}): void {
  setCommonHeaders(response);
  response.writeHead(status, { "Content-Type": "application/json; charset=utf-8", ...headers });
  response.end(JSON.stringify(body));
}

function protectedResourceMetadata(config: DayPageMcpConfig) {
  return {
    resource: config.resource,
    resource_name: "DayPage Cloud MCP",
    authorization_servers: [config.authorizationServer],
    bearer_methods_supported: ["header"],
    scopes_supported: ["openid", "email", "profile"],
    resource_documentation: `${config.appBaseUrl}/docs/mcp`,
  };
}

function metadataPath(config: DayPageMcpConfig): string {
  const resourcePath = new URL(config.resource).pathname.replace(/^\//, "");
  return resourcePath ? `/.well-known/oauth-protected-resource/${resourcePath}` : "/.well-known/oauth-protected-resource";
}

function challenge(config: DayPageMcpConfig): string {
  const metadataUrl = new URL(metadataPath(config), config.resource).toString();
  return `Bearer resource_metadata="${metadataUrl}", scope="openid email profile"`;
}

function bearerToken(request: IncomingMessage): string | null {
  const raw = request.headers.authorization;
  if (!raw) return null;
  const match = /^Bearer\s+(.+)$/i.exec(raw.trim());
  return match?.[1]?.trim() || null;
}

async function readJsonBody(request: IncomingMessage, limitBytes: number): Promise<unknown> {
  const chunks: Buffer[] = [];
  let total = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    total += buffer.length;
    if (total > limitBytes) throw new Error("request body too large");
    chunks.push(buffer);
  }
  if (total === 0) throw new Error("request body is empty");
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function requestPath(request: IncomingMessage): string {
  return new URL(request.url || "/", "http://localhost").pathname;
}

export function createDayPageHttpServer(
  config: DayPageMcpConfig,
  dependencies: HttpDependencies = {
    verifyToken: createTokenVerifier(config),
    createRepository: (auth) => createSupabaseRepository(config, auth),
  },
): Server {
  const limiter = new FixedWindowRateLimiter(config.requestsPerMinute);
  const mcpPath = new URL(config.resource).pathname || "/mcp";

  return createServer(async (request, response) => {
    setCommonHeaders(response);
    const path = requestPath(request);

    if (request.method === "GET" && (path === "/.well-known/oauth-protected-resource" || path === metadataPath(config))) {
      sendJson(response, 200, protectedResourceMetadata(config));
      return;
    }
    if (request.method === "GET" && path === "/healthz") {
      sendJson(response, 200, { status: "ok", service: "daypage-cloud-mcp" });
      return;
    }
    if (path !== mcpPath) {
      sendJson(response, 404, { error: "Not found" });
      return;
    }
    if (request.method === "OPTIONS") {
      response.writeHead(204, { Allow: "POST, GET, DELETE, OPTIONS" });
      response.end();
      return;
    }

    const token = bearerToken(request);
    if (!token) {
      sendJson(response, 401, { error: "Bearer access token required" }, { "WWW-Authenticate": challenge(config) });
      return;
    }

    let auth: DayPageAuthContext;
    try {
      auth = await dependencies.verifyToken(token);
    } catch (error) {
      const message = error instanceof AuthenticationError ? error.message : "Invalid access token";
      sendJson(response, 401, { error: message }, { "WWW-Authenticate": challenge(config) });
      return;
    }

    const rate = limiter.take(`${auth.subject}:${auth.clientId}`);
    if (!rate.allowed) {
      sendJson(response, 429, { error: "Rate limit exceeded" }, { "Retry-After": String(rate.retryAfterSeconds) });
      return;
    }

    const repository = dependencies.createRepository(auth);
    let grant;
    try {
      grant = await repository.getGrant(auth.clientId);
    } catch {
      sendJson(response, 503, { error: "Authorization grant lookup unavailable" });
      return;
    }
    if (!grant.canRead) {
      sendJson(response, 403, { error: "This OAuth client has no active DayPage read grant" });
      return;
    }

    if (request.method !== "POST") {
      sendJson(response, 405, { error: "Method not allowed" }, { Allow: "POST" });
      return;
    }

    let body: unknown;
    try {
      body = await readJsonBody(request, config.requestBodyLimitBytes);
    } catch (error) {
      const tooLarge = error instanceof Error && error.message === "request body too large";
      sendJson(response, tooLarge ? 413 : 400, {
        jsonrpc: "2.0",
        id: null,
        error: { code: -32700, message: tooLarge ? "Request body too large" : "Invalid JSON body" },
      });
      return;
    }

    const authInfo: AuthInfo = {
      token,
      clientId: auth.clientId,
      scopes: auth.grantedScopes,
      expiresAt: auth.expiresAt,
      resource: new URL(config.resource),
      extra: { subject: auth.subject, canWrite: grant.canWrite },
    };
    const authenticatedRequest = request as IncomingMessage & { auth?: AuthInfo };
    authenticatedRequest.auth = authInfo;

    const mcpServer = createDayPageMcpServer(config, auth, grant, repository);
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: undefined,
      enableJsonResponse: true,
    });

    try {
      await mcpServer.connect(transport);
      await transport.handleRequest(authenticatedRequest, response, body);
    } catch {
      if (!response.headersSent) {
        sendJson(response, 500, {
          jsonrpc: "2.0",
          id: null,
          error: { code: -32603, message: "Internal MCP server error" },
        });
      }
    } finally {
      await transport.close().catch(() => undefined);
      await mcpServer.close().catch(() => undefined);
    }
  });
}

export { metadataPath, protectedResourceMetadata };
