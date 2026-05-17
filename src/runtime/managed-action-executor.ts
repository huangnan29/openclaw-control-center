import type { OpenClawInstanceConfig } from "../types";
import type { ManagedActionName } from "./managed-actions";

export interface ManagedActionExecutionInput {
  action: ManagedActionName;
  instance: OpenClawInstanceConfig;
  operationRequestId: string;
  operator: string;
  reason: string;
  gateReady: boolean;
}

export interface ManagedActionExecutionResult {
  ok: boolean;
  status: "executed_mock" | "blocked_by_gate" | "executor_missing";
  liveExecution: boolean;
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
        action: input.action,
        targetInstanceId: input.instance.id,
        operationRequestId: input.operationRequestId,
        detail: `Mock healthcheck completed for ${input.instance.id}.`,
      };
    },
  };
}
