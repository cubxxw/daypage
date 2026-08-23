import { NextResponse } from "next/server";
import { approveConsent } from "@/lib/oauth/consent";
import { hasSameOrigin } from "@/lib/oauth/form-origin";

function consentRedirect(request: Request, authorizationId: string, message: string) {
  const target = new URL("/oauth/consent", request.url);
  target.searchParams.set("authorization_id", authorizationId);
  target.searchParams.set("error", message);
  return NextResponse.redirect(target, 303);
}

function validFormValue(value: FormDataEntryValue | null): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= 200;
}

export async function POST(request: Request) {
  const formData = await request.formData();
  const authorizationId = formData.get("authorization_id");
  const clientId = formData.get("client_id");

  if (!validFormValue(authorizationId) || !validFormValue(clientId)) {
    return consentRedirect(request, "invalid", "The authorization request is invalid.");
  }
  if (!hasSameOrigin(request)) {
    return consentRedirect(request, authorizationId, "The authorization form origin is invalid.");
  }

  try {
    const { redirectUrl } = await approveConsent(
      authorizationId,
      clientId,
      formData.get("permission") === "read_write",
    );
    return NextResponse.redirect(redirectUrl, 303);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Authorization failed.";
    return consentRedirect(request, authorizationId, message);
  }
}
