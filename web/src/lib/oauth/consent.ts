import "server-only";

import { createClient } from "@/lib/supabase/server";

export type ConsentApproval = {
  redirectUrl: string;
};

async function loadPendingAuthorization(authorizationId: string, expectedClientId?: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.auth.oauth.getAuthorizationDetails(authorizationId);

  if (error || !data || !("authorization_id" in data)) {
    throw new Error("This authorization request is no longer available.");
  }
  if (expectedClientId && data.client.id !== expectedClientId) {
    throw new Error("OAuth client mismatch.");
  }

  return { supabase, details: data };
}

export async function approveConsent(
  authorizationId: string,
  clientId: string,
  canWrite: boolean,
): Promise<ConsentApproval> {
  const { supabase, details } = await loadPendingAuthorization(authorizationId, clientId);
  const { error: grantError } = await supabase.rpc("daypage_upsert_mcp_client_grant_v1", {
    p_client_id: details.client.id,
    p_can_write: canWrite,
  });
  if (grantError) throw new Error("DayPage permission could not be saved.");

  const { data, error } = await supabase.auth.oauth.approveAuthorization(authorizationId, {
    skipBrowserRedirect: true,
  });
  if (error || !data?.redirect_url) {
    await supabase.rpc("daypage_revoke_mcp_client_grant_v1", {
      p_client_id: details.client.id,
    });
    throw new Error("OAuth authorization could not be completed.");
  }

  return { redirectUrl: data.redirect_url };
}

export async function denyConsent(authorizationId: string): Promise<ConsentApproval> {
  const { supabase } = await loadPendingAuthorization(authorizationId);
  const { data, error } = await supabase.auth.oauth.denyAuthorization(authorizationId, {
    skipBrowserRedirect: true,
  });
  if (error || !data?.redirect_url) {
    throw new Error("OAuth denial could not be completed.");
  }

  return { redirectUrl: data.redirect_url };
}
