/**
 * Stream lifecycle tests for useAssistantChat: who is allowed to kill an
 * in-flight answer.
 *
 * The backend treats a closed response socket as a user cancellation — it
 * stops the model and persists the partial answer labelled "Cancelled by
 * user." (lib/chat/routeStreaming.ts, `res.on("close")`). So the only place
 * the client may abort the request is the explicit Stop control. Leaving the
 * chat (clicking a sidebar link mid-stream, or React's dev StrictMode
 * mount → cleanup → mount) must leave the request alone and merely stop the
 * orphaned loop from repainting a list it no longer owns.
 */
import { StrictMode, useEffect, useRef } from "react";
import { act, render, renderHook, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Message } from "@/app/components/shared/types";

const { loadChatsMock, setCurrentChatIdMock, replaceMock } = vi.hoisted(() => ({
    loadChatsMock: vi.fn().mockResolvedValue(undefined),
    setCurrentChatIdMock: vi.fn(),
    replaceMock: vi.fn(),
}));
vi.mock("next/navigation", () => ({
    useRouter: () => ({ replace: replaceMock, push: vi.fn() }),
}));
vi.mock("@/app/contexts/ChatHistoryContext", () => ({
    useChatHistoryContext: () => ({
        replaceChatId: vi.fn(),
        loadChats: loadChatsMock,
        setCurrentChatId: setCurrentChatIdMock,
        saveChat: vi.fn().mockResolvedValue("new-chat"),
        setNewChatMessages: vi.fn(),
        updateChatTitle: vi.fn(),
    }),
}));
import { useAssistantChat } from "./useAssistantChat";

const fetchMock = vi.fn();

/**
 * A response body the test drives frame by frame, and that reports whether
 * the consumer cancelled the reader — cancelling is what closes the socket
 * and makes the backend truncate the answer.
 */
function controllableSseResponse() {
    const encoder = new TextEncoder();
    const state = { cancelled: false };
    let push!: (chunk: string) => void;
    let close!: () => void;
    const stream = new ReadableStream<Uint8Array>({
        start(controller) {
            push = (chunk) => controller.enqueue(encoder.encode(chunk));
            close = () => controller.close();
        },
        cancel() {
            state.cancelled = true;
        },
    });
    const response = new Response(stream, {
        status: 200,
        headers: { "Content-Type": "text/event-stream" },
    });
    // Let the hook's loop reach the awaited read() between our own steps.
    const flush = async () => {
        await act(async () => {
            await Promise.resolve();
            await Promise.resolve();
        });
    };
    return {
        response,
        state,
        send: async (chunk: string) => {
            push(chunk);
            await flush();
        },
        close: async () => {
            close();
            await flush();
        },
    };
}

const userMessage = (content = "hello"): Message => ({ role: "user", content });

/** The AbortSignal the hook handed to fetch for the turn in flight. */
const signalOfLastRequest = (): AbortSignal =>
    (fetchMock.mock.calls.at(-1)?.[1] as { signal: AbortSignal }).signal;

beforeEach(() => {
    vi.stubGlobal("fetch", fetchMock);
});

afterEach(() => {
    vi.unstubAllGlobals();
    vi.clearAllMocks();
});

describe("useAssistantChat stream lifecycle", () => {
    it("detaches without aborting when the hook unmounts mid-stream", async () => {
        const body = controllableSseResponse();
        fetchMock.mockResolvedValue(body.response);

        const { result, unmount } = renderHook(() => useAssistantChat());
        let turn!: Promise<string | null>;
        await act(async () => {
            turn = result.current.handleChat(userMessage());
            await Promise.resolve();
        });
        await body.send('data: {"type":"content_delta","text":"Partial"}\n\n');

        unmount();

        // Everything after the unmount belongs to a turn nobody is watching.
        await body.send('data: {"type":"chat_id","chatId":"c-orphan"}\n\n');
        await body.send('data: {"type":"content_delta","text":" and rest"}\n\n');
        await body.close();
        await act(async () => {
            await turn;
        });

        // The request outlives the component: no abort, no reader cancel, so
        // the server finishes the answer and persists it in full.
        expect(signalOfLastRequest().aborted).toBe(false);
        expect(body.state.cancelled).toBe(false);
        // ...and the orphaned loop writes nothing once it is detached.
        expect(setCurrentChatIdMock).not.toHaveBeenCalledWith("c-orphan");
        expect(replaceMock).not.toHaveBeenCalled();
        expect(loadChatsMock).not.toHaveBeenCalled();
    });

    it("aborts the request when the user presses Stop", async () => {
        const body = controllableSseResponse();
        fetchMock.mockResolvedValue(body.response);

        const { result } = renderHook(() => useAssistantChat());
        let turn!: Promise<string | null>;
        await act(async () => {
            turn = result.current.handleChat(userMessage());
            await Promise.resolve();
        });
        await body.send('data: {"type":"content_delta","text":"Partial"}\n\n');

        await act(async () => {
            result.current.cancel();
        });
        expect(signalOfLastRequest().aborted).toBe(true);

        // The next read observes the aborted signal and unwinds the turn.
        // (A real fetch rejects the pending read; here a keep-alive comment
        // line carries no frame and just lets the loop go round again.)
        await body.send(": keep-alive\n\n");
        await act(async () => {
            await turn;
        });

        const assistant = result.current.messages.findLast(
            (message) => message.role === "assistant",
        );
        expect(assistant?.events).toEqual([
            { type: "content", text: "Partial" },
            { type: "content", text: "Cancelled by user." },
        ]);
        expect(result.current.isResponseLoading).toBe(false);
    });

    it("keeps rendering the auto-sent first turn across a StrictMode remount", async () => {
        const body = controllableSseResponse();
        fetchMock.mockResolvedValue(body.response);

        // Mirrors the chat page: the first turn is sent from a mount effect
        // guarded by a ref, so StrictMode's second mount does not re-send it.
        function AutoSendChat() {
            const { messages, handleChat } = useAssistantChat();
            const hasAutoSent = useRef(false);
            useEffect(() => {
                if (hasAutoSent.current) return;
                hasAutoSent.current = true;
                void handleChat(userMessage());
                // eslint-disable-next-line react-hooks/exhaustive-deps
            }, []);
            const assistant = messages.findLast((m) => m.role === "assistant");
            const text = (assistant?.events ?? [])
                .map((event) => (event.type === "content" ? event.text : ""))
                .join("");
            return <div data-testid="answer">{text}</div>;
        }

        await act(async () => {
            render(
                <StrictMode>
                    <AutoSendChat />
                </StrictMode>,
            );
        });
        await body.send('data: {"type":"content_delta","text":"Hello"}\n\n');
        await body.close();

        expect(fetchMock).toHaveBeenCalledTimes(1);
        await waitFor(() =>
            expect(screen.getByTestId("answer")).toHaveTextContent("Hello"),
        );
    });
});
