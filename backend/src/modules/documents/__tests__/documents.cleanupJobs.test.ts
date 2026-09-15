import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { scriptedDb } from "../../../__tests__/helpers/scriptedDb";
import { DbJobDeferredError } from "../../../lib/dbq/types";
const storage = vi.hoisted(() => ({
  deleteFile: vi.fn(),
  assertStorageConfigured: vi.fn(),
}));
vi.mock("../../../lib/storage", () => ({
  ...storage,
  extractedTextKey: (id: string) => `extracted-text/${id}.txt`,
}));
const appJobs = vi.hoisted(() => ({ enqueueAppJobDelivery: vi.fn() }));
vi.mock("../../../lib/queue/appJobsQueue", () => appJobs);
import {
  handleDocumentCleanup,
  captureInlineDocumentCleanup,
  completeInlineDocumentCleanup,
} from "../documents.cleanupJobs";

beforeEach(() => {
  vi.clearAllMocks();
  // clearAllMocks clears calls, not implementations: reset both so a test
  // that makes storage fail cannot leak into the next one.
  storage.deleteFile.mockReset().mockResolvedValue(undefined);
  storage.assertStorageConfigured.mockReset();
});
afterEach(() => vi.unstubAllEnvs());
const job = (keys: unknown[]) => ({ payload: { keys } });

/** scriptedDb plus `rpc`, for the handler's sibling-claim pass. */
type RpcStep = { rpc: string; data?: unknown; error?: unknown };
type TableStep = { table: string; data?: unknown; error?: unknown };
type Recorded = {
  table?: string;
  rpc?: string;
  args?: unknown;
  op: string;
  payload?: unknown;
  filters: Array<[string, ...unknown[]]>;
};

function coalescingDb(steps: Array<RpcStep | TableStep>) {
  const calls: Recorded[] = [];
  let cursor = 0;
  const settle = (call: Recorded) => {
    calls.push(call);
    const step = steps[cursor++];
    expect(step, `Unexpected call ${JSON.stringify(call)}`).toBeDefined();
    return Promise.resolve({
      data: step.data ?? null,
      error: step.error ?? null,
    });
  };
  const from = (table: string) => {
    const call: Recorded = { table, op: "select", filters: [] };
    const run = () => settle(call);
    const builder: Record<string, unknown> = {
      select: () => builder,
      single: run,
      maybeSingle: run,
      then: (resolve: (v: unknown) => unknown, reject: (e: unknown) => unknown) =>
        run().then(resolve, reject),
    };
    for (const op of ["update", "insert", "delete"])
      builder[op] = (payload?: unknown) => {
        call.op = op;
        call.payload = payload;
        return builder;
      };
    for (const filter of ["eq", "is", "in", "or", "order", "range", "limit"])
      builder[filter] = (...args: unknown[]) => {
        call.filters.push([filter, ...args]);
        return builder;
      };
    return builder;
  };
  const rpc = (name: string, args: unknown) =>
    settle({ rpc: name, args, op: "rpc", filters: [] });
  return {
    db: { from, rpc } as unknown as Parameters<typeof handleDocumentCleanup>[0],
    calls,
    done: () =>
      expect(cursor, "Not all expected queries ran").toBe(steps.length),
  };
}

const sibling = (id: string, keys: string[], attempts = 1) => ({
  id,
  kind: "document.cleanup",
  payload: { keys },
  attempts,
  claimed_at: `claimed-${id}`,
});

