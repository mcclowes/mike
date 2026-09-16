import { describe, expect, it } from "vitest";
import {
    ASSISTANT_ERROR_MESSAGE,
    AssistantStreamError,
    assistantStreamErrorEvent,
} from "../streaming";

describe("assistantStreamErrorEvent", () => {
    it("forwards the user-facing error the stream recorded", () => {
        const recorded = {
            type: "error" as const,
            message: "Your Gemini plan doesn't include gemini-2.5-pro.",
            safe_to_display: true,
        };
        const error = new AssistantStreamError(recorded.message, "", [
            { type: "reasoning", text: "thinking" },
            recorded,
        ]);

        expect(assistantStreamErrorEvent(error)).toEqual(recorded);
    });

    it("falls back to the generic message for other failures", () => {
        expect(assistantStreamErrorEvent(new Error("db down"))).toEqual({
            type: "error",
            message: ASSISTANT_ERROR_MESSAGE,
        });
    });
});
