import type { OpenClawInstanceConfig } from "../types";
import type { AgentRunThinkingLevel } from "../contracts/openclaw-tools";
import type { ManagedActionName } from "./managed-actions";

export interface ManagedActionExecutionInput {
  action: ManagedActionName;
  instance: OpenClawInstanceConfig;
  operationRequestId: string;
  operator: string;
  reason: string;
  gateReady: boolean;
  skillName?: string;
  agentId?: string;
  sessionKey?: string;
  sessionId?: string;
  message?: string;
  thinking?: AgentRunThinkingLevel;
  timeoutSeconds?: number;
  deliver?: boolean;
}

export interface ManagedActionExecutionResult {
  ok: boolean;
  status:
    | "executed_mock"
    | "executed_readonly_healthcheck"
    | "executed_collector_refresh"
    | "executed_skill_run"
    | "failed_healthcheck"
    | "failed_collector_refresh"
    | "failed_skill_run"
    | "blocked_invalid_payload"
    | "blocked_by_gate"
    | "executor_missing";
  liveExecution: boolean;
  mutatesOpenClawInstance: boolean;
  action: ManagedActionName;
  targetInstanceId: string;
  operationRequestId: string;
  detail: string;
}

export type ManagedActionExecutor = Partial<Record<
  ManagedActionName,
  (input: ManagedActionExecutionInput) => Promise<ManagedActionExecutionResult>
>>;

export async function runManagedActionExecutor(
  input: ManagedActionExecutionInput,
  executor: ManagedActionExecutor,
): Promise<ManagedActionExecutionResult> {
  if (!input.gateReady) {
    return {
      ok: false,
      status: "blocked_by_gate",
      liveExecution: false,
      mutatesOpenClawInstance: false,
      action: input.action,
      targetInstanceId: input.instance.id,
      operationRequestId: input.operationRequestId,
      detail: "Managed action execution is blocked because the live gate is not ready.",
    };
  }

  const handler = executor[input.action];
  if (!handler) {
    return {
      ok: false,
      status: "executor_missing",
      liveExecution: false,
      mutatesOpenClawInstance: false,
      action: input.action,
      targetInstanceId: input.instance.id,
      operationRequestId: input.operationRequestId,
      detail: `No executor is registered for managed action '${input.action}'.`,
    };
  }

  return await handler(input);
}

export function createMockHealthcheckExecutor(): ManagedActionExecutor {
  return {
    async healthcheck(input) {
      return {
        ok: true,
        status: "executed_mock",
        liveExecution: true,
        mutatesOpenClawInstance: true,
        action: input.action,
        targetInstanceId: input.instance.id,
        operationRequestId: input.operationRequestId,
        detail: `Mock healthcheck completed for ${input.instance.id}.`,
      };
    },
  };
}
