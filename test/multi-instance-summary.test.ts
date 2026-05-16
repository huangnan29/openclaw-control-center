import assert from "node:assert/strict";
import test from "node:test";
import { summarizeMultiInstanceSnapshot } from "../src/runtime/multi-instance-summary";
import type {
  InstanceSnapshot,
  OpenClawInstanceConfig,
  ReadModelSnapshot,
} from "../src/types";

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

test("summarizeMultiInstanceSnapshot 聚合多实例只读快照总览", () => {
  const snapshots: InstanceSnapshot[] = [
    {
      instance: instance("main"),
      status: "connected",
      detail: "ok",
      snapshot: readModelSnapshot({
        sessions: [
          { sessionKey: "main-running", state: "running" },
          { sessionKey: "main-blocked", state: "blocked" },
          { sessionKey: "main-waiting", state: "waiting_approval" },
          { sessionKey: "main-error", state: "error" },
        ],
        approvals: [
          { approvalId: "approval-pending", status: "pending" },
          { approvalId: "approval-approved", status: "approved" },
        ],
        cronJobs: [{ jobId: "cron-main", enabled: true }],
      }),
    },
    {
      instance: instance("tom"),
      status: "partial",
      detail: "degraded",
      snapshot: readModelSnapshot({
        sessions: [{ sessionKey: "tom-running", state: "running" }],
        approvals: [{ approvalId: "approval-tom", status: "pending" }],
        cronJobs: [
          { jobId: "cron-tom-1", enabled: true },
          { jobId: "cron-tom-2", enabled: false },
        ],
      }),
    },
    {
      instance: instance("broken"),
      status: "not_connected",
      detail: "permission denied",
      snapshot: readModelSnapshot(),
    },
  ];

  const summary = summarizeMultiInstanceSnapshot(snapshots, "tom");

  assert.equal(summary.selectedInstanceId, "tom");
  assert.equal(summary.instances, snapshots);
  assert.equal(summary.totals.instances, 3);
  assert.equal(summary.totals.connected, 1);
  assert.equal(summary.totals.partial, 1);
  assert.equal(summary.totals.notConnected, 1);
  assert.equal(summary.totals.sessions, 5);
  assert.equal(summary.totals.running, 2);
  assert.equal(summary.totals.blocked, 2);
  assert.equal(summary.totals.errors, 1);
  assert.equal(summary.totals.pendingApprovals, 2);
  assert.equal(summary.totals.cronJobs, 3);
  assert.match(summary.generatedAt, /^\d{4}-\d{2}-\d{2}T/);
});
