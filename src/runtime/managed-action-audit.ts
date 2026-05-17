import { readFile } from "node:fs/promises";
import { OPERATION_AUDIT_LOG_PATH, type OperationAuditEntry } from "./operation-audit";
import type { ManagedActionName } from "./managed-actions";

export interface ManagedActionAuditFilters {
  limit?: number;
  instanceId?: string;
  operator?: string;
  action?: ManagedActionName;
}

export interface ManagedActionAuditRecord {
  timestamp: string;
  requestId?: string;
  operationRequestId?: string;
  source: OperationAuditEntry["source"];
  ok: boolean;
  action?: ManagedActionName;
  detail: string;
  targetInstanceId?: string;
  targetInstanceName?: string;
  operator?: string;
  reason?: string;
  confirmationTextMatched?: boolean;
  mutatesOpenClawInstance?: boolean;
  commandPreview: string[];
}

export interface ManagedActionAuditSnapshot {
  ok: true;
  path: string;
  count: number;
  records: ManagedActionAuditRecord[];
}

export async function readManagedActionDryRunAudits(
  filters: ManagedActionAuditFilters = {},
): Promise<ManagedActionAuditSnapshot> {
  const limit = clampLimit(filters.limit ?? 20);
  const entries = await readOperationAuditEntries();
  const records = entries
    .filter((entry) => entry.action === "managed_action_dry_run")
    .map(toManagedActionAuditRecord)
    .filter((record): record is ManagedActionAuditRecord => Boolean(record))
    .filter((record) => matchesFilter(record, filters))
    .sort((a, b) => Date.parse(b.timestamp) - Date.parse(a.timestamp))
    .slice(0, limit);

  return {
    ok: true,
    path: OPERATION_AUDIT_LOG_PATH,
    count: records.length,
    records,
  };
}

async function readOperationAuditEntries(): Promise<OperationAuditEntry[]> {
  try {
    const raw = await readFile(OPERATION_AUDIT_LOG_PATH, "utf8");
    return raw
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line !== "")
      .map((line) => JSON.parse(line) as OperationAuditEntry);
  } catch {
    return [];
  }
}

function toManagedActionAuditRecord(entry: OperationAuditEntry): ManagedActionAuditRecord | undefined {
  const metadata = asRecord(entry.metadata);
  const target = asRecord(metadata?.target);
  const targetConfigSnapshot = asRecord(metadata?.targetConfigSnapshot);
  const action = normalizeManagedAction(metadata?.managedAction) ?? parseManagedActionFromDetail(entry.detail);
  const commandPreview = Array.isArray(metadata?.commandPreview)
    ? metadata.commandPreview.filter((item): item is string => typeof item === "string")
    : [];

  return {
    timestamp: entry.timestamp,
    requestId: entry.requestId,
    operationRequestId: asString(metadata?.operationRequestId),
    source: entry.source,
    ok: entry.ok,
    action,
    detail: entry.detail,
    targetInstanceId: asString(target?.instanceId) ?? asString(targetConfigSnapshot?.instanceId),
    targetInstanceName: asString(target?.instanceName) ?? asString(targetConfigSnapshot?.instanceName),
    operator: asString(metadata?.operator),
    reason: asString(metadata?.reason),
    confirmationTextMatched: typeof metadata?.confirmationTextMatched === "boolean" ? metadata.confirmationTextMatched : undefined,
    mutatesOpenClawInstance:
      typeof metadata?.mutatesOpenClawInstance === "boolean" ? metadata.mutatesOpenClawInstance : undefined,
    commandPreview,
  };
}

function matchesFilter(record: ManagedActionAuditRecord, filters: ManagedActionAuditFilters): boolean {
  if (filters.instanceId && record.targetInstanceId !== filters.instanceId) return false;
  if (filters.operator && record.operator !== filters.operator) return false;
  if (filters.action && record.action !== filters.action) return false;
  return true;
}

function parseManagedActionFromDetail(detail: string): ManagedActionName | undefined {
  const match = detail.match(/^previewed\s+([a-z_]+)\s+for\s+/i);
  return normalizeManagedAction(match?.[1]);
}

function normalizeManagedAction(input: unknown): ManagedActionName | undefined {
  if (input === "healthcheck" || input === "collector_refresh" || input === "skill_run") return input;
  return undefined;
}

function clampLimit(value: number): number {
  if (!Number.isFinite(value)) return 20;
  return Math.max(1, Math.min(100, Math.trunc(value)));
}

function asRecord(input: unknown): Record<string, unknown> | undefined {
  return input !== null && typeof input === "object" && !Array.isArray(input)
    ? (input as Record<string, unknown>)
    : undefined;
}

function asString(input: unknown): string | undefined {
  return typeof input === "string" && input.trim() !== "" ? input : undefined;
}