describe("document cleanup job", () => {
  it("deletes unreferenced source/PDF/cache keys once and keeps surviving shared bytes", async () => {
    const fake = scriptedDb([
      { table: "db_jobs", data: [] },
      { table: "document_versions", data: [{ storage_path: "shared" }] },
      {
        table: "document_versions",
        data: [{ pdf_storage_path: "shared-pdf" }],
      },
    ]);
    await handleDocumentCleanup(
      fake.db,
      job([
        "source",
        "pdf",
        "source",
        "shared",
        "shared-pdf",
        "extracted-text/v.txt",
        null,
        "",
      ]),
    );
    expect(storage.deleteFile.mock.calls.flat()).toEqual([
      "source",
      "pdf",
      "extracted-text/v.txt",
    ]);
    for (const call of fake.calls.slice(1))
      expect(call.filters).toContainEqual(["is", "deleted_at", null]);
    fake.done();
  });

  it("does no destructive work when reference lookup fails", async () => {
    const error = { message: "database unavailable" };
    const fake = scriptedDb([{ table: "document_versions", error }]);
    await expect(
      handleDocumentCleanup(fake.db, job(["source"])),
    ).rejects.toEqual(error);
    expect(storage.deleteFile).not.toHaveBeenCalled();
    fake.done();
  });

  it("attempts every key but reports failure so the job retries", async () => {
    const fake = scriptedDb([
      { table: "document_versions", data: [] },
      { table: "document_versions", data: [] },
    ]);
    storage.deleteFile.mockRejectedValueOnce(new Error("storage unavailable"));
    await expect(
      handleDocumentCleanup(fake.db, job(["a", "b"])),
    ).rejects.toThrow("document_cleanup_failed:1");
    expect(storage.deleteFile.mock.calls.flat()).toEqual(["a", "b"]);
  });

  it("defers cache cleanup while a worker can still produce its output", async () => {
    const fake = scriptedDb([
      { table: "db_jobs", data: [{ id: "running-precompute" }] },
    ]);
    await expect(
      handleDocumentCleanup(fake.db, job(["extracted-text/v.txt"])),
    ).rejects.toBeInstanceOf(DbJobDeferredError);
    expect(storage.deleteFile).not.toHaveBeenCalled();
    expect(fake.calls[0].filters).toContainEqual([
      "in",
      "payload->>versionId",
      ["v"],
    ]);
  });

  it("lets the database collect cleanup in the normal worker mode", async () => {
    vi.stubEnv("DB_JOBS_ENABLED", "true");
    const fake = scriptedDb([]);
    expect(
      await captureInlineDocumentCleanup(fake.db, { documentIds: ["doc"] }),
    ).toEqual([]);
    await completeInlineDocumentCleanup(fake.db, []);
    expect(storage.deleteFile).not.toHaveBeenCalled();
    fake.done();
  });

  it("drains the whole pending backlog in one run and marks each row done", async () => {
    const fake = coalescingDb([
      { rpc: "claim_db_jobs", data: [sibling("j2", ["b"]), sibling("j3", ["c", "a"], 2)] },
      { table: "document_versions", data: [] },
      { table: "document_versions", data: [] },
      { table: "db_jobs" },
      { table: "db_jobs" },
    ]);
    await handleDocumentCleanup(fake.db, { id: "j1", payload: { keys: ["a"] } });
    // One deduplicated pass over every claimed row's keys.
    expect(storage.deleteFile.mock.calls.flat()).toEqual(["a", "b", "c"]);
    expect(fake.calls[0].args).toEqual({
      p_limit: 500,
      p_stale_seconds: 600,
      p_kind: "document.cleanup",
    });
    const settled = fake.calls.slice(3);
    expect(settled.map((call) => (call.payload as { status: string }).status)).toEqual(["done", "done"]);
    // Fenced to the claim we hold, exactly like the runner's own writes.
    expect(settled[0].filters).toEqual([
      ["eq", "id", "j2"],
      ["eq", "status", "running"],
      ["eq", "attempts", 1],
      ["eq", "claimed_at", "claimed-j2"],
    ]);
    fake.done();
  });

  it("retries only the rows whose own keys failed", async () => {
    const fake = coalescingDb([
      { rpc: "claim_db_jobs", data: [sibling("j2", ["b"])] },
      { table: "document_versions", data: [] },
      { table: "document_versions", data: [] },
      { table: "db_jobs" },
    ]);
    storage.deleteFile.mockImplementation((key: string) =>
      key === "b" ? Promise.reject(new Error("storage unavailable")) : Promise.resolve(),
    );
    // "a" is this row's key and it succeeded, so this job is done.
    await handleDocumentCleanup(fake.db, { id: "j1", payload: { keys: ["a"] } });
    expect(fake.calls[3].payload).toMatchObject({
      status: "pending",
      last_error: "document_cleanup_failed:1",
    });
    fake.done();
  });

  it("hands claimed rows back when the run cannot proceed", async () => {
    const fake = coalescingDb([
      { rpc: "claim_db_jobs", data: [sibling("j2", ["b"])] },
      { table: "db_jobs", data: [{ id: "running-precompute" }] },
      { table: "db_jobs" },
    ]);
    await expect(
      handleDocumentCleanup(fake.db, {
        id: "j1",
        payload: { keys: ["extracted-text/v.txt"] },
      }),
    ).rejects.toBeInstanceOf(DbJobDeferredError);
    expect(storage.deleteFile).not.toHaveBeenCalled();
    expect(fake.calls[2].payload).toMatchObject({ status: "pending", attempts: 0 });
    fake.done();
  });

  it("keeps draining one row at a time when the claim has no kind filter", async () => {
    const fake = coalescingDb([
      { rpc: "claim_db_jobs", error: { code: "PGRST202", message: "not found" } },
      { table: "document_versions", data: [] },
      { table: "document_versions", data: [] },
    ]);
    await handleDocumentCleanup(fake.db, { id: "j1", payload: { keys: ["a"] } });
    expect(storage.deleteFile.mock.calls.flat()).toEqual(["a"]);
    fake.done();
  });

  it("asks redis to deliver the trigger's cleanup rows after a delete", async () => {
    vi.stubEnv("REDIS_URL", "redis://localhost:6379");
    const fake = coalescingDb([
      { table: "db_jobs", data: [{ id: "trigger-row" }, { id: "trigger-row-2" }] },
    ]);
    await completeInlineDocumentCleanup(fake.db, []);
    expect(appJobs.enqueueAppJobDelivery.mock.calls.flat()).toEqual([
      "trigger-row",
      "trigger-row-2",
    ]);
    expect(fake.calls[0].filters).toEqual([
      ["eq", "kind", "document.cleanup"],
      ["eq", "status", "pending"],
      ["limit", 5],
    ]);
    fake.done();
  });

  // The job form throws to ask the runner for a retry. On a request thread
  // the same throw would 500 a delete that has already happened.
  it("never fails the request when inline deletion fails", async () => {
    vi.stubEnv("DB_JOBS_ENABLED", "false");
    const fake = coalescingDb([
      { table: "document_versions", data: [] },
      { table: "document_versions", data: [] },
    ]);
    storage.deleteFile.mockRejectedValue(new Error("storage unavailable"));
    await expect(
      completeInlineDocumentCleanup(fake.db, ["gone"]),
    ).resolves.toBeUndefined();
    fake.done();
  });

  it("never fails the request when the object store is unconfigured", async () => {
    vi.stubEnv("DB_JOBS_ENABLED", "false");
    storage.assertStorageConfigured.mockImplementation(() => {
      throw new Error("R2_ENDPOINT_URL ... must be set");
    });
    const fake = coalescingDb([]);
    // The capture runs BEFORE the rows are deleted: throwing here would
    // refuse a delete the user is entitled to.
    expect(
      await captureInlineDocumentCleanup(fake.db, { documentIds: ["doc"] }),
    ).toEqual([]);
    await expect(
      completeInlineDocumentCleanup(fake.db, ["gone"]),
    ).resolves.toBeUndefined();
    expect(storage.deleteFile).not.toHaveBeenCalled();
    fake.done();
  });

  it("leaves the durable row alone when the inline snapshot cannot be taken", async () => {
    vi.stubEnv("DB_JOBS_ENABLED", "false");
    const fake = coalescingDb([
      { table: "documents", error: { message: "database unavailable" } },
    ]);
    expect(
      await captureInlineDocumentCleanup(fake.db, { projectIds: ["p1"] }),
    ).toEqual([]);
    fake.done();
  });

  it("captures all artifacts before deleting when workers are disabled", async () => {
    vi.stubEnv("DB_JOBS_ENABLED", "false");
    const fake = scriptedDb([
      {
        table: "document_versions",
        data: [{ id: "v", storage_path: "source", pdf_storage_path: "pdf" }],
      },
    ]);
    expect(
      await captureInlineDocumentCleanup(fake.db, {
        documentIds: ["authorized-doc"],
      }),
    ).toEqual(["source", "pdf", "extracted-text/v.txt"]);
    expect(fake.calls[0].filters).toEqual([
      ["in", "document_id", ["authorized-doc"]],
    ]);
    fake.done();
  });
});
