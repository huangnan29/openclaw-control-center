import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const GATE = join(ROOT, "ops", "tom-readonly", "go-live-gate.sh");

async function writeExecutable(file: string, content: string): Promise<void> {
  await writeFile(file, content, "utf8");
  await chmod(file, 0o755);
}

async function writeHarness(dir: string, options: {
  remoteStage: "needs_remote_credentials" | "ready_for_healthcheck";
  healthcheckExit?: number;
  dryRunReady?: boolean;
  liveApprovalStatus?: string;
}): Promise<{
  deployDir: string;
  bundleDir: string;
  remoteScript: string;
  dryRunScript: string;
  liveScript: string;
  healthcheckScript: string;
}> {
  const deployDir = join(dir, "deploy");
  const bundleDir = join(deployDir, "runtime", "remote-onboarding", "remote-oracle");
  const binDir = join(dir, "bin");
  await mkdir(binDir, { recursive: true });
  await mkdir(bundleDir, { recursive: true });

  const remoteScript = join(binDir, "remote-runner.sh");
  const dryRunScript = join(binDir, "dry-run-gate.sh");
  const liveScript = join(binDir, "live-window.sh");
  const healthcheckScript = join(binDir, "healthcheck.sh");

  const remoteBlocked = options.remoteStage === "needs_remote_credentials";
  await writeExecutable(
    remoteScript,
    `#!/usr/bin/env bash
cat <<'JSON'
{
  "status": "${remoteBlocked ? "blocked" : "ready"}",
  "stage": "${options.remoteStage}",
  "serverId": "remote-oracle",
  "serverName": "Remote Oracle",
  "evidence": {
    "remoteAccess": {
      "status": "${remoteBlocked ? "blocked" : "ready"}",
      "acceptable": ${remoteBlocked ? "false" : "true"},
      "issues": ${remoteBlocked ? "[\"Tom 上缺少远端只读 SSH key\"]" : "[]"}
    },
    "preflight": { "status": "${remoteBlocked ? "missing" : "ready"}" },
    "pull": { "status": "${remoteBlocked ? "missing" : "pulled"}" },
    "snapshot": { "status": "${remoteBlocked ? "missing" : "valid"}" },
    "registry": { "status": "${remoteBlocked ? "missing_server" : "registered"}" }
  },
  "nextCommands": [
    "ops/local/push-remote-collector-credentials.sh plan runtime/push-remote-collector-credentials.json"
  ],
  "safety": {
    "connectsSsh": false,
    "writesActiveRegistry": false,
    "mutatesOpenClawInstance": false,
    "callsLiveApi": false
  }
}
JSON
`,
  );

  const dryRunReady = options.dryRunReady ?? true;
  await writeExecutable(
    dryRunScript,
    `#!/usr/bin/env bash
cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "${dryRunReady ? "ready" : "blocked"}",
  "target": {
    "instanceId": "tom",
    "action": "healthcheck",
    "operator": "Anan"
  },
  "audit": {
    "count": ${dryRunReady ? "1" : "0"},
    "latest": ${dryRunReady ? "{\"operationRequestId\":\"dry-run-1\",\"action\":\"healthcheck\",\"targetInstanceId\":\"tom\",\"operator\":\"Anan\",\"confirmationTextMatched\":true,\"mutatesOpenClawInstance\":false}" : "null"}
  },
  "readiness": {
    "status": "blocked",
    "liveExecutionAvailable": false
  },
  "issues": ${dryRunReady ? "[]" : "[\"没有匹配的 managed action dry-run 审计记录\"]"},
  "nextCommands": [
    "CONFIRM_MANAGED_ACTION_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CREATES_DRY_RUN_AUDIT_RECORD LOCAL_API_TOKEN=<本地令牌> repo/ops/tom-readonly/managed-action-dry-run-gate.sh run"
  ],
  "safety": {
    "callsManagedActionsLiveApi": false,
    "writesOpenClawInstanceDirs": false
  }
}
JSON
`,
  );

  const approvalStatus = options.liveApprovalStatus || "needs_manual_approval";
  await writeExecutable(
    liveScript,
    `#!/usr/bin/env bash
echo "[测试] 读取 approval 状态"
cat <<'JSON'
{
  "status": "${approvalStatus}",
  "approved": false,
  "consumed": false,
  "action": "healthcheck",
  "operator": "Anan",
  "issues": ["approved is not true"]
}
JSON
echo "READONLY_MODE=true"
echo "MANAGED_ACTIONS_LIVE_ENABLED=<unset>"
echo "MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED=<unset>"
echo "readiness.status=blocked"
echo "readiness.liveExecutionAvailable=false"
echo "readiness.executor.productionWired=false"
`,
  );

  const healthcheckExit = options.healthcheckExit ?? 0;
  await writeExecutable(
    healthcheckScript,
    `#!/usr/bin/env bash
echo "healthcheck ${healthcheckExit === 0 ? "ok" : "failed"}"
exit ${healthcheckExit}
`,
  );

  return { deployDir, bundleDir, remoteScript, dryRunScript, liveScript, healthcheckScript };
}

