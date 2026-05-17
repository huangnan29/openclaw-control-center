import assert from "node:assert/strict";
import { mkdtemp, rm, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  buildCollectorSnapshot,
  selectCollectorExportScope,
  writeCollectorSnapshotFile,
} from "../src/runtime/collector-exporter";
import { loadCollectorSnapshotFile } from "../src/runtime/collector-snapshot";
import type { OpenClawInstanceConfig, ReadModelSnapshot } from "../src/types";

function instance(id: string, serverId = "tom-oracle"): OpenClawInstanceConfig {
  return {
    id,
    name: id,
    serverId,
    serverName: serverId === "tom-oracle" ? "Tom Oracle" : "Remote Oracle",
    gatewayUrl: `ws://127.0.0.1:${id === "main" ? "18789" : "18790"}`,
    openclawHome: `/instances/${id}/config`,
    openclawConfigPath: `/instances/${id}/config/openclaw.json`,
    workspaceRoot: `/instances/${id}/workspace`,
    readonly: true,
  };
}

function readModelSnapshot(overrides: Partial<ReadModelSnapshot> = {}): ReadModelSnapshot {
  const generatedAt = "2026-05-17T05:00:00.000Z";
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

test("buildCollectorSnapshot exports connected and failed instances", async () => {
  const snapshot = await buildCollectorSnapshot({
    instances: [instance("main"), instance("broken")],
    serverId: "tom-oracle",
    generatedAt: "2026-05-17T05:00:00.000Z",
    async createSnapshot(current) {
      if (current.id === "broken") throw new Error("gateway down");
      return readModelSnapshot({
        sessions: [
          {
            sessionKey: "main-session",
            state: "running",
            lastMessageAt: "2026-05-17T05:00:00.000Z",
          },
        ],
      });
    },
  });

  assert.equal(snapshot.schemaVersion, 1);
  assert.equal(snapshot.serverId, "tom-oracle");
  assert.equal(snapshot.generatedAt, "2026-05-17T05:00:00.000Z");
  assert.equal(snapshot.instances[0]?.id, "main");
  assert.equal(snapshot.instances[0]?.status, "connected");
  assert.equal(snapshot.instances[0]?.snapshot.sessions[0]?.sessionKey, "main-session");
  assert.equal(snapshot.instances[1]?.id, "broken");
  assert.equal(snapshot.instances[1]?.status, "not_connected");
  assert.equal(snapshot.instances[1]?.detail, "gateway down");
});

test("writeCollectorSnapshotFile writes JSON compatible with collector ingestion", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-collector-exporter-"));
  const file = join(dir, "nested", "snapshot.json");

  try {
    const snapshot = await buildCollectorSnapshot({
      instances: [instance("main")],
      serverId: "tom-oracle",
      generatedAt: "2026-05-17T05:10:00.000Z",
      async createSnapshot() {
        return readModelSnapshot();
      },
    });

    const written = await writeCollectorSnapshotFile(snapshot, file);
    const raw = await readFile(file, "utf8");
    const loaded = await loadCollectorSnapshotFile(file);

    assert.equal(written.path, file);
    assert.equal(written.instances, 1);
    assert(raw.endsWith("\n"));
    assert.equal(loaded.status, "connected");
    assert.equal(loaded.instances[0]?.id, "main");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("selectCollectorExportScope filters by server id", () => {
  const scope = selectCollectorExportScope(
    {
      source: "inline",
      servers: [
        { id: "tom-oracle", name: "Tom Oracle" },
        { id: "remote-oracle", name: "Remote Oracle" },
      ],
      instances: [instance("main", "tom-oracle"), instance("remote-main", "remote-oracle")],
      issues: [],
    },
    "remote-oracle",
  );

  assert.equal(scope.serverId, "remote-oracle");
  assert.equal(scope.serverName, "Remote Oracle");
  assert.deepEqual(scope.instances.map((item) => item.id), ["remote-main"]);
});

test("selectCollectorExportScope auto-selects one configured server", () => {
  const scope = selectCollectorExportScope({
    source: "inline",
    servers: [{ id: "tom-oracle", name: "Tom Oracle" }],
    instances: [instance("main", "tom-oracle"), instance("tom", "tom-oracle")],
    issues: [],
  });

  assert.equal(scope.serverId, "tom-oracle");
  assert.equal(scope.serverName, "Tom Oracle");
  assert.deepEqual(scope.instances.map((item) => item.id), ["main", "tom"]);
});
