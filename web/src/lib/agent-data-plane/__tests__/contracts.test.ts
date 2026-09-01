import { describe, expect, it } from "vitest";
import {
  MemoUnderstandingSchema,
  assertContextDecisionWithinCandidates,
  assertSourceRefsWithinMemo,
  parseMemoUnderstanding,
} from "../contracts";

const memoId = "11111111-1111-4111-8111-111111111111";
const pageId = "22222222-2222-4222-8222-222222222222";

function processingFields(overrides: Record<string, unknown> = {}) {
  return {
    intent: { kind: "idea", confidence: 0.9, rationale: "The memo describes an idea" },
    response_policy: {
      mode: "reflect",
      reason_codes: ["idea_benefits_from_reflection"],
      uncertainty: 0.1,
      max_reply_tokens: 300,
    },
    context_decision: {
      strategy: "semantic",
      query_terms: ["DayPage"],
      candidates: [{ page_id: pageId, selected: true, reason: "Same project" }],
      selected_page_ids: [pageId],
    },
    response: {
      body_md: "This sharpens the DayPage direction.",
      claims: [
        {
          text: "The memo is about DayPage",
          source_refs: [{ memo_id: memoId, start: 0, end: 7 }],
          inference: false,
        },
      ],
      suggested_followups: [],
    },
    proposed_memory_updates: [],
    ...overrides,
  };
}

describe("Agent output contract", () => {
  it("parses a grounded structured result", () => {
    const result = parseMemoUnderstanding(
      `\`\`\`json\n${JSON.stringify({
        ...processingFields(),
        summary: "A grounded memo",
        observations: [
          {
            kind: "fact",
            subject: "DayPage",
            predicate: "state",
            value: "designed",
            confidence: 0.9,
            source_refs: [{ memo_id: memoId, start: 0, end: 7 }],
          },
        ],
        artifacts: [
          {
            kind: "daily_contribution",
            payload: { headline: "Designed DayPage" },
            source_refs: [{ memo_id: memoId, start: 0, end: 7 }],
          },
        ],
        proposed_actions: [],
      })}\n\`\`\``,
    );
    expect(result.observations[0].inference).toBe(false);
    expect(() => assertSourceRefsWithinMemo(result, memoId, 20)).not.toThrow();
    expect(() => assertContextDecisionWithinCandidates(result, [pageId])).not.toThrow();
  });

  it("rejects a cross-memo or out-of-bounds citation", () => {
    const result = MemoUnderstandingSchema.parse({
      ...processingFields(),
      summary: "Bad provenance",
      observations: [],
      artifacts: [
        {
          kind: "daily_contribution",
          payload: {},
          source_refs: [{ memo_id: memoId, start: 0, end: 99 }],
        },
      ],
      proposed_actions: [],
    });
    expect(() => assertSourceRefsWithinMemo(result, memoId, 10)).toThrow(/exceeds memo length/);
  });

  it("rejects an empty or inverted span", () => {
    expect(() =>
      MemoUnderstandingSchema.parse({
        ...processingFields(),
        summary: "Invalid",
        observations: [
          {
            kind: "fact",
            subject: "x",
            predicate: "y",
            value: "z",
            confidence: 1,
            source_refs: [{ memo_id: memoId, start: 4, end: 4 }],
          },
        ],
        artifacts: [],
        proposed_actions: [],
      }),
    ).toThrow();
  });

  it("enforces silent response restraint", () => {
    expect(() =>
      MemoUnderstandingSchema.parse({
        ...processingFields({
          response_policy: {
            mode: "silent",
            reason_codes: ["background_only"],
            uncertainty: 0.1,
            max_reply_tokens: 0,
          },
        }),
        summary: "Background organization",
        observations: [],
        artifacts: [],
        proposed_actions: [],
      }),
    ).toThrow(/silent response policy/);
  });

  it("rejects context ids that were not supplied", () => {
    const result = MemoUnderstandingSchema.parse({
      ...processingFields(),
      summary: "Context test",
      observations: [],
      artifacts: [],
      proposed_actions: [],
    });
    expect(() => assertContextDecisionWithinCandidates(result, [])).toThrow(/not supplied/);
  });
});
