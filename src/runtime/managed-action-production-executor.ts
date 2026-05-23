import type { ManagedActionExecutor } from "./managed-action-executor";
import type { AgentRunThinkingLevel } from "../contracts/openclaw-tools";
import { createScopedToolClient } from "../clients/factory";
import { buildCollectorSnapshot, selectCollectorExportScope, writeCollectorSnapshotFile } from "./collector-exporter";
import { loadOpenClawInstanceConfigs } from "./instance-config";
import {
  evaluateManagedActionSkillRunPolicy,
  runtimeManagedActionSkillRunPolicy,
  type ManagedActionSkillRunPolicy,
} from "./managed-action-skill-run-policy";

export function createProductionManagedActionExecutor(options: {
  skillRunPolicy?: ManagedActionSkillRunPolicy;
} = {}): ManagedActionExecutor {
  return {
    async healthcheck(input) {
      const client = createScopedToolClient(input.instance);
      try {
        const [sessions, cron] = await Promise.all([
          client.sessionsList(),
          client.cronList(),
        ]);
        const sessionCount = sessions.sessions?.length ?? 0;
        const cronCount = cron.jobs?.length ?? 0;
        return {
          ok: true,
          status: "executed_readonly_healthcheck",
          liveExecution: true,
          mutatesOpenClawInstance: false,
          action: input.action,
          targetInstanceId: input.instance.id,
          operationRequestId: input.operationRequestId,
          detail: `Healthcheck completed for ${input.instance.id}: sessions=${sessionCount}, cronJobs=${cronCount}.`,
        };
      } catch (error) {
        return {
          ok: false,
          status: "failed_healthcheck",
          liveExecution: true,
          mutatesOpenClawInstance: false,
          action: input.action,
          targetInstanceId: input.instance.id,
          operationRequestId: input.operationRequestId,
          detail: `Healthcheck failed for ${input.instance.id}: ${formatError(error)}`,
        };
      }
    },

    async collector_refresh(input) {
      try {
        const config = loadOpenClawInstanceConfigs();
        const scope = selectCollectorExportScope(config, input.instance.serverId);
        const outputPath = scope.instances.find((instance) => instance.collectorSnapshotPath)?.collectorSnapshotPath;
        if (!outputPath) {
          return {
            ok: false,
            status: "failed_collector_refresh",
            liveExecution: true,
            mutatesOpenClawInstance: false,
            action: input.action,
            targetInstanceId: input.instance.id,
            operationRequestId: input.operationRequestId,
            detail: `Collector refresh failed for ${input.instance.id}: collectorSnapshotPath is not configured.`,
          };
        }
        const snapshot = await buildCollectorSnapshot({
          instances: scope.instances,
          serverId: scope.serverId,
          serverName: scope.serverName,
        });
        const written = await writeCollectorSnapshotFile(snapshot, outputPath);
        return {
          ok: true,
          status: "executed_collector_refresh",
          liveExecution: true,
          mutatesOpenClawInstance: false,
          action: input.action,
          targetInstanceId: input.instance.id,
          operationRequestId: input.operationRequestId,
          detail: `Collector snapshot refreshed at ${written.path}: instances=${written.instances}.`,
        };
      } catch (error) {
        return {
          ok: false,
          status: "failed_collector_refresh",
          liveExecution: true,
          mutatesOpenClawInstance: false,
          action: input.action,
          targetInstanceId: input.instance.id,
          operationRequestId: input.operationRequestId,
          detail: `Collector refresh failed for ${input.instance.id}: ${formatError(error)}`,
        };
      }
    },

    async skill_run(input) {
      const skillName = input.skillName?.trim();
      const message = input.message?.trim();
      const hasAgentTarget = Boolean(input.agentId?.trim() || input.sessionKey?.trim() || input.sessionId?.trim());
      if (!skillName || !message || !hasAgentTarget) {
        return {
          ok: false,
          status: "blocked_invalid_payload",
          liveExecution: false,
          mutatesOpenClawInstance: false,
          action: input.action,
          targetInstanceId: input.instance.id,
          operationRequestId: input.operationRequestId,
          detail: "skill_run requires skillName, message, and one of agentId/sessionKey/sessionId.",
        };
      }
      const policy = evaluateManagedActionSkillRunPolicy({
        policy: options.skillRunPolicy ?? runtimeManagedActionSkillRunPolicy(),
        instanceId: input.instance.id,
        skillName,
        agentId: input.agentId,
        sessionKey: input.sessionKey,
        sessionId: input.sessionId,
        message,
        timeoutSeconds: input.timeoutSeconds,
        deliver: input.deliver,
      });
      if (!policy.allowed) {
        return {
          ok: false,
          status: "blocked_invalid_payload",
          liveExecution: false,
          mutatesOpenClawInstance: false,
          action: input.action,
          targetInstanceId: input.instance.id,
          operationRequestId: input.operationRequestId,
          detail: policy.detail,
        };
      }

      const client = createScopedToolClient(input.instance);
      if (!client.agentRun) {
        return {
          ok: false,
          status: "executor_missing",
          liveExecution: false,
          mutatesOpenClawInstance: false,
          action: input.action,
          targetInstanceId: input.instance.id,
          operationRequestId: input.operationRequestId,
          detail: "The scoped OpenClaw client does not expose agentRun.",
        };
      }

      try {
        const before = await client.sessionsList();
        const result = await client.agentRun({
          agentId: input.agentId,
          sessionKey: input.sessionKey,
          sessionId: input.sessionId,
          message,
          thinking: normalizeThinking(input.thinking),
          timeoutSeconds: input.timeoutSeconds,
          deliver: input.deliver,
          context: {
            surface: "control-center-managed-action",
            ...(input.instance.workspaceRoot ? { workspaceRoot: input.instance.workspaceRoot } : {}),
          },
        });
        const after = await client.sessionsList();
        const beforeCount = before.sessions?.length ?? 0;
        const afterCount = after.sessions?.length ?? 0;
        return {
          ok: result.ok,
          status: result.ok ? "executed_skill_run" : "failed_skill_run",
          liveExecution: true,
          mutatesOpenClawInstance: true,
          action: input.action,
          targetInstanceId: input.instance.id,
          operationRequestId: input.operationRequestId,
          detail: [
            `Skill run completed for ${input.instance.id}: skill=${skillName}, status=${result.status ?? String(result.ok)}.`,
            `sessionsBefore=${beforeCount}, sessionsAfter=${afterCount}.`,
            result.sessionKey ? `sessionKey=${result.sessionKey}.` : undefined,
            result.runId ? `runId=${result.runId}.` : undefined,
            result.summary ? `summary=${truncate(result.summary, 240)}` : undefined,
          ].filter((item): item is string => Boolean(item)).join(" "),
        };
      } catch (error) {
        return {
          ok: false,
          status: "failed_skill_run",
          liveExecution: true,
          mutatesOpenClawInstance: true,
          action: input.action,
          targetInstanceId: input.instance.id,
          operationRequestId: input.operationRequestId,
          detail: `Skill run failed for ${input.instance.id}: ${formatError(error)}`,
        };
      }
    },
  };
}

function normalizeThinking(input: AgentRunThinkingLevel | undefined): AgentRunThinkingLevel {
  switch (input) {
    case "off":
    case "minimal":
    case "low":
    case "medium":
    case "high":
    case "xhigh":
      return input;
    default:
      return "minimal";
  }
}

function formatError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function truncate(value: string, maxLength: number): string {
  return value.length <= maxLength ? value : `${value.slice(0, Math.max(0, maxLength - 3))}...`;
}
