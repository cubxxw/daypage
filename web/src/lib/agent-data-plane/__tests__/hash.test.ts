import { describe, expect, it } from "vitest";
import { hashJson, stableJson } from "../hash";

describe("canonical hashing", () => {
  it("is stable across object key order", () => {
    expect(stableJson({ b: 2, a: { d: 4, c: 3 } })).toBe(stableJson({ a: { c: 3, d: 4 }, b: 2 }));
    expect(hashJson({ b: 2, a: 1 })).toBe(hashJson({ a: 1, b: 2 }));
  });
});
