import { readFile } from "node:fs/promises";
import type { InstanceConnectionStatus, ReadModelSnapshot } from "../types";

export interface CollectorSnapshotInstanceEntry {
  id: string;
  status: InstanceConnectionStatus;
  detail: string;
  snapshot: ReadModelSnapshot;
}

export interface CollectorSnapshotLoadResult {
  status: "connected" | "not_connected";
  sourcePath: string;
  serverId?: string;
  generatedAt?: string;
  detail: string;
  instances: CollectorSnapshotInstanceEntry[];
}

const INSTANCE_ID_PATTERN = /^[a-z0-9_-]+$/;

export async function loadCollectorSnapshotFile(path: string): Promise<CollectorSnapshotLoadResult> {
  try {
    return parseCollectorSnapshotText(await readFile(path, "utf8"), path);
  } catch (error) {
    return {
      status: "not_connected",
      sourcePath: path,
      detail: `failed to read collector snapshot: ${formatErrorMessage(error)}`,
      instances: [],
    };
  }
}

export function parseCollectorSnapshotText(text: string, sourcePath = "inline"): CollectorSnapshotLoadResult {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch (error) {
    return {
      status: "not_connected",
      sourcePath,
      detail: `invalid collector snapshot json: ${formatErrorMessage(error)}`,
      instances: [],
    };
  }

  if (!isRecord(parsed)) {
    return {
      status: "not_connected",
      sourcePath,
      detail: "collector snapshot must be an object.",
      instances: [],
    };
  }

  const entries = Array.isArray(parsed.instances) ? parsed.instances : undefined;
  if (!entries) {
    return {
      status: "not_connected",
      sourcePath,
      detail: "collector snapshot instances must be an array.",
      instances: [],
    };
  }

  const instances: CollectorSnapshotInstanceEntry[] = [];
  for (const entry of entries) {
    const item = readCollectorInstanceEntry(entry);
    if (item) instances.push(item);
  }

  return {
    status: "connected",
    sourcePath,
    serverId: readTrimmedString(parsed.serverId),
    generatedAt: readTrimmedString(parsed.generatedAt),
    detail: `loaded ${instances.length} collector snapshot instance${instances.length === 1 ? "" : "s"}.`,
    instances,
  };
}

function readCollectorInstanceEntry(value: unknown): CollectorSnapshotInstanceEntry | undefined {
  if (!isRecord(value)) return undefined;
  const id = readTrimmedString(value.id);
  if (!id || !INSTANCE_ID_PATTERN.test(id)) return undefined;
  const status = readInstanceStatus(value.status);
  if (!status) return undefined;
  const snapshot = isRecord(value.snapshot) ? (value.snapshot as unknown as ReadModelSnapshot) : undefined;
  if (!snapshot) return undefined;
  return {
    id,
    status,
    detail: readTrimmedString(value.detail) ?? "collector snapshot",
    snapshot,
  };
}

function readInstanceStatus(value: unknown): InstanceConnectionStatus | undefined {
  if (value === "connected" || value === "partial" || value === "not_connected") return value;
  return undefined;
}

function readTrimmedString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed === "" ? undefined : trimmed;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function formatErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
