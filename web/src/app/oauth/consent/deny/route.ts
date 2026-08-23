import { NextResponse } from "next/server";
import { denyConsent } from "@/lib/oauth/consent";
import { hasSameOrigin } from "@/lib/oauth/form-origin";

function consentRedirect(request: Request, authorizationId: string, message: string) {
  const target = new URL("/oauth/consent", request.url);
  target.searchParams.set("authorization_id", authorizationId);
  target.searchParams.set("error", message);
  return NextResponse.redirect(target, 303);
}

export async function POST(request: Request) {
  const formData = await request.formData();
  const authorizationId = formData.get("authorization_id");

  if (
    typeof authorizationId !== "string"
    || authorizationId.length === 0
    || authorizationId.length > 200
  ) {
    return consentRedirect(request, "invalid", "The authorization request is invalid.");
  }
  if (!hasSameOrigin(request)) {
    return consentRedirect(request, authorizationId, "The authorization form origin is invalid.");
  }

  try {
    const { redirectUrl } = await denyConsent(authorizationId);
    return NextResponse.redirect(redirectUrl, 303);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Authorization failed.";
    return consentRedirect(request, authorizationId, message);
  }
}
