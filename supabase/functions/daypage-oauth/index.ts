const STAGING_PROJECT_URL = "https://gcukhewnszjrwfzhxctn.supabase.co";
const STAGING_CONSENT_URL = "https://getyak.github.io/daypage/oauth/consent/";
const MCP_RESOURCE = `${STAGING_PROJECT_URL}/functions/v1/daypage-mcp`;

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
    authorization_ui: STAGING_CONSENT_URL,
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
    const consent = new URL(STAGING_CONSENT_URL);
    consent.search = url.search;
    return Response.redirect(consent, 302);
  }
  return new Response("Not found", { status: 404 });
});
