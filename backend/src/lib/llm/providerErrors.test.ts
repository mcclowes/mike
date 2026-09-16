import { describe, expect, it } from "vitest";
import { UserFacingError } from "../userFacingError";
import { toProviderStreamError } from "./providerErrors";

const gemini = { label: "Gemini", modelId: "gemini-2.5-pro" };

function apiCallError(statusCode: number, responseBody = "") {
  return Object.assign(new Error(`Request failed (${statusCode})`), {
    name: "AI_APICallError",
    statusCode,
    responseBody,
  });
}

describe("toProviderStreamError", () => {
  it("explains a free-tier key without access to the model", () => {
    const error = toProviderStreamError(
      apiCallError(
        429,
        '{"error":{"code":429,"message":"Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_input_token_count, limit: 0, model: gemini-2.5-pro","status":"RESOURCE_EXHAUSTED"}}',
      ),
      gemini,
    );

    expect(error).toBeInstanceOf(UserFacingError);
    expect(error.message).toBe(
      "Your Gemini plan doesn't include gemini-2.5-pro. Select another model, or upgrade your Gemini plan.",
    );
  });

  it("unwraps the last error from an AI SDK retry error", () => {
    const retryError = Object.assign(new Error("Failed after 3 attempts"), {
      name: "AI_RetryError",
      lastError: apiCallError(429, "Resource has been exhausted"),
    });

    const error = toProviderStreamError(retryError, gemini);

    expect(error).toBeInstanceOf(UserFacingError);
    expect(error.message).toBe(
      "Gemini rate limit or quota reached. Wait a moment and try again, or select another model.",
    );
  });

  it.each([403, 404])("explains a %i as the model being unavailable", (status) => {
    const error = toProviderStreamError(apiCallError(status), gemini);

    expect(error).toBeInstanceOf(UserFacingError);
    expect(error.message).toBe(
      "gemini-2.5-pro isn't available with your Gemini API key. Select another model.",
    );
  });

  it("explains a rejected API key", () => {
    const error = toProviderStreamError(
      apiCallError(
        400,
        '{"error":{"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}',
      ),
      gemini,
    );

    expect(error).toBeInstanceOf(UserFacingError);
    expect(error.message).toBe(
      "Your Gemini API key was rejected. Check the key in your account settings.",
    );
  });

  it("keeps unclassified failures internal", () => {
    const original = apiCallError(500, "backend exploded");

    const error = toProviderStreamError(original, gemini);

    expect(error).not.toBeInstanceOf(UserFacingError);
    expect(error.message).toBe("Request failed (500)");
  });

  it("wraps non-Error values", () => {
    const error = toProviderStreamError(undefined, gemini);

    expect(error).not.toBeInstanceOf(UserFacingError);
    expect(error.message).toBe("Gemini stream failed.");
  });
});
