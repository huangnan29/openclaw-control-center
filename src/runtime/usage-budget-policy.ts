import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { resolveRuntimePath } from "./runtime-path";

const DEFAULT_WARN_RATIO = 0.8;

export const USAGE_BUDGET_POLICY_PATH = resolveRuntimePath("usage-budget-policy.json");

export type UsageBudgetStatus = "ok" | "warn" | "over" | "not_connected";

export interface UsageBudgetPolicy {
  currency: string;
  monthlyLimitCost?: number;
  warnRatio: number;
}

export interface UsageBudgetPolicyLoadResult {
  policy: UsageBudgetPolicy;
  path: string;
  loadedFromFile: boolean;
  issues: string[];
}

export interface UsageBudgetEvaluation {
  status: UsageBudgetStatus;
  usedCost: number;
  limitCost?: number;
  remainingCost?: number;
  usagePercent?: number;
  warnAtCost?: number;
  message: string;
}

export interface UsageBudgetPolicyUpdateResult {
  policy: UsageBudgetPolicy;
  issues: string[];
}

export const DEFAULT_USAGE_BUDGET_POLICY: UsageBudgetPolicy = {
  currency: "USD",
  warnRatio: DEFAULT_WARN_RATIO,
};

export async function loadUsageBudgetPolicy(): Promise<UsageBudgetPolicyLoadResult> {
  try {
    const raw = await readFile(USAGE_BUDGET_POLICY_PATH, "utf8");
    const parsed = JSON.parse(raw) as unknown;
    const issues: string[] = [];
    return {
      policy: normalizeUsageBudgetPolicy(parsed, issues),
      path: USAGE_BUDGET_POLICY_PATH,
      loadedFromFile: true,
      issues,
    };
  } catch (error) {
    const issues: string[] = [];
    if (!isErrorWithCode(error, "ENOENT")) {
      issues.push(`failed to load usage budget policy: ${error instanceof Error ? error.message : "unknown error"}`);
    }
    return {
      policy: { ...DEFAULT_USAGE_BUDGET_POLICY },
      path: USAGE_BUDGET_POLICY_PATH,
      loadedFromFile: false,
      issues,
    };
  }
}

export function buildUsageBudgetPolicyUpdate(input: unknown): UsageBudgetPolicyUpdateResult {
  const issues: string[] = [];
  return {
    policy: normalizeUsageBudgetPolicy(input, issues),
    issues,
  };
}

export async function writeUsageBudgetPolicy(policy: UsageBudgetPolicy): Promise<UsageBudgetPolicyLoadResult> {
  const update = buildUsageBudgetPolicyUpdate(policy);
  if (update.issues.length > 0) {
    return {
      policy: update.policy,
      path: USAGE_BUDGET_POLICY_PATH,
      loadedFromFile: false,
      issues: update.issues,
    };
  }

  const body = `${JSON.stringify(update.policy, null, 2)}\n`;
  const tempPath = `${USAGE_BUDGET_POLICY_PATH}.tmp-${process.pid}-${Date.now()}`;
  await mkdir(dirname(USAGE_BUDGET_POLICY_PATH), { recursive: true });
  await writeFile(tempPath, body, "utf8");
  await rename(tempPath, USAGE_BUDGET_POLICY_PATH);

  return {
    policy: update.policy,
    path: USAGE_BUDGET_POLICY_PATH,
    loadedFromFile: true,
    issues: [],
  };
}

export function evaluateUsageBudget(input: {
  usedCost: number;
  monthlyLimitCost?: number;
  warnRatio?: number;
}): UsageBudgetEvaluation {
  const usedCost = normalizeNonNegativeNumber(input.usedCost);
  const limitCost = normalizePositiveNumber(input.monthlyLimitCost);
  const warnRatio = normalizeWarnRatio(input.warnRatio);

  if (limitCost === undefined) {
    return {
      status: "not_connected",
      usedCost,
      message: "No positive monthly budget limit is configured.",
    };
  }

  const usagePercent = (usedCost / limitCost) * 100;
  const remainingCost = Math.max(0, limitCost - usedCost);
  const warnAtCost = limitCost * warnRatio;

  if (usedCost >= limitCost) {
    return {
      status: "over",
      usedCost,
      limitCost,
      remainingCost,
      usagePercent,
      warnAtCost,
      message: "Estimated usage is over the monthly budget limit.",
    };
  }

  if (usedCost >= warnAtCost) {
    return {
      status: "warn",
      usedCost,
      limitCost,
      remainingCost,
      usagePercent,
      warnAtCost,
      message: "Estimated usage is approaching the monthly budget limit.",
    };
  }

  return {
    status: "ok",
    usedCost,
    limitCost,
    remainingCost,
    usagePercent,
    warnAtCost,
    message: "Estimated usage is within the monthly budget limit.",
  };
}

function normalizeUsageBudgetPolicy(input: unknown, issues: string[]): UsageBudgetPolicy {
  const obj = asObject(input);
  if (!obj) {
    issues.push("usage budget policy must be a JSON object");
    return { ...DEFAULT_USAGE_BUDGET_POLICY };
  }

  const monthlyLimitCostRaw = readNumberAlias(obj, ["monthlyLimitCost", "monthlyCostLimit", "costLimit"]);
  const monthlyLimitCost = normalizePositiveNumber(monthlyLimitCostRaw);
  const warnRatioRaw = readNumberAlias(obj, ["warnRatio"]);
  const warnRatio = normalizeWarnRatio(warnRatioRaw);
  if (warnRatioRaw !== undefined && warnRatioRaw !== warnRatio) {
    issues.push("warnRatio must be a finite number > 0 and < 1");
  }
  if (monthlyLimitCostRaw !== undefined && monthlyLimitCost === undefined) {
    issues.push("monthlyLimitCost must be a finite number > 0");
  }

  const currency = typeof obj.currency === "string" && obj.currency.trim() ? obj.currency.trim().toUpperCase() : "USD";

  return {
    currency,
    warnRatio,
    ...(monthlyLimitCost !== undefined ? { monthlyLimitCost } : {}),
  };
}

function readNumberAlias(obj: Record<string, unknown>, keys: string[]): number | undefined {
  for (const key of keys) {
    const value = obj[key];
    if (value === undefined) continue;
    if (typeof value === "number") return value;
    if (typeof value === "string" && value.trim() !== "") return Number(value.trim());
    return Number.NaN;
  }
  return undefined;
}

function normalizePositiveNumber(value: number | undefined): number | undefined {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) return undefined;
  return value;
}

function normalizeNonNegativeNumber(value: number): number {
  if (!Number.isFinite(value) || value <= 0) return 0;
  return value;
}

function normalizeWarnRatio(value: number | undefined): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0 || value >= 1) return DEFAULT_WARN_RATIO;
  return value;
}

function asObject(v: unknown): Record<string, unknown> | undefined {
  return v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : undefined;
}

function isErrorWithCode(error: unknown, code: string): boolean {
  return error !== null && typeof error === "object" && "code" in error && (error as { code?: unknown }).code === code;
}
