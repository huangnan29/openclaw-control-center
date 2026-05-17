import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { OpenClawReadonlyAdapter } from "../adapters/openclaw-readonly";
import { emptySnapshot } from "../adapters/multi-instance-readonly";
import { createScopedToolClient } from "../clients/factory";
import type {
  InstanceConnectionStatus,
  OpenClawInstanceConfig,
  OpenClawInstanceConfigLoadResult,
  ReadModelSnapshot,
} from "../types";

export interface CollectorSnapshotFile {
  schemaVersion: 1;
  serverId: string;
  serverName?: string;
  generatedAt: string;
  instances: CollectorSnapshotExportEntry[];
}

export interface CollectorSnapshotExportEntry {
  id: string;
  name: string;
  status: InstanceConnectionStatus;
  detail: string;
  snapshot: ReadModelSnapshot;
}

export interface CollectorExportInput {
  instances: OpenClawInstanceConfig[];
  serverId?: string;
  serverName?: string;
  generatedAt?: string;
  createSnapshot?: (instance: OpenClawInstanceConfig) => Promise<ReadModelSnapshot>;
}

export interface CollectorExportScope {
  serverId: string;
  serverName?: string;
  instances: OpenClawInstanceConfig[];
}

export async function buildCollectorSnapshot(input: CollectorExportInput): Promise<CollectorSnapshotFile> {
  const generatedAt = input.generatedAt ?? new Date().toISOString();
  const createSnapshot =
    input.createSnapshot ??
    ((instance: OpenClawInstanceConfig) =>
      new OpenClawReadonlyAdapter(createScopedToolClient(instance), instance).snapshot());

  const instances = await Promise.all(
    input.instances.map(async (instance): Promise<CollectorSnapshotExportEntry> => {
      try {
        return {
          id: instance.id,
          name: instance.name,
          status: "connected",
          detail: "collector ok",
          snapshot: await createSnapshot(instance),
        };
      } catch (error) {
        return {
          id: instance.id,
          name: instance.name,
          status: "not_connected",
          detail: formatErrorMessage(error),
          snapshot: emptySnapshot(),
        };
      }
    }),
  );

  return {
    schemaVersion: 1,
    serverId: input.serverId ?? inferServerId(input.instances),
    ...(input.serverName ? { serverName: input.serverName } : {}),
    generatedAt,
    instances,
  };
}

export async function writeCollectorSnapshotFile(
  snapshot: CollectorSnapshotFile,
  outputPath: string,
): Promise<{ path: string; instances: number }> {
  const resolved = resolve(outputPath);
  await mkdir(dirname(resolved), { recursive: true });
  await writeFile(resolved, `${JSON.stringify(snapshot, null, 2)}\n`, "utf8");
  return {
    path: resolved,
    instances: snapshot.instances.length,
  };
}

export function selectCollectorExportScope(
  result: OpenClawInstanceConfigLoadResult,
  requestedServerId?: string,
): CollectorExportScope {
  const normalizedServerId = requestedServerId?.trim();
  const serverId = normalizedServerId || inferServerId(result.instances);
  const instances = result.instances.filter((instance) => (instance.serverId?.trim() || "local") === serverId);
  if (instances.length === 0) {
    throw new Error(`collector exporter found no instances for server: ${serverId}`);
  }

  const server = result.servers?.find((item) => item.id === serverId);
  return {
    serverId,
    serverName: server?.name ?? instances[0]?.serverName,
    instances,
  };
}

function inferServerId(instances: OpenClawInstanceConfig[]): string {
  const ids = [...new Set(instances.map((instance) => instance.serverId?.trim() || "local"))];
  if (ids.length === 1) return ids[0] as string;
  if (ids.length === 0) return "local";
  throw new Error(`collector exporter requires OPENCLAW_COLLECTOR_SERVER_ID when multiple servers are configured: ${ids.join(", ")}`);
}

function formatErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
