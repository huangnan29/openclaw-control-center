import { createScopedToolClient } from "../clients/factory";
import { summarizeMultiInstanceSnapshot } from "../runtime/multi-instance-summary";
import type {
  InstanceSnapshot,
  MultiInstanceSnapshot,
  OpenClawInstanceConfig,
  ReadModelSnapshot,
} from "../types";
import { OpenClawReadonlyAdapter } from "./openclaw-readonly";

interface MultiInstanceReadonlyAdapterOptions {
  createSnapshot?: (instance: OpenClawInstanceConfig) => Promise<ReadModelSnapshot>;
}

export class MultiInstanceReadonlyAdapter {
  private readonly createSnapshot: (instance: OpenClawInstanceConfig) => Promise<ReadModelSnapshot>;

  constructor(
    private readonly instances: OpenClawInstanceConfig[],
    options: MultiInstanceReadonlyAdapterOptions = {},
  ) {
    this.createSnapshot =
      options.createSnapshot ??
      ((instance) => new OpenClawReadonlyAdapter(createScopedToolClient(instance)).snapshot());
  }

  async snapshot(selectedInstanceId = this.instances[0]?.id ?? ""): Promise<MultiInstanceSnapshot> {
    const snapshots = await Promise.all(this.instances.map((instance) => this.snapshotInstance(instance)));
    return summarizeMultiInstanceSnapshot(snapshots, selectedInstanceId);
  }

  private async snapshotInstance(instance: OpenClawInstanceConfig): Promise<InstanceSnapshot> {
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
    generatedAt,
  };
}
