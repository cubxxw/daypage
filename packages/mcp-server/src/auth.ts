import { createClient, type JwtPayload } from "@supabase/supabase-js";
import type { DayPageMcpConfig } from "./config.js";

export interface DayPageAuthContext {
  token: string;
  subject: string;
  clientId: string;
  expiresAt: number;
  grantedScopes: string[];
  claims: JwtPayload;
  authType: "oauth" | "api_key";
  apiKey?: {
    id: string;
    hash: string;
    canRead: boolean;
    canWrite: boolean;
  };
}

export class AuthenticationError extends Error {
  constructor(message = "Invalid access token") {
    super(message);
    this.name = "AuthenticationError";
  }
}

export interface ClaimsReader {
  getClaims(token: string): Promise<JwtPayload>;
}

export interface ApiKeyRecord {
  key_id: string;
  user_id: string;
  scopes: string[];
  can_read: boolean;
  can_write: boolean;
  expires_at: string | null;
}

export interface ApiKeyReader {
  resolve(keyHash: string): Promise<ApiKeyRecord>;
}

function audienceValues(audience: string | string[]): string[] {
  return Array.isArray(audience) ? audience : [audience];
}

function parseScopes(claims: JwtPayload): string[] {
  const raw = claims.scope;
  if (typeof raw !== "string") return [];
  return raw.split(/\s+/).map((scope) => scope.trim()).filter(Boolean);
}

export function validateClaims(
  config: DayPageMcpConfig,
  token: string,
  claims: JwtPayload,
  nowSeconds = Math.floor(Date.now() / 1000),
): DayPageAuthContext {
  if (claims.iss !== config.issuer) throw new AuthenticationError("Unexpected token issuer");
  if (!audienceValues(claims.aud).includes(config.resource)) {
    throw new AuthenticationError("Token is not intended for this MCP resource");
  }
  if (!claims.sub?.trim()) throw new AuthenticationError("Token subject is missing");
  if (!Number.isFinite(claims.exp) || claims.exp <= nowSeconds) {
    throw new AuthenticationError("Access token has expired");
  }
  if (claims.role !== "authenticated") throw new AuthenticationError("Authenticated role is required");

  const clientId = typeof claims.client_id === "string" ? claims.client_id.trim() : "";
  if (!clientId) throw new AuthenticationError("OAuth client_id claim is required");

  return {
    token,
    subject: claims.sub,
    clientId,
    expiresAt: claims.exp,
    grantedScopes: parseScopes(claims),
    claims,
    authType: "oauth",
  };
}

export function createSupabaseClaimsReader(config: DayPageMcpConfig): ClaimsReader {
  const client = createClient(config.supabaseUrl, config.supabaseAnonKey, {
    auth: { autoRefreshToken: false, detectSessionInUrl: false, persistSession: false },
  });

  return {
    async getClaims(token: string): Promise<JwtPayload> {
      const { data, error } = await client.auth.getClaims(token);
      if (error || !data?.claims) throw new AuthenticationError();
      return data.claims;
    },
  };
}

export function createTokenVerifier(
  config: DayPageMcpConfig,
  reader: ClaimsReader = createSupabaseClaimsReader(config),
): (token: string) => Promise<DayPageAuthContext> {
  return async (token: string) => validateClaims(config, token, await reader.getClaims(token));
}

export function isDayPageApiKey(token: string): boolean {
  return /^dpg_(?:stg|live|dev)_[A-Za-z0-9_-]{32,128}$/.test(token)
    || /^[a-f0-9]{64}$/i.test(token);
}

async function sha256Hex(value: string): Promise<string> {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(bytes)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function createSupabaseApiKeyReader(config: DayPageMcpConfig): ApiKeyReader {
  const client = createClient(config.supabaseUrl, config.supabaseAnonKey, {
    auth: { autoRefreshToken: false, detectSessionInUrl: false, persistSession: false },
  });

  return {
    async resolve(keyHash: string): Promise<ApiKeyRecord> {
      const { data, error } = await client.rpc("daypage_mcp_api_key_request", {
        p_key_hash: keyHash,
        p_operation: "resolve",
        p_arguments: {},
      });
      if (error || !data || typeof data !== "object" || Array.isArray(data)) {
        throw new AuthenticationError("Invalid or expired DayPage API key");
      }
      const record = data as unknown as ApiKeyRecord;
      if (!record.key_id || !record.user_id || !Array.isArray(record.scopes)) {
        throw new AuthenticationError("Invalid DayPage API key response");
      }
      return record;
    },
  };
}

export function createApiKeyVerifier(
  config: DayPageMcpConfig,
  reader: ApiKeyReader = createSupabaseApiKeyReader(config),
): (token: string) => Promise<DayPageAuthContext> {
  return async (token: string) => {
    if (!isDayPageApiKey(token)) throw new AuthenticationError("Invalid DayPage API key format");
    const hash = await sha256Hex(token);
    const record = await reader.resolve(hash);
    const expiresAt = record.expires_at
      ? Math.floor(new Date(record.expires_at).getTime() / 1000)
      : 2_147_483_647;
    if (!Number.isFinite(expiresAt) || expiresAt <= Math.floor(Date.now() / 1000)) {
      throw new AuthenticationError("DayPage API key has expired");
    }
    const clientId = `daypage-pat:${record.key_id}`;
    return {
      token,
      subject: record.user_id,
      clientId,
      expiresAt,
      grantedScopes: record.scopes,
      claims: {
        iss: "daypage-api-key",
        sub: record.user_id,
        aud: config.resource,
        exp: expiresAt,
        iat: Math.floor(Date.now() / 1000),
        role: "authenticated",
        aal: "aal1",
        session_id: record.key_id,
        client_id: clientId,
      },
      authType: "api_key",
      apiKey: {
        id: record.key_id,
        hash,
        canRead: record.can_read,
        canWrite: record.can_write,
      },
    };
  };
}

export function createCredentialVerifier(config: DayPageMcpConfig): (token: string) => Promise<DayPageAuthContext> {
  const verifyOAuth = createTokenVerifier(config);
  const verifyApiKey = createApiKeyVerifier(config);
  return (token: string) => isDayPageApiKey(token) ? verifyApiKey(token) : verifyOAuth(token);
}
