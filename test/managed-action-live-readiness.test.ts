import assert from "node:assert/strict";
import test from "node:test";
import { buildManagedActionLiveReadiness } from "../src/runtime/managed-action-live-readiness";
import { MANAGED_ACTION_LIVE_CONFIRMATION } from "../src/runtime/managed-action-live";
import type { ManagedActionAuditSnapshot } from "../src/runtime/managed-action-audit";
import type { ManagedActionLiveRolloutConfig } from "../src/runtime/managed-action-live-rollout";

const emptyAudit: ManagedActionAuditSnapshot = {
  ok: true,
  path: "runtime/operation-audit.log",
  count: 0,
  records: [],
};

const rolloutDisabled: ManagedActionLiveRolloutConfig = {
  source: "default",
  enabled: false,
  rules: [],
  issues: [],
};

test("managed action live readiness reports default live blockers without executing", () => {
  const readiness = buildManagedActionLiveReadiness({
    gate: {
      enabled: false,
      readonlyMode: true,
      allowedActions: [],
      requiredConfirmationText: MANAGED_ACTION_LIVE_CONFIRMATION,
    },
    rolloutConfig: rolloutDisabled,
    dryRunAudit: emptyAudit,
    productionExecutorWired: false,
    generatedAt: "2026-05-17T00:00:00.000Z",
  });

  assert.equal(readiness.ok, true);
  assert.equal(readiness.status, "blocked");
  assert.equal(readiness.liveExecutionAvailable, false);
  assert.equal(readiness.liveExecutionAttempted, false);
  assert.equal(readiness.mutatesOpenClawInstance, false);
  assert(readiness.blockers.some((item) => item.id === "live_gate_disabled"));
  assert(readiness.blockers.some((item) => item.id === "readonly_mode_enabled"));
  assert(readiness.blockers.some((item) => item.id === "rollout_config_disabled"));
  assert(readiness.blockers.some((item) => item.id === "production_executor_missing"));
  assert(readiness.reviewItems.some((item) => item.id === "dry_run_audit_empty"));
});

test("managed action live readiness reaches blocked-only-by-executor after safety gates are configured", () => {
  const audit: ManagedActionAuditSnapshot = {
    ok: true,
    path: "runtime/operation-audit.log",
    count: 1,
    records: [
      {
        timestamp: "2026-05-17T00:10:00.000Z",
        source: "api",
        ok: true,
        action: "healthcheck",
        operationRequestId: "dry-run-1",
        targetInstanceId: "tom",
        operator: "Anan",
        detail: "previewed healthcheck for tom",
        confirmationTextMatched: true,
        mutatesOpenClawInstance: false,
        commandPreview: ["control-center healthcheck for instance tom"],
      },
    ],
  };
  const rollout: ManagedActionLiveRolloutConfig = {
    source: "file",
    path: "/srv/openclaw-control-center-readonly/runtime/managed-action-rollout.json",
    enabled: true,
    issues: [],
    rules: [
      {
        action: "healthcheck",
        instanceId: "tom",
        operators: ["Anan"],
        risk: "low",
        enabled: true,
        maxDryRunAgeMinutes: 60,
      },
    ],
  };

  const readiness = buildManagedActionLiveReadiness({
    gate: {
      enabled: true,
      readonlyMode: false,
      allowedActions: ["healthcheck"],
      requiredConfirmationText: MANAGED_ACTION_LIVE_CONFIRMATION,
    },
    rolloutConfig: rollout,
    dryRunAudit: audit,
    productionExecutorWired: false,
  });

  assert.equal(readiness.status, "blocked");
  assert.deepEqual(readiness.blockers.map((item) => item.id), ["production_executor_missing"]);
  assert.equal(readiness.reviewItems.length, 0);
  assert.equal(readiness.rollout.enabledRules, 1);
  assert.deepEqual(readiness.rollout.actions, ["healthcheck"]);
  assert.deepEqual(readiness.rollout.instances, ["tom"]);
  assert.equal(readiness.dryRun.latest?.operationRequestId, "dry-run-1");
});

test("managed action live readiness is ready only when executor and all gates are wired", () => {
  const readiness = buildManagedActionLiveReadiness({
    gate: {
      enabled: true,
      readonlyMode: false,
      allowedActions: ["healthcheck"],
      requiredConfirmationText: MANAGED_ACTION_LIVE_CONFIRMATION,
    },
    rolloutConfig: {
      source: "file",
      path: "/tmp/rollout.json",
      enabled: true,
      issues: [],
      rules: [
        {
          action: "healthcheck",
          instanceId: "tom",
          operators: ["*"],
          risk: "low",
          enabled: true,
          maxDryRunAgeMinutes: 60,
        },
      ],
    },
    dryRunAudit: {
      ok: true,
      path: "runtime/operation-audit.log",
      count: 1,
      records: [
        {
          timestamp: "2026-05-17T00:10:00.000Z",
          source: "api",
          ok: true,
          action: "healthcheck",
          operationRequestId: "dry-run-1",
          targetInstanceId: "tom",
          detail: "previewed healthcheck for tom",
          confirmationTextMatched: true,
          mutatesOpenClawInstance: false,
          commandPreview: [],
        },
      ],
    },
    productionExecutorWired: true,
  });

  assert.equal(readiness.status, "ready");
  assert.equal(readiness.liveExecutionAvailable, true);
  assert.equal(readiness.blockers.length, 0);
  assert.equal(readiness.reviewItems.length, 0);
  assert.equal(readiness.executor.status, "wired");
});
