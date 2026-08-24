import assert from "node:assert/strict";
import test from "node:test";
import type { JwtPayload } from "@supabase/supabase-js";
import { AuthenticationError, createApiKeyVerifier, isDayPageApiKey, validateClaims } from "./auth.js";
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
  assert.equal(auth.authType, "oauth");
});

test("API key verifier resolves a prefixed PAT without storing its raw value", async () => {
  const token = `dpg_stg_${"a".repeat(43)}`;
  let receivedHash = "";
  const verify = createApiKeyVerifier(config, {
    async resolve(keyHash) {
      receivedHash = keyHash;
      return {
        key_id: "33333333-3333-4333-8333-333333333333",
        user_id: "11111111-1111-1111-1111-111111111111",
        scopes: ["read"],
        can_read: true,
        can_write: false,
        expires_at: null,
      };
    },
  });

  const auth = await verify(token);
  assert.equal(auth.authType, "api_key");
  assert.equal(auth.subject, "11111111-1111-1111-1111-111111111111");
  assert.equal(auth.apiKey?.canRead, true);
  assert.notEqual(receivedHash, token);
  assert.match(receivedHash, /^[a-f0-9]{64}$/);
});

test("API key detection keeps existing 64-character DayPage keys compatible", () => {
  assert.equal(isDayPageApiKey(`dpg_live_${"z".repeat(43)}`), true);
  assert.equal(isDayPageApiKey("a".repeat(64)), true);
  assert.equal(isDayPageApiKey("eyJhbGciOiJSUzI1NiJ9.payload.signature"), false);
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
