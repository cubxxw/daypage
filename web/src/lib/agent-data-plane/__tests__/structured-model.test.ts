import { describe, expect, it, vi } from "vitest";
import { z } from "zod";
import type { LLMProvider } from "@/lib/ai";
import { callStructuredModel } from "../structured-model";

describe("bounded structured model calls", () => {
  it("repairs one invalid response and accounts for both attempts", async () => {
    const chat = vi
      .fn()
      .mockResolvedValueOnce({ content: "not json", tokens_in: 3, tokens_out: 2, model: "test" })
      .mockResolvedValueOnce({ content: '{"answer":"ok"}', tokens_in: 5, tokens_out: 4, model: "test" });
    const provider = { chat } as unknown as LLMProvider;

    const result = await callStructuredModel({
      provider,
      system: "Return JSON",
      prompt: "Input",
      schema: z.object({ answer: z.literal("ok") }),
      maxTokens: 50,
      timeoutSeconds: 1,
    });

    expect(result).toEqual({ value: { answer: "ok" }, tokensIn: 8, tokensOut: 6, model: "test" });
    expect(chat).toHaveBeenCalledTimes(2);
    expect(chat.mock.calls[1]?.[0]?.[1]?.content).toContain("failed validation");
  });
});
