/**
 * Keep post-auth navigation on this origin. Reject absolute, protocol-relative,
 * backslash and control-character variants that can become open redirects.
 */
export function safeNextPath(raw: string | null | undefined, fallback = "/home"): string {
  if (!raw) return fallback;
  const value = raw.trim();
  if (
    !value.startsWith("/") ||
    value.startsWith("//") ||
    value.startsWith("/\\") ||
    /[\u0000-\u001f\u007f]/.test(value)
  ) {
    return fallback;
  }
  return value;
}
