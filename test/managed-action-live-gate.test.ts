import assert from "node:assert/strict";
import test from "node:test";
import {
  evaluateManagedActionLiveGate,
  MANAGED_ACTION_LIVE_CONFIRMATION,
} from "../src/runtime/managed-action-live";

const readyGate = {
  enabled: true,
  readonlyMode: false,
  allowedActions: ["healthcheck" as const],
  requiredConfirmationText: MANAGED_ACTION_LIVE_CONFIRMATION,
};

test("managed action live gate blocks when rollout does not allow the request", () => {
  const decision = evaluateManagedActionLiveGate({
    gate: readyGate,
    action: "healthcheck",
    operationRequestId: "dry-run-1",
    dryRunReferenceValid: true,
    rolloutAllowed: false,
    confirmedText: MANAGED_ACTION_LIVE_CONFIRMATION,
  });

  assert.equal(decision.ok, false);
  assert.equal(decision.status, "blocked_rollout_not_allowed");
  assert.equal(decision.liveExecution, false);
});

test("managed action live gate reaches not implemented only after all safety checks pass", () => {
  const decision = evaluateManagedActionLiveGate({
    gate: readyGate,
    action: "healthcheck",
    operationRequestId: "dry-run-1",
    dryRunReferenceValid: true,
    rolloutAllowed: true,
    confirmedText: MANAGED_ACTION_LIVE_CONFIRMATION,
  });

  assert.equal(decision.ok, false);
  assert.equal(decision.status, "ready_not_implemented");
  assert.equal(decision.liveExecution, false);
});

test("managed action live gate is ready only when the production executor is explicitly wired", () => {
  const decision = evaluateManagedActionLiveGate({
    gate: readyGate,
    action: "healthcheck",
    operationRequestId: "dry-run-1",
    dryRunReferenceValid: true,
    rolloutAllowed: true,
    executorWired: true,
    confirmedText: MANAGED_ACTION_LIVE_CONFIRMATION,
  });

  assert.equal(decision.ok, true);
  assert.equal(decision.status, "ready");
  assert.equal(decision.statusCode, 200);
  assert.equal(decision.liveExecution, false);
});
