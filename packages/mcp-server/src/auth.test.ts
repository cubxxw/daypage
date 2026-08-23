import assert from "node:assert/strict";
import test from "node:test";
import type { JwtPayload } from "@supabase/supabase-js";
import { AuthenticationError, validateClaims } from "./auth.js";
import type { DayPageMcpConfig } from "./config.js";

const config: DayPageMcpConfig = {
  host: "127.0.0.1",
  port: 43119,
  supabaseUrl: "https://example.supabase.co",
  supabaseAnonKey: "anon",
  issuer: "https://example.supabase.co/auth/v1",
  authorizationServer: "https://example.supabase.co/auth/v1",
  resource: "https://mcp.daypage.example/mcp",
  appBaseUrl: "https://daypage.example",
  requestBodyLimitBytes: 1024,
  requestsPerMinute: 60,
};

function claims(overrides: Partial<JwtPayload> = {}): JwtPayload {
  return {
    iss: config.issuer,
    sub: "11111111-1111-1111-1111-111111111111",
    aud: ["authenticated", config.resource],
    exp: Math.floor(Date.now() / 1000) + 600,
    iat: Math.floor(Date.now() / 1000),
    role: "authenticated",
    aal: "aal1",
    session_id: "22222222-2222-2222-2222-222222222222",
    client_id: "codex-test-client",
    scope: "openid email profile",
    ...overrides,
  };
}

test("validateClaims accepts a resource-bound OAuth token", () => {
  const auth = validateClaims(config, "secret-token", claims());
  assert.equal(auth.subject, "11111111-1111-1111-1111-111111111111");
  assert.equal(auth.clientId, "codex-test-client");
  assert.deepEqual(auth.grantedScopes, ["openid", "email", "profile"]);
});

test("validateClaims rejects a token for another resource", () => {
  assert.throws(
    () => validateClaims(config, "secret-token", claims({ aud: "authenticated" })),
    (error: unknown) => error instanceof AuthenticationError && /not intended/.test(error.message),
  );
});

test("validateClaims rejects normal app sessions without an OAuth client", () => {
  assert.throws(
    () => validateClaims(config, "secret-token", claims({ client_id: undefined })),
    (error: unknown) => error instanceof AuthenticationError && /client_id/.test(error.message),
  );
});
