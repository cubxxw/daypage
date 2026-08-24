import { describe, expect, it } from "vitest";
import { safeNextPath } from "../safe-next";

describe("safeNextPath", () => {
  it("keeps an OAuth consent callback on this origin", () => {
    expect(safeNextPath("/oauth/consent?authorization_id=pending-123")).toBe(
      "/oauth/consent?authorization_id=pending-123",
    );
  });

  it.each([
    "https://attacker.example/steal",
    "//attacker.example/steal",
    "/\\attacker.example/steal",
    "javascript:alert(1)",
    "/oauth/consent\nLocation: https://attacker.example",
  ])("rejects unsafe callback %s", (value) => {
    expect(safeNextPath(value, "/home")).toBe("/home");
  });

  it("uses the fallback for missing values", () => {
    expect(safeNextPath(undefined, "/today")).toBe("/today");
  });
});
