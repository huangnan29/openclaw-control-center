import assert from "node:assert/strict";
import test from "node:test";
import { ReadonlyToolClient } from "../src/clients/tool-client";
import { startUiServer } from "../src/ui/server";

function instance(id: string) {
  return {
    id,
    name: id,
    gatewayUrl: `ws://127.0.0.1:${id === "main" ? "18789" : "18791"}`,
    openclawHome: `/instances/${id}/config`,
    openclawConfigPath: `/instances/${id}/config/openclaw.json`,
    workspaceRoot: `/instances/${id}/workspace`,
    readonly: true,
  };
}

test("managed action dry-run previews whitelisted actions without executing in readonly multi-instance mode", async () => {
  const previousInstancesJson = process.env.OPENCLAW_INSTANCES_JSON;
  const previousInstancesFile = process.env.OPENCLAW_INSTANCES_FILE;
  process.env.OPENCLAW_INSTANCES_JSON = JSON.stringify({
    servers: [
      {
        id: "tom-oracle",
        name: "Tom Oracle",
        collectorSnapshotPath: "/app/runtime/collectors/tom-oracle/snapshot.json",
        instances: [instance("main"), instance("tom")],
      },
    ],
  });
  delete process.env.OPENCLAW_INSTANCES_FILE;

  const server = startUiServer(0, new ReadonlyToolClient(), {
    readonlyMode: true,
    localTokenAuthRequired: false,
  });

  try {
    if (!server.listening) {
      await new Promise<void>((resolve, reject) => {
        server.once("listening", resolve);
        server.once("error", reject);
      });
    }
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("Failed to bind ephemeral UI port.");
    const baseUrl = `http://127.0.0.1:${address.port}`;

    const response = await fetch(`${baseUrl}/api/managed-actions/dry-run`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        instanceId: "tom",
        action: "healthcheck",
        operator: "Anan",
        reason: "上线前只读演练",
        confirmedText: "DRY-RUN-ONLY",
      }),
    });
    assert.equal(response.status, 200);
    const body = await response.json() as {
      ok: boolean;
      dryRun: boolean;
      liveExecution: boolean;
      action: string;
      target: { instanceId: string; serverId?: string };
      commandPreview: string[];
      safety: { mutatesOpenClawInstance: boolean; requiresConfirmation: boolean };
      review: { operationRequestId: string; operator: string; reason: string; confirmationTextMatched: boolean };
    };

    assert.equal(body.ok, true);
    assert.equal(body.dryRun, true);
    assert.equal(body.liveExecution, false);
    assert.equal(body.action, "healthcheck");
    assert.equal(body.target.instanceId, "tom");
    assert.deepEqual(body.commandPreview, ["control-center healthcheck for instance tom"]);
    assert.equal(body.safety.mutatesOpenClawInstance, false);
    assert.equal(body.safety.requiresConfirmation, true);
    assert.equal(typeof body.review.operationRequestId, "string");
    assert.equal(body.review.operator, "Anan");
    assert.equal(body.review.reason, "上线前只读演练");
    assert.equal(body.review.confirmationTextMatched, true);

    const auditResponse = await fetch(`${baseUrl}/api/managed-actions/audit?limit=5&instanceId=tom&operator=Anan`);
    assert.equal(auditResponse.status, 200);
    const audit = await auditResponse.json() as {
      ok: boolean;
      count: number;
      records: Array<{
        action?: string;
        targetInstanceId?: string;
        operator?: string;
        reason?: string;
        confirmationTextMatched?: boolean;
        mutatesOpenClawInstance?: boolean;
      }>;
    };
    assert.equal(audit.ok, true);
    assert(audit.count >= 1);
    assert.equal(audit.records[0]?.action, "healthcheck");
    assert.equal(audit.records[0]?.targetInstanceId, "tom");
    assert.equal(audit.records[0]?.operator, "Anan");
    assert.equal(audit.records[0]?.reason, "上线前只读演练");
    assert.equal(audit.records[0]?.confirmationTextMatched, true);
    assert.equal(audit.records[0]?.mutatesOpenClawInstance, false);

    const liveResponse = await fetch(`${baseUrl}/api/managed-actions/live`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        instanceId: "tom",
        action: "healthcheck",
        operator: "Anan",
        reason: "确认真实执行默认关闭",
        operationRequestId: body.review.operationRequestId,
        confirmedText: "LIVE-ACTION-APPROVED",
      }),
    });
    assert.equal(liveResponse.status, 403);
    const liveBody = await liveResponse.json() as {
      ok: boolean;
      status: string;
      liveExecution: boolean;
      gate: { enabled: boolean };
      dryRunReference: { valid: boolean; status: string; operationRequestId: string };
      rollout: { allowed: boolean; status: string };
    };
    assert.equal(liveBody.ok, false);
    assert.equal(liveBody.status, "blocked_disabled");
    assert.equal(liveBody.liveExecution, false);
    assert.equal(liveBody.gate.enabled, false);
    assert.equal(liveBody.dryRunReference.valid, true);
    assert.equal(liveBody.dryRunReference.status, "valid");
    assert.equal(liveBody.dryRunReference.operationRequestId, body.review.operationRequestId);
    assert.equal(liveBody.rollout.allowed, false);
    assert.equal(liveBody.rollout.status, "disabled");

    const readinessResponse = await fetch(`${baseUrl}/api/managed-actions/readiness`);
    assert.equal(readinessResponse.status, 200);
    const readinessBody = await readinessResponse.json() as {
      ok: boolean;
      status: string;
      liveExecutionAvailable: boolean;
      liveExecutionAttempted: boolean;
      mutatesOpenClawInstance: boolean;
      dryRun: { count: number; latest?: { operationRequestId?: string } };
      executor: { productionWired: boolean; status: string };
      blockers: Array<{ id: string }>;
    };
    assert.equal(readinessBody.ok, true);
    assert.equal(readinessBody.status, "blocked");
    assert.equal(readinessBody.liveExecutionAvailable, false);
    assert.equal(readinessBody.liveExecutionAttempted, false);
    assert.equal(readinessBody.mutatesOpenClawInstance, false);
    assert(readinessBody.dryRun.count >= 1);
    assert.equal(readinessBody.dryRun.latest?.operationRequestId, body.review.operationRequestId);
    assert.equal(readinessBody.executor.productionWired, false);
    assert.equal(readinessBody.executor.status, "missing");
    assert(readinessBody.blockers.some((item) => item.id === "production_executor_missing"));
    assert(!JSON.stringify(readinessBody).includes("LOCAL_API_TOKEN"));

    const invalidReferenceLiveResponse = await fetch(`${baseUrl}/api/managed-actions/live`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        instanceId: "tom",
        action: "healthcheck",
        operator: "Anan",
        reason: "确认真实执行引用无效申请时会标记",
        operationRequestId: "missing-dry-run-request",
        confirmedText: "LIVE-ACTION-APPROVED",
      }),
    });
    assert.equal(invalidReferenceLiveResponse.status, 403);
    const invalidReferenceLiveBody = await invalidReferenceLiveResponse.json() as {
      status: string;
      liveExecution: boolean;
      dryRunReference: { valid: boolean; status: string };
    };
    assert.equal(invalidReferenceLiveBody.status, "blocked_disabled");
    assert.equal(invalidReferenceLiveBody.liveExecution, false);
    assert.equal(invalidReferenceLiveBody.dryRunReference.valid, false);
    assert.equal(invalidReferenceLiveBody.dryRunReference.status, "missing");

    const actionMismatchLiveResponse = await fetch(`${baseUrl}/api/managed-actions/live`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        instanceId: "tom",
        action: "collector_refresh",
        operator: "Anan",
        reason: "确认真实执行引用动作必须一致",
        operationRequestId: body.review.operationRequestId,
        confirmedText: "LIVE-ACTION-APPROVED",
      }),
    });
    assert.equal(actionMismatchLiveResponse.status, 403);
    const actionMismatchLiveBody = await actionMismatchLiveResponse.json() as {
      dryRunReference: { valid: boolean; status: string };
    };
    assert.equal(actionMismatchLiveBody.dryRunReference.valid, false);
    assert.equal(actionMismatchLiveBody.dryRunReference.status, "action_mismatch");

    const targetMismatchLiveResponse = await fetch(`${baseUrl}/api/managed-actions/live`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        instanceId: "main",
        action: "healthcheck",
        operator: "Anan",
        reason: "确认真实执行引用目标必须一致",
        operationRequestId: body.review.operationRequestId,
        confirmedText: "LIVE-ACTION-APPROVED",
      }),
    });
    assert.equal(targetMismatchLiveResponse.status, 403);
    const targetMismatchLiveBody = await targetMismatchLiveResponse.json() as {
      dryRunReference: { valid: boolean; status: string };
    };
    assert.equal(targetMismatchLiveBody.dryRunReference.valid, false);
    assert.equal(targetMismatchLiveBody.dryRunReference.status, "target_mismatch");

    const blockedResponse = await fetch(`${baseUrl}/api/managed-actions/dry-run`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        instanceId: "missing",
        action: "healthcheck",
        operator: "Anan",
        reason: "确认缺失实例不会执行",
        confirmedText: "DRY-RUN-ONLY",
      }),
    });
    assert.equal(blockedResponse.status, 404);

    const confirmationResponse = await fetch(`${baseUrl}/api/managed-actions/dry-run`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        instanceId: "tom",
        action: "healthcheck",
        operator: "Anan",
        reason: "确认短语错误时阻断",
        confirmedText: "RUN",
      }),
    });
    assert.equal(confirmationResponse.status, 400);
  } finally {
    if (server.listening) {
      await new Promise<void>((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
    }
    if (previousInstancesJson === undefined) {
      delete process.env.OPENCLAW_INSTANCES_JSON;
    } else {
      process.env.OPENCLAW_INSTANCES_JSON = previousInstancesJson;
    }
    if (previousInstancesFile === undefined) {
      delete process.env.OPENCLAW_INSTANCES_FILE;
    } else {
      process.env.OPENCLAW_INSTANCES_FILE = previousInstancesFile;
    }
  }
});

