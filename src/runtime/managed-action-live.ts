import {
  MANAGED_ACTIONS_LIVE_ALLOWED_ACTIONS,
  MANAGED_ACTIONS_LIVE_ENABLED,
  READONLY_MODE,
} from "../config";
import {
  isManagedActionName,
  type ManagedActionName,
} from "./managed-actions";

export const MANAGED_ACTION_LIVE_CONFIRMATION = "LIVE-ACTION-APPROVED";

export interface ManagedActionLiveGate {
  enabled: boolean;
  readonlyMode: boolean;
  allowedActions: ManagedActionName[];
  requiredConfirmationText: typeof MANAGED_ACTION_LIVE_CONFIRMATION;
}

export interface ManagedActionLiveGateDecision {
  ok: boolean;
  statusCode: number;
  status:
    | "blocked_disabled"
    | "blocked_readonly"
    | "blocked_not_whitelisted"
    | "blocked_confirmation"
    | "blocked_missing_dry_run"
    | "blocked_invalid_dry_run"
    | "blocked_rollout_not_allowed"
    | "blocked_skill_run_policy"
    | "ready"
    | "ready_not_implemented";
  message: string;
  liveExecution: false;
}

export function runtimeManagedActionLiveGate(): ManagedActionLiveGate {
  return {
    enabled: MANAGED_ACTIONS_LIVE_ENABLED,
    readonlyMode: READONLY_MODE,
    allowedActions: MANAGED_ACTIONS_LIVE_ALLOWED_ACTIONS.filter(isManagedActionName),
    requiredConfirmationText: MANAGED_ACTION_LIVE_CONFIRMATION,
  };
}

export function evaluateManagedActionLiveGate(input: {
  gate: ManagedActionLiveGate;
  action: ManagedActionName;
  operationRequestId?: string;
  dryRunReferenceValid?: boolean;
  rolloutAllowed?: boolean;
  skillRunPolicyAllowed?: boolean;
  executorWired?: boolean;
  confirmedText?: string;
}): ManagedActionLiveGateDecision {
  if (!input.gate.enabled) {
    return blocked("blocked_disabled", "Managed action live execution is disabled.", 403);
  }
  if (input.gate.readonlyMode) {
    return blocked("blocked_readonly", "Managed action live execution is blocked while READONLY_MODE is enabled.", 403);
  }
  if (!input.gate.allowedActions.includes(input.action)) {
    return blocked("blocked_not_whitelisted", `Managed action '${input.action}' is not whitelisted for live execution.`, 403);
  }
  if (!input.operationRequestId) {
    return blocked("blocked_missing_dry_run", "A prior dry-run operationRequestId is required before live execution.", 400);
  }
  if (input.dryRunReferenceValid !== true) {
    return blocked("blocked_invalid_dry_run", "The referenced dry-run request is not valid for live execution.", 400);
  }
  if (input.confirmedText !== input.gate.requiredConfirmationText) {
    return blocked(
      "blocked_confirmation",
      `confirmedText must equal ${input.gate.requiredConfirmationText}.`,
      400,
    );
  }
  if (input.rolloutAllowed !== true) {
    return blocked("blocked_rollout_not_allowed", "Managed action live rollout config does not allow this request.", 403);
  }
  if (input.action === "skill_run" && input.skillRunPolicyAllowed !== true) {
    return blocked("blocked_skill_run_policy", "Managed action skill_run is blocked by skill-run live policy.", 403);
  }

  if (input.executorWired === true) {
    return {
      ok: true,
      statusCode: 200,
      status: "ready",
      message: "Managed action live execution passed the gate and a live executor is wired.",
      liveExecution: false,
    };
  }

  return {
    ok: false,
    statusCode: 501,
    status: "ready_not_implemented",
    message: "Managed action live execution passed the gate but no live executor is implemented yet.",
    liveExecution: false,
  };
}

function blocked(
  status: ManagedActionLiveGateDecision["status"],
  message: string,
  statusCode: number,
): ManagedActionLiveGateDecision {
  return {
    ok: false,
    statusCode,
    status,
    message,
    liveExecution: false,
  };
}
