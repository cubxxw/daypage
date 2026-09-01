import { describe, expect, it } from "vitest";
import { feedbackScoreProjection } from "../feedback";
import { RecordFeedbackSchema } from "../contracts";

describe("feedback score projection", () => {
  it("preserves the exact event and emits a semantic adoption score", () => {
    expect(feedbackScoreProjection({ event_type: "action.accepted" })).toEqual([
      { name: "user.action.accepted", value: 1, reason: undefined },
      { name: "user.action_adoption", value: 1, reason: undefined },
    ]);
  });

  it("does not pretend dismissal is a definitive quality failure", () => {
    const scores = feedbackScoreProjection({ event_type: "response.dismissed" });
    expect(scores).toEqual([
      { name: "user.response.dismissed", value: 1, reason: undefined },
    ]);
    expect(scores.some((score) => score.name === "overall_quality")).toBe(false);
  });

  it("keeps event occurrence separate from an explicit scalar rating", () => {
    expect(
      feedbackScoreProjection({ event_type: "response.saved", value: 0.5 }),
    ).toEqual([
      { name: "user.response.saved", value: 1, reason: undefined },
      { name: "user.explicit_value", value: 0.5, reason: undefined },
      { name: "user.response_durable_value", value: 1, reason: undefined },
    ]);
  });

  it("requires concrete correction evidence for edit signals", () => {
    expect(
      RecordFeedbackSchema.safeParse({
        event_type: "response.edited",
        idempotency_key: "feedback-edit-1",
      }).success,
    ).toBe(false);
    expect(
      RecordFeedbackSchema.safeParse({
        event_type: "response.edited",
        correction: { before: "long", after: "short" },
        idempotency_key: "feedback-edit-2",
      }).success,
    ).toBe(true);
  });
});
