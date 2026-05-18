import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import type { InstanceConnectionStatus } from "../types";
import type { CollectorSnapshotFile } from "./collector-exporter";

export interface CollectorHistoryInstanceSample {
  id: string;
  name?: string;
  status: InstanceConnectionStatus;
  sessions: number;
  running: number;
  blocked: number;
  errors: number;
  pendingApprovals: number;
  tokensIn: number;
  tokensOut: number;
  totalTokens: number;
  cost: number;
}

export interface CollectorHistoryModelSample {
  model: string;
  sessions: number;
  tokensIn: number;
  tokensOut: number;
  totalTokens: number;
  cost: number;
}

export interface CollectorHistoryTotals {
  instances: number;
  connected: number;
  partial: number;
  notConnected: number;
  sessions: number;
  running: number;
  blocked: number;
  errors: number;
  pendingApprovals: number;
  tokensIn: number;
  tokensOut: number;
  totalTokens: number;
  cost: number;
}

export interface CollectorHistorySample {
  generatedAt: string;
  serverId: string;
  serverName?: string;
  totals: CollectorHistoryTotals;
  instances: CollectorHistoryInstanceSample[];
  models: CollectorHistoryModelSample[];
}

export interface CollectorHistoryFile {
  schemaVersion: 1;
  serverId: string;
  serverName?: string;
  updatedAt: string;
  retentionDays: number;
  samples: CollectorHistorySample[];
}

export interface CollectorHistoryLoadResult {
  status: "connected" | "not_connected";
  sourcePath: string;
  detail: string;
  history?: CollectorHistoryFile;
}

const DEFAULT_RETENTION_DAYS = 8;
const DEFAULT_MAX_SAMPLES = 6000;

export function collectorHistoryPathForSnapshotPath(snapshotPath: string): string {
  return join(dirname(snapshotPath), "history.json");
}

export async function appendCollectorHistorySample(
  snapshot: CollectorSnapshotFile,
  historyPath: string,
  options: { retentionDays?: number; maxSamples?: number } = {},
): Promise<{ path: string; samples: number }> {
  const resolved = resolve(historyPath);
  const retentionDays = options.retentionDays ?? DEFAULT_RETENTION_DAYS;
  const maxSamples = options.maxSamples ?? DEFAULT_MAX_SAMPLES;
  const nextSample = buildCollectorHistorySample(snapshot);
  const existing = await readCollectorHistoryFileOrEmpty(resolved, snapshot, retentionDays);
  const samples = [...existing.samples.filter((sample) => sample.generatedAt !== nextSample.generatedAt), nextSample]
    .filter((sample) => isWithinRetention(sample.generatedAt, nextSample.generatedAt, retentionDays))
    .sort((a, b) => Date.parse(a.generatedAt) - Date.parse(b.generatedAt))
    .slice(-maxSamples);
  const nextFile: CollectorHistoryFile = {
    schemaVersion: 1,
    serverId: snapshot.serverId,
    ...(snapshot.serverName ? { serverName: snapshot.serverName } : {}),
    updatedAt: new Date().toISOString(),
    retentionDays,
    samples,
  };

  await writeJsonAtomic(resolved, nextFile);
  return { path: resolved, samples: nextFile.samples.length };
}

export async function loadCollectorHistoryFile(path: string): Promise<CollectorHistoryLoadResult> {
  const resolved = resolve(path);
  try {
    const raw = JSON.parse(await readFile(resolved, "utf8")) as unknown;
    const history = parseCollectorHistoryFile(raw);
    return {
      status: "connected",
      sourcePath: resolved,
      detail: `loaded ${history.samples.length} collector history sample${history.samples.length === 1 ? "" : "s"}.`,
      history,
    };
  } catch (error) {
    return {
      status: "not_connected",
      sourcePath: resolved,
      detail: `failed to read collector history: ${formatErrorMessage(error)}`,
    };
  }
}

