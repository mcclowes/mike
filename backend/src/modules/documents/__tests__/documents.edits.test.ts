import { afterEach, describe, expect, it, vi } from "vitest";
import { scriptedDb } from "../../../__tests__/helpers/scriptedDb";

const storage = vi.hoisted(() => ({
  downloadFile: vi.fn(),
  uploadFile: vi.fn(),
  deleteFile: vi.fn(),
  assertStorageConfigured: vi.fn(),
}));
const dbq = vi.hoisted(() => ({
  enqueueStorageCleanup: vi.fn(),
  requestDocumentCleanupDelivery: vi.fn(),
}));
const docx = vi.hoisted(() => ({ resolveTrackedChange: vi.fn() }));
const access = vi.hoisted(() => ({ ensureDocAccess: vi.fn() }));

vi.mock("../../../lib/storage", () => ({
  ...storage,
  extractedTextKey: (id: string) => `extracted-text/${id}.txt`,
}));
vi.mock("../../../lib/dbq/enqueue", () => dbq);
vi.mock("../../../lib/docxTrackedChanges", () => ({
  ...docx,
  extractTrackedChangeIds: vi.fn(),
}));
vi.mock("../../../lib/access", () => access);
vi.mock("../../../lib/permissions", () => ({ can: () => true }));
vi.mock("../../../lib/downloadTokens", () => ({
  buildDownloadUrl: () => "https://example.test/download",
}));
vi.mock("../../../lib/documentVersions", async (importOriginal) => ({
  ...(await importOriginal<object>()),
  loadActiveVersion: vi.fn(async () => ({
    storage_path: "docs/v1.docx",
    filename: "Clause.docx",
    version_number: 2,
    source: "assistant_edit",
  })),
}));

import { resolveEdit } from "../documents.edits";

const PENDING_EDIT = {
  id: "edit-1",
  document_id: "doc-1",
  change_id: "c1",
  del_w_id: "w-del",
  ins_w_id: "w-ins",
  status: "pending",
};
const DOC = {
  id: "doc-1",
  current_version_id: "v1",
  user_id: "user-1",
  project_id: null,
  org_id: null,
  workflow_id: null,
};

afterEach(() => {
  vi.unstubAllEnvs();
  vi.clearAllMocks();
});

function arrange() {
  storage.downloadFile.mockResolvedValue(new Uint8Array([1, 2, 3]).buffer);
  storage.uploadFile.mockResolvedValue(undefined);
  storage.deleteFile.mockResolvedValue(undefined);
  dbq.requestDocumentCleanupDelivery.mockResolvedValue(0);
  docx.resolveTrackedChange.mockResolvedValue({
    bytes: new Uint8Array([9, 9, 9]),
    found: true,
  });
  access.ensureDocAccess.mockResolvedValue({ ok: true, projectRole: "owner" });
}

const run = (db: Parameters<typeof resolveEdit>[5]) =>
  resolveEdit("accept", "doc-1", "edit-1", "user-1", "u@example.test", db);

describe("resolving a tracked edit", () => {
  // Measured before this change: two direct document_versions updates (each
  // firing the cleanup trigger) plus an explicit storage.cleanup enqueue — three
  // db_jobs rows carrying the same key for one click.
  it("rewrites the version with a single update and no explicit enqueue", async () => {
    arrange();
    const fake = scriptedDb([
      { table: "document_edits", data: PENDING_EDIT },
      { table: "documents", data: DOC },
      { table: "document_versions", op: "update", data: { id: "v1" } },
      { table: "document_edits", op: "update" },
      { table: "document_edits", data: [] },
    ]);

    const result = await run(fake.db);

    expect(result.ok).toBe(true);
    const versionWrites = fake.calls.filter(
      (call) => call.table === "document_versions",
    );
    // One write to the version => the trigger fires once => one cleanup row.
    expect(versionWrites).toHaveLength(1);
    expect(versionWrites[0].payload).toEqual({
      content_sha256: expect.any(String),
      pdf_storage_path: null,
    });
    // Scoped by the lifecycle helper, not by a raw id filter.
    expect(versionWrites[0].filters).toEqual([
      ["eq", "id", "v1"],
      ["eq", "document_id", "doc-1"],
      ["is", "deleted_at", null],
    ]);
    // The keys ride on that one row instead of a second job of their own.
    expect(dbq.enqueueStorageCleanup).not.toHaveBeenCalled();
    fake.done();
  });

  it("still removes the stale rendition inline when the queue is disabled", async () => {
    arrange();
    vi.stubEnv("DB_JOBS_ENABLED", "false");
    const fake = scriptedDb([
      { table: "document_edits", data: PENDING_EDIT },
      { table: "documents", data: DOC },
      // The lifecycle helper's pre-write snapshot of the keys about to retire.
      {
        table: "document_versions",
        data: {
          storage_path: "docs/v1.docx",
          pdf_storage_path: "renditions/v1.pdf",
          content_sha256: "old-hash",
        },
      },
      { table: "document_versions", op: "update", data: { id: "v1" } },
      { table: "db_jobs", data: [] },
      { table: "document_versions", data: [] },
      { table: "document_versions", data: [] },
      { table: "document_edits", op: "update" },
      { table: "document_edits", data: [] },
    ]);

    const result = await run(fake.db);

    expect(result.ok).toBe(true);
    expect(storage.deleteFile.mock.calls.flat()).toEqual([
      "renditions/v1.pdf",
      "extracted-text/v1.txt",
    ]);
    expect(dbq.enqueueStorageCleanup).not.toHaveBeenCalled();
    fake.done();
  });

  // The bytes are already replaced by the time the row is written, so a failed
  // write must not leave the old hash attesting to content that is gone.
  it("clears the hash when the version write fails", async () => {
    arrange();
    const fake = scriptedDb([
      { table: "document_edits", data: PENDING_EDIT },
      { table: "documents", data: DOC },
      {
        table: "document_versions",
        op: "update",
        error: { message: "write failed" },
      },
      { table: "document_versions", op: "update", data: { id: "v1" } },
      { table: "document_edits", op: "update" },
      { table: "document_edits", data: [] },
    ]);

    await run(fake.db);

    const versionWrites = fake.calls.filter(
      (call) => call.table === "document_versions",
    );
    expect(versionWrites[1].payload).toEqual({
      content_sha256: null,
      pdf_storage_path: null,
    });
    fake.done();
  });
});
