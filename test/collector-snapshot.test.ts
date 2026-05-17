import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { loadCollectorSnapshotFile } from "../src/runtime/collector-snapshot";
import type { ReadModelSnapshot } from "../src/types";

function readModelSnapshot(overrides: Partial<ReadModelSnapshot> = {}): ReadModelSnapshot {
  const generatedAt = "2026-05-17T04:00:00.000Z";
  return {
    sessions: [],
    statuses: [],
    cronJobs: [],
    approvals: [],
    projects: {
      projects: [],
      updatedAt: generatedAt,
    },
    projectSummaries: [],
    tasks: {
      tasks: [],
      agentBudgets: [],
      updatedAt: generatedAt,
    },
    tasksSummary: {
      projects: 0,
      tasks: 0,
      todo: 0,
      inProgress: 0,
      blocked: 0,
      done: 0,
      owners: 0,
      artifacts: 0,
    },
    budgetSummary: {
      total: 0,
      ok: 0,
      warn: 0,
      over: 0,
      evaluations: [],
    },
    generatedAt,
    ...overrides,
  };
}

test("loadCollectorSnapshotFile reads readonly collector snapshots", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-collector-"));
  const file = join(dir, "snapshot.json");

  try {
    await writeFile(
      file,
      JSON.stringify({
        schemaVersion: 1,
        serverId: "remote-oracle",
        generatedAt: "2026-05-17T04:00:00.000Z",
        instances: [
          {
            id: "remote-main",
            status: "connected",
            detail: "collector ok",
            snapshot: readModelSnapshot({
              sessions: [
                {
                  sessionKey: "remote-session",
                  state: "running",
                  lastMessageAt: "2026-05-17T04:00:00.000Z",
                },
              ],
            }),
          },
        ],
      }),
      "utf8",
    );

    const snapshot = await loadCollectorSnapshotFile(file);

    assert.equal(snapshot.status, "connected");
    assert.equal(snapshot.serverId, "remote-oracle");
    assert.equal(snapshot.instances[0]?.id, "remote-main");
    assert.equal(snapshot.instances[0]?.snapshot.sessions[0]?.sessionKey, "remote-session");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("loadCollectorSnapshotFile reports unreadable snapshot without throwing", async () => {
  const snapshot = await loadCollectorSnapshotFile(join(tmpdir(), "missing-openclaw-collector-snapshot.json"));

  assert.equal(snapshot.status, "not_connected");
  assert.equal(snapshot.instances.length, 0);
  assert.match(snapshot.detail, /failed to read collector snapshot/);
});