function buildCollectorHistorySample(snapshot: CollectorSnapshotFile): CollectorHistorySample {
  const instances = snapshot.instances.map((entry): CollectorHistoryInstanceSample => {
    const tokensIn = entry.snapshot.statuses.reduce((sum, status) => sum + (status.tokensIn ?? 0), 0);
    const tokensOut = entry.snapshot.statuses.reduce((sum, status) => sum + (status.tokensOut ?? 0), 0);
    return {
      id: entry.id,
      ...(entry.name ? { name: entry.name } : {}),
      status: entry.status,
      sessions: entry.snapshot.sessions.length,
      running: entry.snapshot.sessions.filter((session) => session.state === "running").length,
      blocked: entry.snapshot.sessions.filter((session) => session.state === "blocked" || session.state === "waiting_approval").length,
      errors: entry.snapshot.sessions.filter((session) => session.state === "error").length,
      pendingApprovals: entry.snapshot.approvals.filter((approval) => approval.status === "pending").length,
      tokensIn,
      tokensOut,
      totalTokens: tokensIn + tokensOut,
      cost: entry.snapshot.statuses.reduce((sum, status) => sum + (status.cost ?? 0), 0),
    };
  });

  return {
    generatedAt: snapshot.generatedAt,
    serverId: snapshot.serverId,
    ...(snapshot.serverName ? { serverName: snapshot.serverName } : {}),
    totals: summarizeHistoryInstances(instances),
    instances,
    models: buildModelSamples(snapshot),
  };
}

function buildModelSamples(snapshot: CollectorSnapshotFile): CollectorHistoryModelSample[] {
  const rows = new Map<string, CollectorHistoryModelSample>();
  for (const entry of snapshot.instances) {
    for (const status of entry.snapshot.statuses) {
      const model = status.model?.trim() || "unknown";
      const current = rows.get(model) ?? { model, sessions: 0, tokensIn: 0, tokensOut: 0, totalTokens: 0, cost: 0 };
      current.sessions += 1;
      current.tokensIn += status.tokensIn ?? 0;
      current.tokensOut += status.tokensOut ?? 0;
      current.totalTokens = current.tokensIn + current.tokensOut;
      current.cost += status.cost ?? 0;
      rows.set(model, current);
    }
  }
  return [...rows.values()].sort((a, b) => b.totalTokens - a.totalTokens);
}

function summarizeHistoryInstances(instances: CollectorHistoryInstanceSample[]): CollectorHistoryTotals {
  return instances.reduce(
    (totals, item) => {
      totals.instances += 1;
      if (item.status === "connected") totals.connected += 1;
      if (item.status === "partial") totals.partial += 1;
      if (item.status === "not_connected") totals.notConnected += 1;
      totals.sessions += item.sessions;
      totals.running += item.running;
      totals.blocked += item.blocked;
      totals.errors += item.errors;
      totals.pendingApprovals += item.pendingApprovals;
      totals.tokensIn += item.tokensIn;
      totals.tokensOut += item.tokensOut;
      totals.totalTokens += item.totalTokens;
      totals.cost += item.cost;
      return totals;
    },
    {
      instances: 0,
      connected: 0,
      partial: 0,
      notConnected: 0,
      sessions: 0,
      running: 0,
      blocked: 0,
      errors: 0,
      pendingApprovals: 0,
      tokensIn: 0,
      tokensOut: 0,
      totalTokens: 0,
      cost: 0,
    },
  );
}

async function readCollectorHistoryFileOrEmpty(
  path: string,
  snapshot: CollectorSnapshotFile,
  retentionDays: number,
): Promise<CollectorHistoryFile> {
  try {
    return parseCollectorHistoryFile(JSON.parse(await readFile(path, "utf8")) as unknown);
  } catch {
    return {
      schemaVersion: 1,
      serverId: snapshot.serverId,
      ...(snapshot.serverName ? { serverName: snapshot.serverName } : {}),
      updatedAt: new Date().toISOString(),
      retentionDays,
      samples: [],
    };
  }
}

function parseCollectorHistoryFile(value: unknown): CollectorHistoryFile {
  if (!isRecord(value)) throw new Error("collector history must be an object.");
  if (value.schemaVersion !== 1) throw new Error("collector history schemaVersion must be 1.");
  const serverId = readString(value.serverId) || "unknown";
  const samples = Array.isArray(value.samples) ? value.samples.map(readSample).filter((sample): sample is CollectorHistorySample => Boolean(sample)) : [];
  return {
    schemaVersion: 1,
    serverId,
    ...(readString(value.serverName) ? { serverName: readString(value.serverName) } : {}),
    updatedAt: readString(value.updatedAt) || new Date().toISOString(),
    retentionDays: readNumber(value.retentionDays) ?? DEFAULT_RETENTION_DAYS,
    samples,
  };
}

