import type { ManagedActionAuditSnapshot } from "./managed-action-audit";
import { MANAGED_ACTION_DRY_RUN_REFERENCE_MAX_AGE_MS } from "./managed-action-audit";
import type { ManagedActionLiveGate } from "./managed-action-live";
import type { ManagedActionLiveRolloutConfig, ManagedActionLiveRolloutRule } from "./managed-action-live-rollout";
import type { ManagedActionName } from "./managed-actions";

export type ManagedActionLiveReadinessStatus = "blocked" | "review_required" | "ready";
export type ManagedActionLiveReadinessFindingSeverity = "block" | "review";
export type ManagedActionLiveReadinessFindingId =
  | "live_gate_disabled"
  | "readonly_mode_enabled"
  | "live_action_whitelist_empty"
  | "rollout_config_disabled"
  | "rollout_config_issues"
  | "rollout_enabled_rules_empty"
  | "production_executor_missing"
  | "dry_run_audit_empty";

export interface ManagedActionLiveReadinessFinding {
  id: ManagedActionLiveReadinessFindingId;
  severity: ManagedActionLiveReadinessFindingSeverity;
  detail: string;
}

export interface ManagedActionLiveReadinessSnapshot {
  ok: true;
  generatedAt: string;
  status: ManagedActionLiveReadinessStatus;
  liveExecutionAvailable: boolean;
  liveExecutionAttempted: false;
  mutatesOpenClawInstance: false;
  gate: {
    enabled: boolean;
    readonlyMode: boolean;
    allowedActions: ManagedActionName[];
    requiredConfirmationText: string;
  };
  rollout: {
    source: ManagedActionLiveRolloutConfig["source"];
    path?: string;
    enabled: boolean;
    rulesTotal: number;
    enabledRules: number;
    actions: ManagedActionName[];
    instances: string[];
    issues: string[];
  };
  dryRun: {
    auditPath: string;
    count: number;
    latest?: {
      timestamp: string;
      operationRequestId?: string;
      action?: ManagedActionName;
      targetInstanceId?: string;
      operator?: string;
    };
    referenceMaxAgeMs: number;
  };
  executor: {
    productionWired: boolean;
    status: "missing" | "wired";
    mockOnly: boolean;
  };
  findings: ManagedActionLiveReadinessFinding[];
  blockers: ManagedActionLiveReadinessFinding[];
  reviewItems: ManagedActionLiveReadinessFinding[];
}

