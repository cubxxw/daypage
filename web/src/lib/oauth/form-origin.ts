export function hasSameOrigin(request: Request): boolean {
  const origin = request.headers.get("origin");
  if (!origin) return false;

  try {
    const actual = new URL(origin);
    const requestUrl = new URL(request.url);
    const host = request.headers.get("host") ?? requestUrl.host;
    const forwardedProtocol = request.headers.get("x-forwarded-proto")?.split(",", 1)[0]?.trim();
    const protocol = forwardedProtocol ? `${forwardedProtocol}:` : requestUrl.protocol;
    return actual.protocol === protocol && actual.host === host;
  } catch {
    return false;
  }
}