function readSample(value: unknown): CollectorHistorySample | undefined {
  if (!isRecord(value)) return undefined;
  const generatedAt = readString(value.generatedAt);
  const serverId = readString(value.serverId);
  if (!generatedAt || !serverId || Number.isNaN(Date.parse(generatedAt))) return undefined;
  const instances = Array.isArray(value.instances)
    ? value.instances.map(readInstanceSample).filter((sample): sample is CollectorHistoryInstanceSample => Boolean(sample))
    : [];
  const totals = isRecord(value.totals) ? readTotals(value.totals) : summarizeHistoryInstances(instances);
  return {
    generatedAt,
    serverId,
    ...(readString(value.serverName) ? { serverName: readString(value.serverName) } : {}),
    totals,
    instances,
    models: Array.isArray(value.models)
      ? value.models.map(readModelSample).filter((sample): sample is CollectorHistoryModelSample => Boolean(sample))
      : [],
  };
}

function readInstanceSample(value: unknown): CollectorHistoryInstanceSample | undefined {
  if (!isRecord(value)) return undefined;
  const id = readString(value.id);
  const status = readStatus(value.status);
  if (!id || !status) return undefined;
  const tokensIn = readNumber(value.tokensIn) ?? 0;
  const tokensOut = readNumber(value.tokensOut) ?? 0;
  return {
    id,
    ...(readString(value.name) ? { name: readString(value.name) } : {}),
    status,
    sessions: readNumber(value.sessions) ?? 0,
    running: readNumber(value.running) ?? 0,
    blocked: readNumber(value.blocked) ?? 0,
    errors: readNumber(value.errors) ?? 0,
    pendingApprovals: readNumber(value.pendingApprovals) ?? 0,
    tokensIn,
    tokensOut,
    totalTokens: readNumber(value.totalTokens) ?? tokensIn + tokensOut,
    cost: readNumber(value.cost) ?? 0,
  };
}

function readModelSample(value: unknown): CollectorHistoryModelSample | undefined {
  if (!isRecord(value)) return undefined;
  const model = readString(value.model);
  if (!model) return undefined;
  const tokensIn = readNumber(value.tokensIn) ?? 0;
  const tokensOut = readNumber(value.tokensOut) ?? 0;
  return {
    model,
    sessions: readNumber(value.sessions) ?? 0,
    tokensIn,
    tokensOut,
    totalTokens: readNumber(value.totalTokens) ?? tokensIn + tokensOut,
    cost: readNumber(value.cost) ?? 0,
  };
}

function readTotals(value: Record<string, unknown>): CollectorHistoryTotals {
  return {
    instances: readNumber(value.instances) ?? 0,
    connected: readNumber(value.connected) ?? 0,
    partial: readNumber(value.partial) ?? 0,
    notConnected: readNumber(value.notConnected) ?? 0,
    sessions: readNumber(value.sessions) ?? 0,
    running: readNumber(value.running) ?? 0,
    blocked: readNumber(value.blocked) ?? 0,
    errors: readNumber(value.errors) ?? 0,
    pendingApprovals: readNumber(value.pendingApprovals) ?? 0,
    tokensIn: readNumber(value.tokensIn) ?? 0,
    tokensOut: readNumber(value.tokensOut) ?? 0,
    totalTokens: readNumber(value.totalTokens) ?? 0,
    cost: readNumber(value.cost) ?? 0,
  };
}

function isWithinRetention(generatedAt: string, referenceAt: string, retentionDays: number): boolean {
  const generatedMs = Date.parse(generatedAt);
  const referenceMs = Date.parse(referenceAt);
  if (!Number.isFinite(generatedMs) || !Number.isFinite(referenceMs)) return false;
  return generatedMs >= referenceMs - retentionDays * 24 * 60 * 60 * 1000;
}

async function writeJsonAtomic(path: string, value: unknown): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const tempPath = `${path}.tmp-${process.pid}-${Date.now()}`;
  await writeFile(tempPath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  await rename(tempPath, path);
}

function readStatus(value: unknown): InstanceConnectionStatus | undefined {
  if (value === "connected" || value === "partial" || value === "not_connected") return value;
  return undefined;
}

function readString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed === "" ? undefined : trimmed;
}

function readNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function formatErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
