import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { OpenClawReadonlyAdapter } from "../src/adapters/openclaw-readonly";
import { MultiInstanceReadonlyAdapter } from "../src/adapters/multi-instance-readonly";
import { ReadonlyToolClient } from "../src/clients/tool-client";
import type { OpenClawInstanceConfig, ReadModelSnapshot } from "../src/types";

function instance(id: string): OpenClawInstanceConfig {
  return {
    id,
    name: id,
    gatewayUrl: `ws://127.0.0.1:${id === "main" ? "18789" : "18790"}`,
    openclawHome: `/instances/${id}/config`,
    openclawConfigPath: `/instances/${id}/config/openclaw.json`,
    workspaceRoot: `/instances/${id}/workspace`,
    readonly: true,
  };
}

function readModelSnapshot(overrides: Partial<ReadModelSnapshot> = {}): ReadModelSnapshot {
  return {
    sessions: [],
    statuses: [],
    cronJobs: [],
    approvals: [],
    projects: {
      projects: [],
      updatedAt: "2026-05-17T00:00:00.000Z",
    },
    projectSummaries: [],
    tasks: {
      tasks: [],
      agentBudgets: [],
      updatedAt: "2026-05-17T00:00:00.000Z",
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
    generatedAt: "2026-05-17T00:00:00.000Z",
    ...overrides,
  };
}

test("MultiInstanceReadonlyAdapter 在单实例失败时返回 not_connected 空快照", async () => {
  const instances = [instance("main"), instance("broken")];
  const adapter = new MultiInstanceReadonlyAdapter(instances, {
    async createSnapshot(current) {
      if (current.id === "broken") {
        throw new Error("permission denied");
      }

      return readModelSnapshot({
        sessions: [{ sessionKey: "main-running", state: "running" }],
      });
    },
  });

  const snapshot = await adapter.snapshot("main");

  assert.equal(snapshot.selectedInstanceId, "main");
  assert.equal(snapshot.instances.length, 2);
  assert.equal(snapshot.instances[0]?.instance.id, "main");
  assert.equal(snapshot.instances[0]?.status, "connected");
  assert.equal(snapshot.instances[1]?.instance.id, "broken");
  assert.equal(snapshot.instances[1]?.status, "not_connected");
  assert.match(snapshot.instances[1]?.detail ?? "", /permission denied/);
  assert.deepEqual(snapshot.instances[1]?.snapshot.sessions, []);
  assert.equal(snapshot.totals.running, 1);
});

test("OpenClawReadonlyAdapter 从实例级 openclaw.json 读取 Agent 配置名录", async () => {
  const home = await mkdtemp(join(tmpdir(), "openclaw-readonly-roster-"));
  const configPath = join(home, "openclaw.json");

  try {
    await writeFile(
      configPath,
      JSON.stringify(
        {
          agents: {
            list: [
              { id: "main", name: "主控 Agent" },
              { id: "writer", name: "写作 Agent" },
            ],
          },
        },
        null,
        2,
      ),
      "utf8",
    );

    const adapter = new OpenClawReadonlyAdapter(new ReadonlyToolClient(), {
      ...instance("main"),
      openclawHome: home,
      openclawConfigPath: configPath,
    });

    const snapshot = await adapter.snapshot();

    assert.equal(snapshot.agentRoster?.status, "connected");
    assert.equal(snapshot.agentRoster?.sourcePath, configPath);
    assert.deepEqual(snapshot.agentRoster?.entries.map((entry) => entry.agentId), ["main", "writer"]);
    assert(snapshot.agentRoster?.detail.includes("source of truth"));
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});
