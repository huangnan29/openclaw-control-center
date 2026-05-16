import type { InstanceSnapshot, MultiInstanceSnapshot } from "../types";

export function summarizeMultiInstanceSnapshot(
  instances: InstanceSnapshot[],
  selectedInstanceId = instances[0]?.instance.id ?? "",
): MultiInstanceSnapshot {
  const totals = {
    instances: instances.length,
    connected: 0,
    partial: 0,
    notConnected: 0,
    sessions: 0,
    running: 0,
    blocked: 0,
    errors: 0,
    pendingApprovals: 0,
    cronJobs: 0,
  };

  for (const instance of instances) {
    if (instance.status === "connected") totals.connected += 1;
    if (instance.status === "partial") totals.partial += 1;
    if (instance.status === "not_connected") totals.notConnected += 1;

    totals.sessions += instance.snapshot.sessions.length;
    totals.running += instance.snapshot.sessions.filter((session) => session.state === "running").length;
    totals.blocked += instance.snapshot.sessions.filter(
      (session) => session.state === "blocked" || session.state === "waiting_approval",
    ).length;
    totals.errors += instance.snapshot.sessions.filter((session) => session.state === "error").length;
    totals.pendingApprovals += instance.snapshot.approvals.filter((approval) => approval.status === "pending").length;
    totals.cronJobs += instance.snapshot.cronJobs.length;
  }

  return {
    generatedAt: new Date().toISOString(),
    selectedInstanceId,
    instances,
    totals,
  };
}
