import { describe, expect, it } from "vitest";
import { decideToolApproval, sanitizeReceipt } from "../tools";
import {
  applyPagePatchBody,
  artifactBlock,
  mergeAfterConflict,
  removeArtifactBlock,
} from "../page-reconcile";

describe("tool authorization boundary", () => {
  it("never lets model text auto-authorize an external write", () => {
    expect(
      decideToolApproval({
        effect: "external_write",
        defaultApproval: "auto",
        requested: "auto",
        bindingRequired: false,
        bindingPresent: true,
      }),
    ).toBe("confirm");
  });

  it("fails closed when an Agent has no explicit Tool binding", () => {
    expect(
      decideToolApproval({
        effect: "read",
        defaultApproval: "auto",
        requested: "auto",
        bindingRequired: true,
        bindingPresent: false,
      }),
    ).toBe("forbidden");
  });

  it("allows a proposal to demand stricter confirmation", () => {
    expect(
      decideToolApproval({
        effect: "internal_write",
        defaultApproval: "auto",
        requested: "required",
        bindingRequired: false,
        bindingPresent: true,
      }),
    ).toBe("confirm");
  });

  it("recursively removes secret-bearing receipt fields", () => {
    const receipt = sanitizeReceipt(
      {
        provider_id: "evt_123",
        nested: {
          access_token: "must-not-leak",
          result: [{ cookie: "must-not-leak", label: "kept" }],
        },
      },
      65_536,
    );
    expect(receipt).toEqual({
      provider_id: "evt_123",
      nested: { result: [{ label: "kept" }] },
    });
  });
});

describe("optimistic page conflict fallback", () => {
  it("preserves the concurrent body and appends a traceable contribution", () => {
    const merged = mergeAfterConflict(
      "Concurrent accepted content",
      { contribution_md: "Grounded new fact" },
      "11111111-1111-4111-8111-111111111111",
    );
    expect(merged).toContain("Concurrent accepted content");
    expect(merged).toContain("Grounded new fact");
    expect(merged).toContain("daypage-artifact:11111111-1111-4111-8111-111111111111");
  });

  it("appends contribution patches even before a version conflict", () => {
    const merged = applyPagePatchBody(
      "Human-authored context",
      { contribution_md: "Grounded addition" },
      "22222222-2222-4222-8222-222222222222",
      false,
    );
    expect(merged).toContain("Human-authored context");
    expect(merged).toContain("Grounded addition");
    expect(merged).toContain("daypage-artifact:22222222-2222-4222-8222-222222222222");
  });

  it("retracts an exact bounded contribution without removing human content", () => {
    const id = "33333333-3333-4333-8333-333333333333";
    const body = ["Human context", artifactBlock(id, "Old grounded fact"), "Human footer"].join("\n\n");
    const result = removeArtifactBlock(body, id, "Old grounded fact");
    expect(result).toEqual({
      body: "Human context\n\nHuman footer",
      found: true,
      removed: true,
    });
  });

  it("refuses to guess where an edited legacy contribution ends", () => {
    const id = "44444444-4444-4444-8444-444444444444";
    const result = removeArtifactBlock(
      `Human context\n\n<!-- daypage-artifact:${id} -->\n\nEdited grounded fact`,
      id,
      "Original grounded fact",
    );
    expect(result.found).toBe(true);
    expect(result.removed).toBe(false);
  });
});
