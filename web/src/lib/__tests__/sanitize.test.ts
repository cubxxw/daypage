import { describe, expect, it } from "vitest";
import { sanitizeMemoBody } from "../sanitize";

describe("sanitizeMemoBody", () => {
  it("preserves plain text and Markdown syntax", () => {
    expect(sanitizeMemoBody("Today's **memo** [link](https://example.com)")).toBe(
      "Today's **memo** [link](https://example.com)",
    );
  });

  it("removes every HTML tag delimiter instead of deny-listing dangerous forms", () => {
    const input = [
      '<script src="https://evil.example/x.js"></script >',
      '<img src=x onerror="alert(1)">',
      '<a href="JaVaScRiPt:alert(1)">click</a>',
      '<svg><a href="data:text/html,<script>alert(1)</script>">x</a></svg>',
    ].join("\n");

    const sanitized = sanitizeMemoBody(input);

    expect(sanitized).not.toContain("<");
    expect(sanitized).not.toContain(">");
    expect(sanitized).toContain('script src="https://evil.example/x.js"/script ');
    expect(sanitized).toContain('img src=x onerror="alert(1)"');
    expect(sanitized).toContain("svg");
  });

  it("keeps HTML entities readable without double-escaping them", () => {
    expect(sanitizeMemoBody("&lt;b&gt;<b>x</b>")).toBe("&lt;b&gt;bx/b");
  });
});
