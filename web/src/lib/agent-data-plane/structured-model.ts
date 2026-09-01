import "server-only";
import type { z } from "zod";
import type { LLMProvider } from "@/lib/ai";
import { stripJsonFence } from "./contracts";

export async function callStructuredModel<T>(input: {
  provider: LLMProvider;
  system: string;
  prompt: string;
  schema: z.ZodType<T>;
  maxTokens: number;
  timeoutSeconds?: number;
  temperature?: number;
  model?: string;
}): Promise<{ value: T; tokensIn: number; tokensOut: number; model: string }> {
  let lastError: unknown;
  let tokensIn = 0;
  let tokensOut = 0;
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const prompt = attempt === 1
        ? input.prompt
        : `${input.prompt}\n\nYour previous response failed validation. Return only one JSON object matching the requested schema exactly.`;
      const response = await Promise.race([
        input.provider.chat(
          [
            { role: "system", content: input.system },
            { role: "user", content: prompt },
          ],
          {
            model: input.model,
            jsonMode: true,
            temperature: attempt === 1 ? (input.temperature ?? 0.2) : 0,
            maxTokens: input.maxTokens,
          },
        ),
        new Promise<never>((_, reject) => {
          timer = setTimeout(
            () => reject(new Error(`Structured model call timed out after ${input.timeoutSeconds ?? 120}s`)),
            (input.timeoutSeconds ?? 120) * 1_000,
          );
        }),
      ]);
      tokensIn += response.tokens_in;
      tokensOut += response.tokens_out;
      return {
        value: input.schema.parse(JSON.parse(stripJsonFence(response.content))),
        tokensIn,
        tokensOut,
        model: response.model,
      };
    } catch (error) {
      lastError = error;
    } finally {
      if (timer) clearTimeout(timer);
    }
  }
  throw lastError instanceof Error ? lastError : new Error(String(lastError));
}