function runGate(
  harness: Awaited<ReturnType<typeof writeHarness>>,
  mode: "status" | "check",
  topologyMode = "cross-server",
): any {
  const output = execFileSync(GATE, [mode, harness.bundleDir], {
    env: {
      ...process.env,
      DEPLOY_DIR: harness.deployDir,
      OPENCLAW_TOPOLOGY_MODE: topologyMode,
      GO_LIVE_REMOTE_ROLLOUT_RUNNER_SCRIPT: harness.remoteScript,
      GO_LIVE_MANAGED_ACTION_DRY_RUN_GATE_SCRIPT: harness.dryRunScript,
      GO_LIVE_HEALTHCHECK_WINDOW_SCRIPT: harness.liveScript,
      GO_LIVE_HEALTHCHECK_SCRIPT: harness.healthcheckScript,
    },
    encoding: "utf8",
  });
  return JSON.parse(output);
}

test("go-live gate reports the current cross-server credential blocker without running healthcheck", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-go-live-gate-"));
  try {
    const harness = await writeHarness(dir, { remoteStage: "needs_remote_credentials" });
    const report = runGate(harness, "status");

    assert.equal(report.status, "blocked_cross_server_readonly");
    assert.equal(report.stages.existingInstances.status, "skipped");
    assert.equal(report.stages.crossServerReadonlyMonitoring.stage, "needs_remote_credentials");
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
    assert.equal(report.safety.writesOpenClawInstanceDirs, false);
    assert(report.nextCommands.some((command: string) => command.includes("push-remote-collector-credentials.sh")));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("go-live gate skips cross-server blockers in local-only topology", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-go-live-gate-"));
  try {
    const harness = await writeHarness(dir, { remoteStage: "needs_remote_credentials" });
    const report = runGate(harness, "check", "local-only");

    assert.equal(report.topologyMode, "local-only");
    assert.equal(report.status, "blocked_managed_actions");
    assert.equal(report.stages.existingInstances.status, "passed");
    assert.equal(report.stages.crossServerReadonlyMonitoring.status, "skipped_local_only");
    assert.equal(report.stages.crossServerReadonlyMonitoring.stage, "local_only");
    assert.equal(report.evidence.remoteRolloutRunner.skipped, true);
    assert.equal(report.safety.crossServerRequired, false);
    assert.equal(report.safety.writesOpenClawInstanceDirs, false);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
    assert(report.nextCommands.some((command: string) => command.includes("live-healthcheck-rollout-runner.sh prepare")));
    assert(report.nextCommands.some((command: string) => command.includes("live-healthcheck-rollout-runner.sh run-approved")));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("go-live gate moves to managed-action blockers after readonly monitoring and healthcheck pass", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-go-live-gate-"));
  try {
    const harness = await writeHarness(dir, { remoteStage: "ready_for_healthcheck" });
    const report = runGate(harness, "check");

    assert.equal(report.status, "blocked_managed_actions");
    assert.equal(report.stages.existingInstances.status, "passed");
    assert.equal(report.stages.crossServerReadonlyMonitoring.status, "ready_for_healthcheck");
    assert.equal(report.stages.managedActionDryRunEvidence.status, "ready");
    assert.equal(report.stages.managedActions.status, "blocked");
    assert(report.nextCommands.some((command: string) => command.includes("live-healthcheck-rollout-runner.sh prepare")));
    assert(report.nextCommands.some((command: string) => command.includes("live-healthcheck-approval.sh approve")));
    assert(report.nextCommands.some((command: string) => command.includes("live-healthcheck-rollout-runner.sh run-approved")));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("go-live gate requires managed action dry-run evidence before live approval", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-go-live-gate-"));
  try {
    const harness = await writeHarness(dir, { remoteStage: "ready_for_healthcheck", dryRunReady: false });
    const report = runGate(harness, "check");

    assert.equal(report.status, "blocked_managed_action_dry_run");
    assert.equal(report.stages.existingInstances.status, "passed");
    assert.equal(report.stages.crossServerReadonlyMonitoring.status, "ready_for_healthcheck");
    assert.equal(report.stages.managedActionDryRunEvidence.status, "blocked");
    assert(report.nextCommands.some((command: string) => command.includes("managed-action-dry-run-gate.sh run")));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("go-live gate blocks immediately when existing instance healthcheck fails", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-go-live-gate-"));
  try {
    const harness = await writeHarness(dir, { remoteStage: "ready_for_healthcheck", healthcheckExit: 2 });
    const report = runGate(harness, "check");

    assert.equal(report.status, "blocked_existing_instances");
    assert.equal(report.stages.existingInstances.status, "failed");
    assert.deepEqual(report.nextCommands, ["./healthcheck.sh"]);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
