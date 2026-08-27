import { createHash } from "node:crypto";

const SYSTEM_ACTION_NUMBER_SCALE = 1_000_000;

export function canonicalSystemActionNumber(value) {
  if (!Number.isFinite(value)) throw new TypeError("system action numbers must be finite");
  const scaled = value * SYSTEM_ACTION_NUMBER_SCALE;
  const rounded = Math.round(scaled);
  if (!Number.isSafeInteger(rounded) || Math.abs(scaled - rounded) > 0.0000001) {
    throw new TypeError("system action numbers require at most six decimal places");
  }
  if (rounded === 0) return "0";
  const sign = rounded < 0 ? "-" : "";
  const digits = String(Math.abs(rounded)).padStart(7, "0");
  const whole = digits.slice(0, -6);
  const fraction = digits.slice(-6).replace(/0+$/, "");
  return fraction ? `${sign}${whole}.${fraction}` : `${sign}${whole}`;
}

/** Canonical JSON used only for executable system-action payload hashes. */
export function canonicalSystemActionJson(value) {
  if (value === null || typeof value !== "object") {
    if (typeof value === "number") return canonicalSystemActionNumber(value);
    const encoded = JSON.stringify(value);
    if (encoded === undefined) throw new TypeError("system action payload is not JSON-encodable");
    return encoded;
  }
  if (Array.isArray(value)) {
    return `[${value.map(canonicalSystemActionJson).join(",")}]`;
  }
  const object = value;
  return `{${Object.keys(object)
    .sort()
    .map((key) => `${JSON.stringify(key)}:${canonicalSystemActionJson(object[key])}`)
    .join(",")}}`;
}

export function systemActionPayloadHash(payload) {
  return createHash("sha256")
    .update(canonicalSystemActionJson(payload), "utf8")
    .digest("hex");
}
