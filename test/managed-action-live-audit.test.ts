import assert from "node:assert/strict";
import test from "node:test";
import {
  buildManagedActionLiveAuditEntry,
  type ManagedActionLiveAuditInput,
} from "../src/runtime/managed-action-live-audit";

const instance = {
  id: "tom",
  name: "Tom",
  gatewayUrl: "ws://127.0.0.1:18791",
  openclawHome: "/instances/tom/config",
  openclawConfigPath: "/instances/tom/config/openclaw.json",
  workspaceRoot: "/instances/tom/workspace",
  readonly: true,
  serverId: "tom-oracle",
  serverName: "Tom Oracle",
};

const baseInput: Omit<ManagedActionLiveAuditInput, "outcome"> = {
  source: "api",
  action: "healthcheck",
  instance,
  operationRequestId: "dry-run-1",
  requestId: "req-1",
  operator: "Anan",
  reason: "验证真实执行审计结构",
  executor: "managed-action-healthcheck",
  startedAt: "2026-05-17T06:00:00.000Z",
  finishedAt: "2026-05-17T06:00:02.500Z",
  gate: {
    enabled: true,
    readonlyMode: false,
    allowedActions: ["healthcheck"],
    requiredConfirmationText: "LIVE-ACTION-APPROVED",
  },
  commandPreview: ["healthcheck tom"],
};

test("managed action live audit entry describes executed results", () => {
  const entry = buildManagedActionLiveAuditEntry({
    ...baseInput,
    outcome: "executed",
    result: { message: "healthcheck ok", exitCode: 0, artifactPaths: ["runtime/live/healthcheck.json"] },
  });

  assert.equal(entry.action, "managed_action_live_result");
  assert.equal(entry.ok, true);
  assert.equal(entry.detail, "executed healthcheck for tom");
  const metadata = entry.metadata!;
  assert.equal(metadata.outcome, "executed");
  assert.equal(metadata.liveExecution, true);
  assert.equal(metadata.mutatesOpenClawInstance, true);
  assert.equal(metadata.operationRequestId, "dry-run-1");
  assert.equal(metadata.target && typeof metadata.target === "object" && !Array.isArray(metadata.target) ? (metadata.target as { instanceId?: string }).instanceId : undefined, "tom");
  assert.equal(metadata.durationMs, 2500);
  assert.deepEqual(metadata.rollback, { required: false, status: "not_required" });
});

test("managed action live audit entry describes failed results", () => {
  const entry = buildManagedActionLiveAuditEntry({
    ...baseInput,
    outcome: "failed",
    error: { code: "HEALTHCHECK_TIMEOUT", message: "timeout" },
    rollback: { status: "pending", detail: "manual inspection required" },
  });

  assert.equal(entry.ok, false);
  assert.equal(entry.detail, "failed healthcheck for tom");
  assert.equal(entry.metadata?.outcome, "failed");
  assert.equal(entry.metadata?.liveExecution, true);
  assert.deepEqual(entry.metadata?.error, { code: "HEALTHCHECK_TIMEOUT", message: "timeout" });
  assert.deepEqual(entry.metadata?.rollback, {
    required: true,
    status: "pending",
    detail: "manual inspection required",
  });
});

test("managed action live audit entry describes rolled back results", () => {
  const entry = buildManagedActionLiveAuditEntry({
    ...baseInput,
    outcome: "rolled_back",
    error: { message: "execution failed after partial work" },
    rollback: {
      status: "completed",
      detail: "restored previous state",
      artifactPaths: ["runtime/live/rollback.json"],
    },
  });

  assert.equal(entry.ok, false);
  assert.equal(entry.detail, "rolled back healthcheck for tom");
  assert.equal(entry.metadata?.outcome, "rolled_back");
  assert.equal(entry.metadata?.rollback && typeof entry.metadata.rollback === "object" && !Array.isArray(entry.metadata.rollback) ? (entry.metadata.rollback as { status?: string }).status : undefined, "completed");
  assert.equal(entry.metadata?.rollback && typeof entry.metadata.rollback === "object" && !Array.isArray(entry.metadata.rollback) ? (entry.metadata.rollback as { required?: boolean }).required : undefined, true);
});

test("managed action live audit entry describes skipped results without live execution", () => {
  const entry = buildManagedActionLiveAuditEntry({
    ...baseInput,
    outcome: "skipped",
    skip: { reason: "dry-run request expired" },
  });

  assert.equal(entry.ok, true);
  assert.equal(entry.detail, "skipped healthcheck for tom");
  assert.equal(entry.metadata?.outcome, "skipped");
  assert.equal(entry.metadata?.liveExecution, false);
  assert.equal(entry.metadata?.mutatesOpenClawInstance, false);
  assert.deepEqual(entry.metadata?.skip, { reason: "dry-run request expired" });
});
