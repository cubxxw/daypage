import { describe, expect, it } from "vitest";
import { hasSameOrigin } from "../form-origin";

describe("hasSameOrigin", () => {
  it("accepts a browser form posted to the same public host", () => {
    const request = new Request("http://localhost:13000/oauth/consent/approve", {
      headers: { host: "127.0.0.1:13000", origin: "http://127.0.0.1:13000" },
    });
    expect(hasSameOrigin(request)).toBe(true);
  });

  it("uses the forwarded protocol behind a TLS proxy", () => {
    const request = new Request("http://internal/oauth/consent/approve", {
      headers: {
        host: "staging.daypage.example",
        origin: "https://staging.daypage.example",
        "x-forwarded-proto": "https",
      },
    });
    expect(hasSameOrigin(request)).toBe(true);
  });

  it("rejects cross-origin and missing-origin posts", () => {
    const crossOrigin = new Request("https://daypage.example/oauth/consent/approve", {
      headers: { host: "daypage.example", origin: "https://evil.example" },
    });
    expect(hasSameOrigin(crossOrigin)).toBe(false);
    expect(hasSameOrigin(new Request("https://daypage.example/oauth/consent/approve"))).toBe(false);
  });
});
