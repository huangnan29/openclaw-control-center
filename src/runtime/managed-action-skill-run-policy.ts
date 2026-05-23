import {
  MANAGED_ACTIONS_LIVE_SKILL_RUN_ALLOWED_INSTANCES,
  MANAGED_ACTIONS_LIVE_SKILL_RUN_ALLOWED_SKILLS,
  MANAGED_ACTIONS_LIVE_SKILL_RUN_DELIVER_ENABLED,
  MANAGED_ACTIONS_LIVE_SKILL_RUN_MAX_TIMEOUT_SECONDS,
} from "../config";

export interface ManagedActionSkillRunPolicy {
  allowedSkills: string[];
  allowedInstances: string[];
  maxTimeoutSeconds: number;
  deliverAllowed: boolean;
}

export interface ManagedActionSkillRunPolicyDecision {
  allowed: boolean;
  status:
    | "allowed"
    | "blocked_skill_policy_not_configured"
    | "blocked_skill_not_allowed"
    | "blocked_instance_not_allowed"
    | "blocked_missing_target"
    | "blocked_missing_message"
    | "blocked_timeout_too_large"
    | "blocked_deliver_not_allowed";
  detail: string;
}

export function runtimeManagedActionSkillRunPolicy(): ManagedActionSkillRunPolicy {
  return {
    allowedSkills: normalizeList(MANAGED_ACTIONS_LIVE_SKILL_RUN_ALLOWED_SKILLS),
    allowedInstances: normalizeList(MANAGED_ACTIONS_LIVE_SKILL_RUN_ALLOWED_INSTANCES),
    maxTimeoutSeconds: MANAGED_ACTIONS_LIVE_SKILL_RUN_MAX_TIMEOUT_SECONDS,
    deliverAllowed: MANAGED_ACTIONS_LIVE_SKILL_RUN_DELIVER_ENABLED,
  };
}

export function evaluateManagedActionSkillRunPolicy(input: {
  policy: ManagedActionSkillRunPolicy;
  instanceId: string;
  skillName?: string;
  agentId?: string;
  sessionKey?: string;
  sessionId?: string;
  message?: string;
  timeoutSeconds?: number;
  deliver?: boolean;
}): ManagedActionSkillRunPolicyDecision {
  const skillName = input.skillName?.trim();
  const hasTarget = Boolean(input.agentId?.trim() || input.sessionKey?.trim() || input.sessionId?.trim());
  const hasMessage = Boolean(input.message?.trim());
  if (input.policy.allowedSkills.length === 0 || input.policy.allowedInstances.length === 0) {
    return blocked("blocked_skill_policy_not_configured", "skill_run live policy requires allowed skills and allowed instances.");
  }
  if (!skillName || !input.policy.allowedSkills.includes(skillName)) {
    return blocked("blocked_skill_not_allowed", "skill_run skillName is not allowed by live policy.");
  }
  if (!input.policy.allowedInstances.includes(input.instanceId)) {
    return blocked("blocked_instance_not_allowed", "skill_run target instance is not allowed by live policy.");
  }
  if (!hasTarget) {
    return blocked("blocked_missing_target", "skill_run requires one of agentId, sessionKey, or sessionId.");
  }
  if (!hasMessage) {
    return blocked("blocked_missing_message", "skill_run requires a non-empty message.");
  }
  if (
    input.timeoutSeconds !== undefined
    && Number.isFinite(input.timeoutSeconds)
    && input.timeoutSeconds > input.policy.maxTimeoutSeconds
  ) {
    return blocked("blocked_timeout_too_large", "skill_run timeoutSeconds exceeds live policy.");
  }
  if (input.deliver === true && !input.policy.deliverAllowed) {
    return blocked("blocked_deliver_not_allowed", "skill_run deliver=true is not allowed by live policy.");
  }
  return {
    allowed: true,
    status: "allowed",
    detail: "skill_run live policy allows this request.",
  };
}

function normalizeList(items: string[]): string[] {
  return [...new Set(items.map((item) => item.trim()).filter(Boolean))].sort((a, b) => a.localeCompare(b));
}

function blocked(
  status: ManagedActionSkillRunPolicyDecision["status"],
  detail: string,
): ManagedActionSkillRunPolicyDecision {
  return {
    allowed: false,
    status,
    detail,
  };
}
