import { createClient, type JwtPayload } from "@supabase/supabase-js";
import type { DayPageMcpConfig } from "./config.js";

export interface DayPageAuthContext {
  token: string;
  subject: string;
  clientId: string;
  expiresAt: number;
  grantedScopes: string[];
  claims: JwtPayload;
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
