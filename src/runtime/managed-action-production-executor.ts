import type { ManagedActionExecutor } from "./managed-action-executor";

export function createProductionManagedActionExecutor(): ManagedActionExecutor {
  return {
    async healthcheck(input) {
      return {
        ok: true,
        status: "executed_readonly_healthcheck",
        liveExecution: true,
        mutatesOpenClawInstance: false,
        action: input.action,
        targetInstanceId: input.instance.id,
        operationRequestId: input.operationRequestId,
        detail: `Readonly healthcheck completed for ${input.instance.id}.`,
      };
    },
  };
}
