import type { OpenClawInstanceConfig } from "../types";
import type { ManagedActionName } from "./managed-actions";
import type { ManagedActionLiveGate } from "./managed-action-live";
import type { OperationAuditInput } from "./operation-audit";

export type ManagedActionLiveAuditOutcome = "executed" | "failed" | "rolled_back" | "skipped";
export type ManagedActionRollbackStatus = "not_required" | "pending" | "completed" | "failed";

export interface ManagedActionLiveAuditInput {
  outcome: ManagedActionLiveAuditOutcome;
  source: OperationAuditInput["source"];
  action: ManagedActionName;
  instance: OpenClawInstanceConfig;
  operationRequestId: string;
  requestId?: string;
  operator: string;
  reason: string;
  executor: string;
  startedAt: string;
  finishedAt: string;
  gate: ManagedActionLiveGate;
  commandPreview?: string[];
  mutatesOpenClawInstance?: boolean;
  result?: {
    message?: string;
    exitCode?: number;
    artifactPaths?: string[];
  };
  error?: {
    code?: string;
    message: string;
  };
  rollback?: {
    status: ManagedActionRollbackStatus;
    detail?: string;
    artifactPaths?: string[];
  };
  skip?: {
    reason: string;
  };
}

export interface ManagedActionLiveAuditMetadata extends Record<string, unknown> {
  managedAction: ManagedActionName;
  outcome: ManagedActionLiveAuditOutcome;
  operationRequestId: string;
  operator: string;
  reason: string;
  executor: string;
  liveExecution: boolean;
  mutatesOpenClawInstance: boolean;
  startedAt: string;
  finishedAt: string;
  durationMs: number;
  target: {
    instanceId: string;
    instanceName: string;
    gatewayUrl: string;
    readonly: boolean;
    serverId?: string;
    serverName?: string;
  };
  gate: {
    enabled: boolean;
    readonlyMode: boolean;
    allowedActions: ManagedActionName[];
  };
  commandPreview: string[];
  result?: {
    message?: string;
    exitCode?: number;
    artifactPaths?: string[];
  };
  error?: {
    code?: string;
    message: string;
  };
  rollback: {
    required: boolean;
    status: ManagedActionRollbackStatus;
    detail?: string;
    artifactPaths?: string[];
  };
  skip?: {
    reason: string;
  };
}

export function buildManagedActionLiveAuditEntry(input: ManagedActionLiveAuditInput): OperationAuditInput {
  const metadata = buildManagedActionLiveAuditMetadata(input);
  return {
    action: "managed_action_live_result",
    source: input.source,
    ok: input.outcome === "executed" || input.outcome === "skipped",
    requestId: input.requestId,
    detail: buildManagedActionLiveAuditDetail(input, metadata),
    metadata,
  };
}

export function buildManagedActionLiveAuditMetadata(
  input: ManagedActionLiveAuditInput,
): ManagedActionLiveAuditMetadata {
  const durationMs = Math.max(0, Date.parse(input.finishedAt) - Date.parse(input.startedAt));
  const liveExecution = input.outcome !== "skipped";
  const mutatesOpenClawInstance = input.mutatesOpenClawInstance ?? liveExecution;
  const rollbackStatus = input.rollback?.status ?? (input.outcome === "rolled_back" ? "completed" : "not_required");
  return {
    managedAction: input.action,
    outcome: input.outcome,
    operationRequestId: input.operationRequestId,
    operator: input.operator,
    reason: input.reason,
    executor: input.executor,
    liveExecution,
    mutatesOpenClawInstance,
    startedAt: input.startedAt,
    finishedAt: input.finishedAt,
    durationMs,
    target: {
      instanceId: input.instance.id,
      instanceName: input.instance.name,
      gatewayUrl: input.instance.gatewayUrl,
      readonly: input.instance.readonly ?? true,
      ...(input.instance.serverId ? { serverId: input.instance.serverId } : {}),
      ...(input.instance.serverName ? { serverName: input.instance.serverName } : {}),
    },
    gate: {
      enabled: input.gate.enabled,
      readonlyMode: input.gate.readonlyMode,
      allowedActions: [...input.gate.allowedActions],
    },
    commandPreview: input.commandPreview ?? [],
    ...(input.result ? { result: input.result } : {}),
    ...(input.error ? { error: input.error } : {}),
    rollback: {
      required: input.outcome === "rolled_back" || rollbackStatus !== "not_required",
      status: rollbackStatus,
      ...(input.rollback?.detail ? { detail: input.rollback.detail } : {}),
      ...(input.rollback?.artifactPaths ? { artifactPaths: input.rollback.artifactPaths } : {}),
    },
    ...(input.skip ? { skip: input.skip } : {}),
  };
}

function buildManagedActionLiveAuditDetail(
  input: ManagedActionLiveAuditInput,
  metadata: ManagedActionLiveAuditMetadata,
): string {
  if (input.outcome === "executed") {
    return `executed ${input.action} for ${metadata.target.instanceId}`;
  }
  if (input.outcome === "failed") {
    return `failed ${input.action} for ${metadata.target.instanceId}`;
  }
  if (input.outcome === "rolled_back") {
    return `rolled back ${input.action} for ${metadata.target.instanceId}`;
  }
  return `skipped ${input.action} for ${metadata.target.instanceId}`;
}