export function buildManagedActionLiveReadiness(input: {
  gate: ManagedActionLiveGate;
  rolloutConfig: ManagedActionLiveRolloutConfig;
  dryRunAudit: ManagedActionAuditSnapshot;
  productionExecutorWired?: boolean;
  generatedAt?: string;
}): ManagedActionLiveReadinessSnapshot {
  const productionExecutorWired = input.productionExecutorWired === true;
  const enabledRules = input.rolloutConfig.rules.filter((rule) => rule.enabled);
  const findings = buildFindings({
    gate: input.gate,
    rolloutConfig: input.rolloutConfig,
    enabledRules,
    dryRunAudit: input.dryRunAudit,
    productionExecutorWired,
  });
  const blockers = findings.filter((finding) => finding.severity === "block");
  const reviewItems = findings.filter((finding) => finding.severity === "review");
  const status: ManagedActionLiveReadinessStatus =
    blockers.length > 0 ? "blocked" : reviewItems.length > 0 ? "review_required" : "ready";
  const liveExecutionAvailable = status === "ready";
  const latestDryRun = input.dryRunAudit.records[0];

  return {
    ok: true,
    generatedAt: input.generatedAt ?? new Date().toISOString(),
    status,
    liveExecutionAvailable,
    liveExecutionAttempted: false,
    mutatesOpenClawInstance: false,
    gate: {
      enabled: input.gate.enabled,
      readonlyMode: input.gate.readonlyMode,
      allowedActions: input.gate.allowedActions,
      requiredConfirmationText: input.gate.requiredConfirmationText,
    },
    rollout: {
      source: input.rolloutConfig.source,
      ...(input.rolloutConfig.path ? { path: input.rolloutConfig.path } : {}),
      enabled: input.rolloutConfig.enabled,
      rulesTotal: input.rolloutConfig.rules.length,
      enabledRules: enabledRules.length,
      actions: uniqueSorted(enabledRules.map((rule) => rule.action)),
      instances: uniqueSorted(enabledRules.map((rule) => rule.instanceId)),
      issues: input.rolloutConfig.issues,
    },
    dryRun: {
      auditPath: input.dryRunAudit.path,
      count: input.dryRunAudit.count,
      ...(latestDryRun
        ? {
            latest: {
              timestamp: latestDryRun.timestamp,
              ...(latestDryRun.operationRequestId ? { operationRequestId: latestDryRun.operationRequestId } : {}),
              ...(latestDryRun.action ? { action: latestDryRun.action } : {}),
              ...(latestDryRun.targetInstanceId ? { targetInstanceId: latestDryRun.targetInstanceId } : {}),
              ...(latestDryRun.operator ? { operator: latestDryRun.operator } : {}),
            },
          }
        : {}),
      referenceMaxAgeMs: MANAGED_ACTION_DRY_RUN_REFERENCE_MAX_AGE_MS,
    },
    executor: {
      productionWired: productionExecutorWired,
      status: productionExecutorWired ? "wired" : "missing",
      mockOnly: !productionExecutorWired,
    },
    findings,
    blockers,
    reviewItems,
  };
}

function buildFindings(input: {
  gate: ManagedActionLiveGate;
  rolloutConfig: ManagedActionLiveRolloutConfig;
  enabledRules: ManagedActionLiveRolloutRule[];
  dryRunAudit: ManagedActionAuditSnapshot;
  productionExecutorWired: boolean;
}): ManagedActionLiveReadinessFinding[] {
  const findings: ManagedActionLiveReadinessFinding[] = [];
  if (!input.gate.enabled) {
    findings.push({
      id: "live_gate_disabled",
      severity: "block",
      detail: "MANAGED_ACTIONS_LIVE_ENABLED is not enabled.",
    });
  }
  if (input.gate.readonlyMode) {
    findings.push({
      id: "readonly_mode_enabled",
      severity: "block",
      detail: "READONLY_MODE is enabled.",
    });
  }
  if (input.gate.allowedActions.length === 0) {
    findings.push({
      id: "live_action_whitelist_empty",
      severity: "block",
      detail: "MANAGED_ACTIONS_LIVE_ALLOWED_ACTIONS does not contain a valid managed action.",
    });
  }
  if (!input.rolloutConfig.enabled) {
    findings.push({
      id: "rollout_config_disabled",
      severity: "block",
      detail: "Managed action live rollout config is disabled or missing.",
    });
  }
  if (input.rolloutConfig.issues.length > 0) {
    findings.push({
      id: "rollout_config_issues",
      severity: "block",
      detail: input.rolloutConfig.issues.join("; "),
    });
  }
  if (input.rolloutConfig.enabled && input.enabledRules.length === 0) {
    findings.push({
      id: "rollout_enabled_rules_empty",
      severity: "block",
      detail: "Managed action live rollout config has no enabled rules.",
    });
  }
  if (!input.productionExecutorWired) {
    findings.push({
      id: "production_executor_missing",
      severity: "block",
      detail: "No production managed action executor is wired.",
    });
  }
  if (input.dryRunAudit.count === 0) {
    findings.push({
      id: "dry_run_audit_empty",
      severity: "review",
      detail: "No dry-run audit record is visible for live request reference checks.",
    });
  }
  return findings;
}

function uniqueSorted<T extends string>(items: T[]): T[] {
  return [...new Set(items)].sort((a, b) => a.localeCompare(b));
}
