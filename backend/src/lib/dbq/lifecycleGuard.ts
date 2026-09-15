// Boot-time proof that the document-lifecycle migration is applied.
//
// Rollouts run code and migrations at different moments, and this subsystem is
// asymmetric about which order is safe. Migration first is merely untidy: an
// older runner meets a job kind it does not know, fails the row, and the
// claim's backoff keeps it polite until the new code arrives. Code first is
// destructive in a way nothing reports: deletes still succeed, because the
// rows go through ordinary DELETEs — but the trigger that records WHERE the
// bytes live does not exist yet, so nothing is ever enqueued and the objects
// are orphaned with no record that they were meant to go. Uploads and edits
// 500 at the same time (PGRST202 on the lifecycle RPCs), which looks like an
// unrelated outage.
//
// So: ask the database once, at boot, whether the contract is installed, and
// refuse to serve if it is not. The check is a single cheap RPC.

import { createServerSupabase, type Db } from "../supabase";

export type LifecycleProbe = {
  data: unknown;
  error: { code?: string | null; message?: string | null } | null;
};

export type LifecycleVerdict =
  | { status: "ok" }
  | { status: "missing"; message: string }
  | { status: "inconclusive"; message: string };

/** PostgREST: the function is not in the schema cache. Postgres: no such function. */
const MISSING_FUNCTION_CODES = new Set(["PGRST202", "42883"]);

const ACTIONABLE = [
  "[startup] The document-lifecycle migration is not applied to this database.",
  "Deletes would succeed while the trigger that records their storage keys does",
  "not exist, orphaning objects with no record that they were meant to go, and",
  "every upload, version and edit would fail. Apply the migrations",
  "(backend/migrations, see docs/deployment.md) and restart. To start anyway —",
  "knowing storage will leak — set DOCUMENT_LIFECYCLE_GUARD=off.",
].join(" ");

/**
 * The decision, separated from the call so it can be tested directly.
 *
 * An unknown error is deliberately NOT fatal. The guard exists to catch a
 * deployment-ordering mistake, which is a permanent condition; a database
 * that is merely slow or briefly unreachable at boot would otherwise turn
 * into a crash loop, which is a worse outage than the one being prevented.
 */
export function evaluateLifecycleProbe(
  probe: LifecycleProbe,
): LifecycleVerdict {
  if (probe.error) {
    const code = probe.error.code ?? "";
    if (MISSING_FUNCTION_CODES.has(code))
      return { status: "missing", message: ACTIONABLE };
    return {
      status: "inconclusive",
      message: `[startup] Could not verify the document-lifecycle migration: ${
        probe.error.message ?? code ?? "unknown error"
      }`,
    };
  }
  // Number(null) is 0, and "0" is the answer that stops the process — so the
  // absence of an answer has to be ruled out before the value is read.
  const raw = Array.isArray(probe.data) ? probe.data[0] : probe.data;
  const version = typeof raw === "number" ? raw : Number.NaN;
  if (version >= 1) return { status: "ok" };
  if (version === 0) return { status: "missing", message: ACTIONABLE };
  return {
    status: "inconclusive",
    message:
      "[startup] Could not verify the document-lifecycle migration: the probe returned no version.",
  };
}

export async function probeDocumentLifecycle(db: Db): Promise<LifecycleVerdict> {
  try {
    const { data, error } = await db.rpc("document_lifecycle_version");
    return evaluateLifecycleProbe({ data, error });
  } catch (err) {
    return evaluateLifecycleProbe({
      data: null,
      error: { message: err instanceof Error ? err.message : String(err) },
    });
  }
}

/**
 * Boot gate. Stops the process when the migration is provably absent, warns
 * and continues when the answer is merely unavailable.
 */
export async function enforceDocumentLifecycleMigration(
  db: Db = createServerSupabase(),
  exit: (code: number) => never = process.exit as (code: number) => never,
): Promise<LifecycleVerdict> {
  if (process.env.DOCUMENT_LIFECYCLE_GUARD === "off") return { status: "ok" };
  const verdict = await probeDocumentLifecycle(db);
  if (verdict.status === "missing") {
    console.error(verdict.message);
    exit(1);
  } else if (verdict.status === "inconclusive") {
    console.warn(verdict.message);
  }
  return verdict;
}
