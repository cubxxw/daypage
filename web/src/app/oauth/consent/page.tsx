import { redirect } from "next/navigation";
import { auth } from "@/lib/auth/session";
import { createClient } from "@/lib/supabase/server";

export const metadata = {
  title: "Authorize an app — DayPage",
  description: "Choose what an external agent or app may access in your DayPage.",
};

function ErrorCard({ message }: { message: string }) {
  return (
    <main className="oauth-consent-shell">
      <section className="oauth-consent-card" role="alert">
        <div className="oauth-consent-mark" aria-hidden>◇</div>
        <p className="oauth-consent-kicker">DAYPAGE · AUTHORIZATION</p>
        <h1>This request can’t continue.</h1>
        <p className="oauth-consent-copy">{message}</p>
        <a className="btn btn--secondary btn--md" href="/settings">Return to settings</a>
      </section>
    </main>
  );
}

export default async function OAuthConsentPage({
  searchParams,
}: {
  searchParams: Promise<{ authorization_id?: string; error?: string }>;
}) {
  const { authorization_id: authorizationId, error: queryError } = await searchParams;
  if (!authorizationId || authorizationId.length > 200) {
    return <ErrorCard message="The OAuth authorization ID is missing or invalid." />;
  }

  const session = await auth();
  if (!session?.user) {
    const callbackUrl = `/oauth/consent?authorization_id=${encodeURIComponent(authorizationId)}`;
    redirect(`/login?callbackUrl=${encodeURIComponent(callbackUrl)}`);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.auth.oauth.getAuthorizationDetails(authorizationId);
  if (error || !data) {
    return <ErrorCard message={queryError ?? "This request expired or is not valid for the signed-in account."} />;
  }
  if (!("authorization_id" in data)) redirect(data.redirect_url);
  if (data.user.id !== session.user.id) {
    return <ErrorCard message="The authorization request belongs to a different signed-in account." />;
  }

  const standardScopes = data.scope.split(/\s+/).filter(Boolean);

  return (
    <main className="oauth-consent-shell">
      <section className="oauth-consent-card" aria-labelledby="oauth-consent-title">
        <div className="oauth-consent-heading">
          <div className="oauth-consent-mark" aria-hidden>◇</div>
          <div>
            <p className="oauth-consent-kicker">DAYPAGE · AUTHORIZATION</p>
            <h1 id="oauth-consent-title">Connect {data.client.name}</h1>
          </div>
        </div>

        <p className="oauth-consent-copy">
          This app wants to use DayPage Cloud MCP as <strong>{data.user.email}</strong>.
          Your local Vault remains on your devices; this permission covers only data already synced to your DayPage account.
        </p>

        {queryError ? <div className="oauth-consent-error" role="alert">{queryError}</div> : null}

        <div className="oauth-client-card">
          <div>
            <span className="oauth-client-label">Requesting app</span>
            <strong>{data.client.name}</strong>
          </div>
          {data.client.uri ? (
            <a href={data.client.uri} target="_blank" rel="noreferrer">View app ↗</a>
          ) : null}
        </div>

        <form action="/oauth/consent/approve" method="post" className="oauth-permission-form">
          <input type="hidden" name="authorization_id" value={data.authorization_id} />
          <input type="hidden" name="client_id" value={data.client.id} />
          <fieldset>
            <legend>Choose DayPage access</legend>
            <label className="oauth-permission-option">
              <input type="radio" name="permission" value="read_only" defaultChecked />
              <span>
                <strong>Read only</strong>
                <small>Search and read synced memos and compiled pages. Recommended for assistants.</small>
              </span>
            </label>
            <label className="oauth-permission-option">
              <input type="radio" name="permission" value="read_write" />
              <span>
                <strong>Read and add memos</strong>
                <small>Also lets the app create new cloud memos. Existing memos cannot be deleted through MCP.</small>
              </span>
            </label>
          </fieldset>

          <div className="oauth-standard-scopes">
            <span>Identity scopes requested</span>
            <div>{standardScopes.map((scope) => <code key={scope}>{scope}</code>)}</div>
          </div>

          <p className="oauth-consent-note">
            You can revoke this connection at any time in DayPage Settings. DayPage validates this app’s OAuth client on every MCP request.
          </p>

          <div className="oauth-consent-actions">
            <button className="btn btn--primary btn--md" type="submit">Allow connection</button>
            <button
              className="btn btn--ghost btn--md"
              type="submit"
              formAction="/oauth/consent/deny"
              formMethod="post"
            >
              Deny
            </button>
          </div>
        </form>
      </section>
    </main>
  );
}
