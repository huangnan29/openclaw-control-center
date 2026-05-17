import assert from "node:assert/strict";
import test from "node:test";
import {
  createMockHealthcheckExecutor,
  runManagedActionExecutor,
} from "../src/runtime/managed-action-executor";

const instance = {
  id: "tom",
  name: "Tom",
  gatewayUrl: "ws://127.0.0.1:18791",
  openclawHome: "/instances/tom/config",
  openclawConfigPath: "/instances/tom/config/openclaw.json",
  workspaceRoot: "/instances/tom/workspace",
  readonly: true,
};

test("managed action executor refuses to run when the live gate is not ready", async () => {
  let called = false;
  const result = await runManagedActionExecutor(
    {
      action: "healthcheck",
      instance,
      operationRequestId: "dry-run-1",
      operator: "Anan",
      reason: "测试闸门阻断",
      gateReady: false,
    },
    {
      async healthcheck() {
        called = true;
        throw new Error("executor should not be called");
      },
    },
  );

  assert.equal(called, false);
  assert.equal(result.ok, false);
  assert.equal(result.status, "blocked_by_gate");
  assert.equal(result.liveExecution, false);
});

test("managed action executor can run a mock healthcheck only when the gate is ready", async () => {
  const result = await runManagedActionExecutor(
    {
      action: "healthcheck",
      instance,
      operationRequestId: "dry-run-2",
      operator: "Anan",
      reason: "测试 mock executor",
      gateReady: true,
    },
    createMockHealthcheckExecutor(),
  );

  assert.equal(result.ok, true);
  assert.equal(result.status, "executed_mock");
  assert.equal(result.liveExecution, true);
  assert.equal(result.targetInstanceId, "tom");
  assert.equal(result.operationRequestId, "dry-run-2");
});

test("managed action executor reports missing executors without live execution", async () => {
  const result = await runManagedActionExecutor(
    {
      action: "skill_run",
      instance,
      operationRequestId: "dry-run-3",
      operator: "Anan",
      reason: "测试未注册执行器",
      gateReady: true,
    },
    createMockHealthcheckExecutor(),
  );

  assert.equal(result.ok, false);
  assert.equal(result.status, "executor_missing");
  assert.equal(result.liveExecution, false);
});
