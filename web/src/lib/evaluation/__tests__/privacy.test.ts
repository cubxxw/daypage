import { describe, expect, it } from "vitest";
import { pseudonymizeUser, redactText, scrubEvaluationValue } from "../privacy";

describe("evaluation privacy boundary", () => {
  it("redacts common identity and credential-shaped content", () => {
    const text = redactText("Email me@example.com, call +86 138 0013 8000, open https://user:pass@example.com/x");
    expect(text).not.toContain("me@example.com");
    expect(text).not.toContain("138 0013 8000");
    expect(text).not.toContain("user:pass");
  });

  it("drops content in metadata-only mode and credential keys in redacted mode", () => {
    expect(scrubEvaluationValue({ memo: "private" }, "metadata_only")).toBeUndefined();
    expect(
      scrubEvaluationValue(
        { body: "hello me@example.com", api_key: "secret", nested: { password: "bad" } },
        "redacted",
      ),
    ).toEqual({ body: "hello [EMAIL]", nested: {} });
  });

  it("uses a stable salted pseudonym", () => {
    expect(pseudonymizeUser("user-id", "salt")).toBe(pseudonymizeUser("user-id", "salt"));
    expect(pseudonymizeUser("user-id", "salt")).not.toBe(pseudonymizeUser("user-id", "other"));
  });
});
