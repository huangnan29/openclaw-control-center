import { createScopedToolClient } from "../clients/factory";
import {
  loadCollectorSnapshotFile,
  type CollectorSnapshotLoadResult,
} from "../runtime/collector-snapshot";
import { summarizeMultiInstanceSnapshot } from "../runtime/multi-instance-summary";
import type {
  CollectorSnapshotSource,
  InstanceSnapshot,
  MultiInstanceSnapshot,
  OpenClawInstanceConfig,
  ReadModelSnapshot,
} from "../types";
import { OpenClawReadonlyAdapter } from "./openclaw-readonly";

interface MultiInstanceReadonlyAdapterOptions {
  createSnapshot?: (instance: OpenClawInstanceConfig) => Promise<ReadModelSnapshot>;
  loadCollectorSnapshot?: (path: string) => Promise<CollectorSnapshotLoadResult>;
}

export class MultiInstanceReadonlyAdapter {
  private readonly createSnapshot: (instance: OpenClawInstanceConfig) => Promise<ReadModelSnapshot>;
  private readonly loadCollectorSnapshot: (path: string) => Promise<CollectorSnapshotLoadResult>;

  constructor(
    private readonly instances: OpenClawInstanceConfig[],
    options: MultiInstanceReadonlyAdapterOptions = {},
  ) {
    this.createSnapshot =
      options.createSnapshot ??
      ((instance) => new OpenClawReadonlyAdapter(createScopedToolClient(instance), instance).snapshot());
    this.loadCollectorSnapshot = options.loadCollectorSnapshot ?? loadCollectorSnapshotFile;
  }

  async snapshot(selectedInstanceId = this.instances[0]?.id ?? ""): Promise<MultiInstanceSnapshot> {
    const collectorCache = new Map<string, Promise<CollectorSnapshotLoadResult>>();
    const snapshots = await Promise.all(this.instances.map((instance) => this.snapshotInstance(instance, collectorCache)));
    return summarizeMultiInstanceSnapshot(snapshots, selectedInstanceId);
  }

  private async snapshotInstance(
    instance: OpenClawInstanceConfig,
    collectorCache: Map<string, Promise<CollectorSnapshotLoadResult>>,
  ): Promise<InstanceSnapshot> {
    if (instance.collectorSnapshotPath) {
      return this.snapshotCollectorInstance(instance, collectorCache);
    }

    try {
      return {
        instance,
        status: "connected",
        detail: "ok",
        snapshot: await this.createSnapshot(instance),
      };
    } catch (error) {
      return {
        instance,
        status: "not_connected",
        detail: error instanceof Error ? error.message : String(error),
        snapshot: emptySnapshot(),
      };
    }
  }

  private async snapshotCollectorInstance(
    instance: OpenClawInstanceConfig,
    collectorCache: Map<string, Promise<CollectorSnapshotLoadResult>>,
  ): Promise<InstanceSnapshot> {
    const path = instance.collectorSnapshotPath as string;
    const collector = await readCachedCollectorSnapshot(path, collectorCache, this.loadCollectorSnapshot);
    const collectorSource = toCollectorSnapshotSource(collector);
    if (collector.status !== "connected") {
      return {
        instance,
        status: "not_connected",
        detail: collector.detail,
        collector: collectorSource,
        snapshot: emptySnapshot(),
      };
    }

    const entry = collector.instances.find((item) => item.id === instance.id);
    if (!entry) {
      return {
        instance,
        status: "not_connected",
        detail: `collector snapshot missing instance: ${instance.id}`,
        collector: collectorSource,
        snapshot: emptySnapshot(),
      };
    }

    return {
      instance,
      status: entry.status,
      detail: entry.detail,
      collector: collectorSource,
      snapshot: entry.snapshot,
    };
  }
}

function toCollectorSnapshotSource(collector: CollectorSnapshotLoadResult): CollectorSnapshotSource {
  return {
    status: collector.status,
    sourcePath: collector.sourcePath,
    ...(collector.serverId ? { serverId: collector.serverId } : {}),
    ...(collector.generatedAt ? { generatedAt: collector.generatedAt } : {}),
    detail: collector.detail,
  };
}

function readCachedCollectorSnapshot(
  path: string,
  cache: Map<string, Promise<CollectorSnapshotLoadResult>>,
  loadCollectorSnapshot: (path: string) => Promise<CollectorSnapshotLoadResult>,
): Promise<CollectorSnapshotLoadResult> {
  const existing = cache.get(path);
  if (existing) return existing;
  const next = loadCollectorSnapshot(path);
  cache.set(path, next);
  return next;
}

export function emptySnapshot(): ReadModelSnapshot {
  const generatedAt = new Date().toISOString();

  return {
    sessions: [],
    statuses: [],
    cronJobs: [],
    approvals: [],
    projects: {
      projects: [],
      updatedAt: generatedAt,
    },
    projectSummaries: [],
    tasks: {
      tasks: [],
      agentBudgets: [],
      updatedAt: generatedAt,
    },
    tasksSummary: {
      projects: 0,
      tasks: 0,
      todo: 0,
      inProgress: 0,
      blocked: 0,
      done: 0,
      owners: 0,
      artifacts: 0,
    },
    budgetSummary: {
      total: 0,
      ok: 0,
      warn: 0,
      over: 0,
      evaluations: [],
    },
    agentRoster: {
      status: "not_connected",
      sourcePath: "",
      detail: "snapshot unavailable.",
      entries: [],
    },
    runtimeLogs: {
      status: "not_connected",
      sourcePaths: [],
      detail: "snapshot unavailable.",
      entries: [],
    },
    generatedAt,
  };
}
