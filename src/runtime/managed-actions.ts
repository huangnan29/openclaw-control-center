import type { OpenClawInstanceConfig } from "../types";

export type ManagedActionName = "healthcheck" | "collector_refresh" | "skill_run";
export const MANAGED_ACTION_DRY_RUN_CONFIRMATION = "DRY-RUN-ONLY";

export interface ManagedActionDefinition {
  action: ManagedActionName;
  label: string;
  description: string;
  mutatesOpenClawInstance: boolean;
}

export interface ManagedActionDryRunInput {
  action: ManagedActionName;
  instance: OpenClawInstanceConfig;
  operationRequestId: string;
  operator: string;
  reason: string;
  confirmedText: string;
  skillName?: string;
}

export interface ManagedActionDryRunResult {
  ok: true;
  status: "dry_run_ready";
  dryRun: true;
  liveExecution: false;
  action: ManagedActionName;
  label: string;
  target: {
    instanceId: string;
    instanceName: string;
    serverId?: string;
    serverName?: string;
  };
  commandPreview: string[];
  safety: {
    mutatesOpenClawInstance: false;
    requiresConfirmation: true;
    auditRequired: true;
  };
  review: {
    operationRequestId: string;
    createdAt: string;
    operator: string;
    reason: string;
    requiredConfirmationText: typeof MANAGED_ACTION_DRY_RUN_CONFIRMATION;
    confirmationTextMatched: true;
    targetConfigSnapshot: {
      instanceId: string;
      instanceName: string;
      gatewayUrl: string;
      readonly: boolean;
      serverId?: string;
      serverName?: string;
    };
  };
}

const ACTIONS: ManagedActionDefinition[] = [
  {
    action: "healthcheck",
    label: "Control-center healthcheck",
    description: "Preview a readonly healthcheck for the selected instance scope.",
    mutatesOpenClawInstance: false,
  },
  {
    action: "collector_refresh",
    label: "Collector snapshot refresh",
    description: "Preview a collector snapshot refresh. The dry-run never runs the collector.",
    mutatesOpenClawInstance: false,
  },
  {
    action: "skill_run",
    label: "Skill invocation",
    description: "Preview a future OpenClaw skill invocation. The dry-run does not call OpenClaw.",
    mutatesOpenClawInstance: false,
  },
];

export function listManagedActions(): ManagedActionDefinition[] {
  return ACTIONS.map((action) => ({ ...action }));
}

export function isManagedActionName(input: string): input is ManagedActionName {
  return ACTIONS.some((action) => action.action === input);
}

export function buildManagedActionDryRun(input: ManagedActionDryRunInput): ManagedActionDryRunResult {
  const definition = ACTIONS.find((action) => action.action === input.action);
  if (!definition) {
    throw new Error(`unsupported managed action: ${input.action}`);
  }
  if (input.confirmedText !== MANAGED_ACTION_DRY_RUN_CONFIRMATION) {
    throw new Error(`confirmedText must equal ${MANAGED_ACTION_DRY_RUN_CONFIRMATION}`);
  }

  return {
    ok: true,
    status: "dry_run_ready",
    dryRun: true,
    liveExecution: false,
    action: input.action,
    label: definition.label,
    target: {
      instanceId: input.instance.id,
      instanceName: input.instance.name,
      ...(input.instance.serverId ? { serverId: input.instance.serverId } : {}),
      ...(input.instance.serverName ? { serverName: input.instance.serverName } : {}),
    },
    commandPreview: buildCommandPreview(input),
    safety: {
      mutatesOpenClawInstance: false,
      requiresConfirmation: true,
      auditRequired: true,
    },
    review: {
      operationRequestId: input.operationRequestId,
      createdAt: new Date().toISOString(),
      operator: input.operator,
      reason: input.reason,
      requiredConfirmationText: MANAGED_ACTION_DRY_RUN_CONFIRMATION,
      confirmationTextMatched: true,
      targetConfigSnapshot: {
        instanceId: input.instance.id,
        instanceName: input.instance.name,
        gatewayUrl: input.instance.gatewayUrl,
        readonly: input.instance.readonly ?? true,
        ...(input.instance.serverId ? { serverId: input.instance.serverId } : {}),
        ...(input.instance.serverName ? { serverName: input.instance.serverName } : {}),
      },
    },
  };
}

function buildCommandPreview(input: ManagedActionDryRunInput): string[] {
  if (input.action === "healthcheck") {
    return [`control-center healthcheck for instance ${input.instance.id}`];
  }
  if (input.action === "collector_refresh") {
    return [`collector snapshot refresh for server ${input.instance.serverId ?? "local"}`];
  }

  const skillName = input.skillName?.trim() || "<skill-name>";
  return [`openclaw skill dry-run for instance ${input.instance.id}: ${skillName}`];
}
