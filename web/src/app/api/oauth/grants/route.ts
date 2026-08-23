import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function invalid(message: string) {
  return NextResponse.json({ error: message }, { status: 400 });
}

async function authenticatedClient() {
  const supabase = await createClient();
  const { data: { user }, error } = await supabase.auth.getUser();
  return { supabase, user: error ? null : user };
}

export async function GET() {
  const { supabase, user } = await authenticatedClient();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const [oauthResult, grantResult] = await Promise.all([
    supabase.auth.oauth.listGrants(),
    supabase
      .from("mcp_client_grants")
      .select("client_id,can_read,can_write,created_at,updated_at,revoked_at")
      .eq("user_id", user.id),
  ]);

  if (oauthResult.error) {
    return NextResponse.json({ error: "OAuth grants are unavailable" }, { status: 503 });
  }
  if (grantResult.error) {
    return NextResponse.json({ error: "DayPage grants are unavailable" }, { status: 503 });
  }

  const daypageGrants = new Map((grantResult.data ?? []).map((grant) => [grant.client_id, grant]));
  const connections = (oauthResult.data ?? []).map((oauthGrant) => {
    const grant = daypageGrants.get(oauthGrant.client.id);
    return {
      client: oauthGrant.client,
      scopes: oauthGrant.scopes,
      granted_at: oauthGrant.granted_at,
      can_read: grant?.can_read === true && !grant.revoked_at,
      can_write: grant?.can_write === true && !grant.revoked_at,
      daypage_grant_active: Boolean(grant && !grant.revoked_at),
    };
  });

  return NextResponse.json({
    connections,
    mcp_url: process.env.DAYPAGE_MCP_RESOURCE ?? null,
  });
}

export async function PATCH(request: NextRequest) {
  const { supabase, user } = await authenticatedClient();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const body = await request.json().catch(() => null) as { client_id?: unknown; can_write?: unknown } | null;
  const clientId = typeof body?.client_id === "string" ? body.client_id.trim() : "";
  if (!clientId || clientId.length > 200 || typeof body?.can_write !== "boolean") {
    return invalid("client_id and can_write are required");
  }

  const { data, error } = await supabase
    .from("mcp_client_grants")
    .update({ can_write: body.can_write, updated_at: new Date().toISOString() })
    .eq("user_id", user.id)
    .eq("client_id", clientId)
    .is("revoked_at", null)
    .select("client_id")
    .maybeSingle();
  if (error) return NextResponse.json({ error: "Permission update failed" }, { status: 503 });
  if (!data) return NextResponse.json({ error: "Connection not found" }, { status: 404 });
  return NextResponse.json({ updated: true });
}

export async function DELETE(request: NextRequest) {
  const { supabase, user } = await authenticatedClient();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const body = await request.json().catch(() => null) as { client_id?: unknown } | null;
  const clientId = typeof body?.client_id === "string" ? body.client_id.trim() : "";
  if (!clientId || clientId.length > 200) return invalid("client_id is required");

  const now = new Date().toISOString();
  const { error: grantError } = await supabase
    .from("mcp_client_grants")
    .update({ revoked_at: now, can_read: false, can_write: false, updated_at: now })
    .eq("user_id", user.id)
    .eq("client_id", clientId);
  if (grantError) return NextResponse.json({ error: "Connection revoke failed" }, { status: 503 });

  const { error: oauthError } = await supabase.auth.oauth.revokeGrant({ clientId });
  if (oauthError) {
    return NextResponse.json(
      { error: "DayPage access is disabled, but the OAuth refresh grant still needs revocation" },
      { status: 502 },
    );
  }
  return new NextResponse(null, { status: 204 });
}