test("managed action live route executes readonly healthcheck only when executor switch and all gates are ready", async () => {
  const previousInstancesJson = process.env.OPENCLAW_INSTANCES_JSON;
  const previousInstancesFile = process.env.OPENCLAW_INSTANCES_FILE;
  process.env.OPENCLAW_INSTANCES_JSON = JSON.stringify({
    instances: [instance("tom")],
  });
  delete process.env.OPENCLAW_INSTANCES_FILE;

  const server = startUiServer(0, new ReadonlyToolClient(), {
    readonlyMode: false,
    localTokenAuthRequired: false,
    managedActionLiveGate: {
      enabled: true,
      readonlyMode: false,
      allowedActions: ["healthcheck"],
      requiredConfirmationText: "LIVE-ACTION-APPROVED",
    },
    managedActionProductionExecutorEnabled: true,
    managedActionLiveRolloutConfig: {
      source: "file",
      path: "/tmp/test-rollout.json",
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
    },
  });

  try {
    if (!server.listening) {
      await new Promise<void>((resolve, reject) => {
        server.once("listening", resolve);
        server.once("error", reject);
      });
    }
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("Failed to bind ephemeral UI port.");
    const baseUrl = `http://127.0.0.1:${address.port}`;

    const dryRunResponse = await fetch(`${baseUrl}/api/managed-actions/dry-run`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        instanceId: "tom",
        action: "healthcheck",
        operator: "Anan",
        reason: "真实执行前的 dry-run 引用",
        confirmedText: "DRY-RUN-ONLY",
      }),
    });
    assert.equal(dryRunResponse.status, 200);
    const dryRun = await dryRunResponse.json() as { review: { operationRequestId: string } };

    const liveResponse = await fetch(`${baseUrl}/api/managed-actions/live`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        instanceId: "tom",
        action: "healthcheck",
        operator: "Anan",
        reason: "显式开关打开后的只读 healthcheck",
        operationRequestId: dryRun.review.operationRequestId,
        confirmedText: "LIVE-ACTION-APPROVED",
      }),
    });
    assert.equal(liveResponse.status, 200);
    const live = await liveResponse.json() as {
      ok: boolean;
      status: string;
      liveExecution: boolean;
      gate: { enabled: boolean; readonlyMode: boolean };
      rollout: { allowed: boolean; status: string };
      dryRunReference: { valid: boolean; status: string };
      executor: { productionWired: boolean; status: string };
      safety: { mutatesOpenClawInstance: boolean };
    };
    assert.equal(live.ok, true);
    assert.equal(live.status, "executed_readonly_healthcheck");
    assert.equal(live.liveExecution, true);
    assert.equal(live.gate.enabled, true);
    assert.equal(live.gate.readonlyMode, false);
    assert.equal(live.rollout.allowed, true);
    assert.equal(live.rollout.status, "allowed");
    assert.equal(live.dryRunReference.valid, true);
    assert.equal(live.dryRunReference.status, "valid");
    assert.equal(live.executor.productionWired, true);
    assert.equal(live.executor.status, "wired");
    assert.equal(live.safety.mutatesOpenClawInstance, false);

    const readinessResponse = await fetch(`${baseUrl}/api/managed-actions/readiness`);
    assert.equal(readinessResponse.status, 200);
    const readiness = await readinessResponse.json() as {
      liveExecutionAvailable: boolean;
      executor: { productionWired: boolean; status: string };
    };
    assert.equal(readiness.liveExecutionAvailable, true);
    assert.equal(readiness.executor.productionWired, true);
    assert.equal(readiness.executor.status, "wired");
  } finally {
    if (server.listening) {
      await new Promise<void>((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
    }
    if (previousInstancesJson === undefined) {
      delete process.env.OPENCLAW_INSTANCES_JSON;
    } else {
      process.env.OPENCLAW_INSTANCES_JSON = previousInstancesJson;
    }
    if (previousInstancesFile === undefined) {
      delete process.env.OPENCLAW_INSTANCES_FILE;
    } else {
      process.env.OPENCLAW_INSTANCES_FILE = previousInstancesFile;
    }
  }
});
