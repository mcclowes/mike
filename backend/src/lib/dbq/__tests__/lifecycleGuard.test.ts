import { afterEach, describe, expect, it, vi } from "vitest";

vi.mock("../../supabase", () => ({ createServerSupabase: () => ({}) }));

import {
  enforceDocumentLifecycleMigration,
  evaluateLifecycleProbe,
  probeDocumentLifecycle,
  type LifecycleProbe,
} from "../lifecycleGuard";

afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

const probeDb = (result: LifecycleProbe) =>
  ({ rpc: vi.fn(async () => result) }) as never;

describe("document lifecycle boot guard", () => {
  it("passes when the database reports the lifecycle contract", () => {
    expect(evaluateLifecycleProbe({ data: 1, error: null })).toEqual({
      status: "ok",
    });
    // PostgREST hands back a scalar RPC result as a bare value or a one-row
    // array depending on the client; both mean the same thing.
    expect(evaluateLifecycleProbe({ data: [1], error: null }).status).toBe("ok");
  });

  it("fails when the probe reports the lifecycle RPCs are absent", () => {
    const verdict = evaluateLifecycleProbe({ data: 0, error: null });
    expect(verdict.status).toBe("missing");
    // The operator has to be told what to DO, not just what is broken.
    expect(verdict.status === "missing" && verdict.message).toMatch(
      /Apply the migrations/,
    );
  });

  it("fails when the probe function itself is missing", () => {
    for (const code of ["PGRST202", "42883"]) {
      expect(
        evaluateLifecycleProbe({ data: null, error: { code } }).status,
      ).toBe("missing");
    }
  });

  // A database that is briefly unreachable at boot must not become a crash
  // loop — that is a worse outage than the one this guard prevents.
  it("is inconclusive, not fatal, for any other failure", () => {
    expect(
      evaluateLifecycleProbe({
        data: null,
        error: { code: "57P03", message: "the database system is starting up" },
      }).status,
    ).toBe("inconclusive");
    expect(evaluateLifecycleProbe({ data: null, error: null }).status).toBe(
      "inconclusive",
    );
  });

  it("stops the process only on a missing migration", async () => {
    const exit = vi.fn();
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    await enforceDocumentLifecycleMigration(
      probeDb({ data: 0, error: null }),
      exit as never,
    );
    expect(exit).toHaveBeenCalledWith(1);
    expect(error).toHaveBeenCalled();
  });

  it("warns and keeps serving when the answer is unavailable", async () => {
    const exit = vi.fn();
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    await enforceDocumentLifecycleMigration(
      probeDb({ data: null, error: { code: "57P03", message: "starting up" } }),
      exit as never,
    );
    expect(exit).not.toHaveBeenCalled();
    expect(warn).toHaveBeenCalled();
  });

  it("can be switched off for a deployment that accepts the risk", async () => {
    vi.stubEnv("DOCUMENT_LIFECYCLE_GUARD", "off");
    const exit = vi.fn();
    const db = probeDb({ data: 0, error: null });
    await enforceDocumentLifecycleMigration(db, exit as never);
    expect(exit).not.toHaveBeenCalled();
  });

  it("treats a thrown client error as inconclusive", async () => {
    const db = {
      rpc: vi.fn(async () => {
        throw new Error("socket hang up");
      }),
    } as never;
    expect((await probeDocumentLifecycle(db)).status).toBe("inconclusive");
  });
});
