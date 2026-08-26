declare const Deno: {
  env: { get(name: string): string | undefined };
};

function required(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value.replace(/\/$/, "");
}

const runtimeSupabaseUrl = required("SUPABASE_URL");
const publicSupabaseUrl = Deno.env.get("DAYPAGE_PUBLIC_SUPABASE_URL")?.trim().replace(/\/$/, "")
  || runtimeSupabaseUrl;
const MCP_RESOURCE = Deno.env.get("DAYPAGE_MCP_RESOURCE")?.trim().replace(/\/$/, "")
  || `${publicSupabaseUrl}/functions/v1/daypage-mcp`;
const OAUTH_CONSENT_URL = required("DAYPAGE_OAUTH_CONSENT_URL");

const jsonHeaders = {
  "cache-control": "no-store",
  "content-type": "application/json; charset=utf-8",
  "referrer-policy": "no-referrer",
  "x-content-type-options": "nosniff",
};

function docs(): Response {
  return new Response(JSON.stringify({
    name: "DayPage Cloud MCP",
    resource: MCP_RESOURCE,
    transport: "Streamable HTTP",
    authentication: "OAuth 2.1 with PKCE and Dynamic Client Registration",
    default_access: "read-only",
    authorization_ui: OAUTH_CONSENT_URL,
    tools: ["daypage_list_recent", "daypage_search", "daypage_get_memo", "daypage_get_page"],
  }, null, 2), { headers: jsonHeaders });
}

Deno.serve((request) => {
  if (request.method !== "GET") return new Response("Method not allowed", { status: 405 });
  const url = new URL(request.url);
  if (url.pathname.endsWith("/healthz")) {
    return new Response(JSON.stringify({ status: "ok", service: "daypage-oauth" }), {
      headers: jsonHeaders,
    });
  }
  if (url.pathname.endsWith("/docs/mcp")) return docs();
  if (url.pathname.endsWith("/consent")) {
    const consent = new URL(OAUTH_CONSENT_URL);
    consent.search = url.search;
    return Response.redirect(consent, 302);
  }
  return new Response("Not found", { status: 404 });
});
