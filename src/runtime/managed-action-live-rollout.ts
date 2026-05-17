import { readFile } from "node:fs/promises";
import { MANAGED_ACTIONS_LIVE_ROLLOUT_FILE } from "../config";
import {
  isManagedActionName,
  type ManagedActionName,
} from "./managed-actions";

export type ManagedActionLiveRolloutRisk = "low" | "medium" | "high";
export type ManagedActionLiveRolloutStatus = "disabled" | "allowed" | "no_matching_rule";

export interface ManagedActionLiveRolloutRule {
  action: ManagedActionName;
  instanceId: string;
  operators: string[];
  risk: ManagedActionLiveRolloutRisk;
  enabled: boolean;
  maxDryRunAgeMinutes: number;
}

export interface ManagedActionLiveRolloutConfig {
  source: "default" | "file";
  path?: string;
  enabled: boolean;
  rules: ManagedActionLiveRolloutRule[];
  issues: string[];
}

export interface ManagedActionLiveRolloutDecision {
  allowed: boolean;
  status: ManagedActionLiveRolloutStatus;
  rule?: ManagedActionLiveRolloutRule;
  message: string;
}

export async function loadManagedActionLiveRolloutConfig(
  path = MANAGED_ACTIONS_LIVE_ROLLOUT_FILE,
): Promise<ManagedActionLiveRolloutConfig> {
  if (!path) return defaultManagedActionLiveRolloutConfig();

  try {
    const raw = await readFile(path, "utf8");
    return normalizeManagedActionLiveRolloutConfig(JSON.parse(raw), path);
  } catch (error) {
    return {
      source: "file",
      path,
      enabled: false,
      rules: [],
      issues: [`failed to read managed action live rollout config: ${error instanceof Error ? error.message : "unknown error"}`],
    };
  }
}

export function defaultManagedActionLiveRolloutConfig(): ManagedActionLiveRolloutConfig {
  return {
    source: "default",
    enabled: false,
    rules: [],
    issues: [],
  };
}

export function normalizeManagedActionLiveRolloutConfig(
  input: unknown,
  path?: string,
): ManagedActionLiveRolloutConfig {
  const obj = asRecord(input);
  const issues: string[] = [];
  if (!obj) {
    return {
      source: path ? "file" : "default",
      ...(path ? { path } : {}),
      enabled: false,
      rules: [],
      issues: ["managed action live rollout config must be a JSON object"],
    };
  }

  const enabled = obj.enabled === true;
  const rawRules = Array.isArray(obj.rules) ? obj.rules : [];
  if (!Array.isArray(obj.rules)) issues.push("rules must be an array");
  const rules = rawRules
    .map((rule, index) => normalizeRule(rule, index, issues))
    .filter((rule): rule is ManagedActionLiveRolloutRule => Boolean(rule));

  return {
    source: path ? "file" : "default",
    ...(path ? { path } : {}),
    enabled,
    rules,
    issues,
  };
}

export function evaluateManagedActionLiveRollout(input: {
  config: ManagedActionLiveRolloutConfig;
  action: ManagedActionName;
  instanceId: string;
  operator: string;
}): ManagedActionLiveRolloutDecision {
  if (!input.config.enabled) {
    return {
      allowed: false,
      status: "disabled",
      message: "Managed action live rollout config is disabled.",
    };
  }

  const rule = input.config.rules.find((candidate) => {
    if (!candidate.enabled) return false;
    if (candidate.action !== input.action) return false;
    if (candidate.instanceId !== input.instanceId) return false;
    return candidate.operators.includes("*") || candidate.operators.includes(input.operator);
  });

  if (!rule) {
    return {
      allowed: false,
      status: "no_matching_rule",
      message: "No managed action live rollout rule matches this request.",
    };
  }

  return {
    allowed: true,
    status: "allowed",
    rule,
    message: "Managed action live rollout rule matches this request.",
  };
}

function normalizeRule(
  input: unknown,
  index: number,
  issues: string[],
): ManagedActionLiveRolloutRule | undefined {
  const obj = asRecord(input);
  if (!obj) {
    issues.push(`rules[${index}] must be an object`);
    return undefined;
  }

  const action = typeof obj.action === "string" && isManagedActionName(obj.action) ? obj.action : undefined;
  const instanceId = normalizeString(obj.instanceId);
  const operators = normalizeOperators(obj.operators);
  const risk = normalizeRisk(obj.risk);
  const maxDryRunAgeMinutes = normalizePositiveInt(obj.maxDryRunAgeMinutes, 60);
  const enabled = obj.enabled !== false;
  if (!action) issues.push(`rules[${index}].action must be healthcheck, collector_refresh, or skill_run`);
  if (!instanceId) issues.push(`rules[${index}].instanceId is required`);
  if (operators.length === 0) issues.push(`rules[${index}].operators must contain at least one operator or *`);
  if (!risk) issues.push(`rules[${index}].risk must be low, medium, or high`);
  if (!action || !instanceId || operators.length === 0 || !risk) return undefined;

  return {
    action,
    instanceId,
    operators,
    risk,
    enabled,
    maxDryRunAgeMinutes,
  };
}

function normalizeOperators(input: unknown): string[] {
  if (!Array.isArray(input)) return [];
  return input
    .map((item) => normalizeString(item))
    .filter((item): item is string => Boolean(item));
}

function normalizeRisk(input: unknown): ManagedActionLiveRolloutRisk | undefined {
  return input === "low" || input === "medium" || input === "high" ? input : undefined;
}

function normalizePositiveInt(input: unknown, fallback: number): number {
  const parsed = typeof input === "number" ? input : Number.parseInt(String(input ?? ""), 10);
  if (!Number.isFinite(parsed) || parsed <= 0) return fallback;
  return Math.trunc(parsed);
}

function normalizeString(input: unknown): string | undefined {
  return typeof input === "string" && input.trim() !== "" ? input.trim() : undefined;
}

function asRecord(input: unknown): Record<string, unknown> | undefined {
  return input !== null && typeof input === "object" && !Array.isArray(input)
    ? (input as Record<string, unknown>)
    : undefined;
}
