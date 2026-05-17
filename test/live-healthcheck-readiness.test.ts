import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "tom-readonly", "live-healthcheck-readiness.sh");

async function writeExecutable(file: string, text: string) {
  await writeFile(file, text, "utf8");
  await chmod(file, 0o755);
}

async function writeHarness(
  dir: string,
  options: {
    approvalStatus?: "needs_manual_approval" | "approved" | "consumed";
    packetReady?: boolean;
  } = {},
) {
  const deployDir = join(dir, "deploy");
  const scriptDir = join(dir, "scripts");
  const logFile = join(dir, "commands.log");
  const approvalStatus = options.approvalStatus || "needs_manual_approval";
  const packetReady = options.packetReady !== false;
  await mkdir(join(deployDir, "runtime", "remote-onboarding", "remote-oracle"), { recursive: true });
  await mkdir(scriptDir, { recursive: true });

  await writeExecutable(
    join(scriptDir, "go-live-gate.sh"),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'go-live %s\\n' "$*" >> "${logFile}"
cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "blocked_managed_actions",
  "topologyMode": "local-only",
  "stages": {
    "existingInstances": { "status": "passed" },
    "crossServerReadonlyMonitoring": { "status": "skipped_local_only" },
    "managedActionDryRunEvidence": { "status": "ready" },
    "managedActions": { "status": "blocked" }
  },
  "safety": {
    "callsManagedActionsLiveApi": false,
    "writesOpenClawInstanceDirs": false
  }
}
JSON
`,
  );

  await writeExecutable(
    join(scriptDir, "managed-action-dry-run-gate.sh"),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'dry-run %s\\n' "$*" >> "${logFile}"
cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "ready",
  "target": { "instanceId": "tom", "action": "healthcheck", "operator": "Anan" },
  "audit": { "count": 1, "latest": { "operationRequestId": "dry-run-1" } },
  "issues": [],
  "safety": { "callsManagedActionsLiveApi": false }
}
JSON
`,
  );

  await writeExecutable(
    join(scriptDir, "live-healthcheck-approval-packet.sh"),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'packet %s\\n' "$*" >> "${logFile}"
cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "${packetReady ? "ready" : "blocked"}",
  "packetFile": "packet.json",
  "target": { "instanceId": "tom", "action": "healthcheck", "operator": "Anan" },
  "issues": ${packetReady ? "[]" : "[\"packet is stale\"]"},
  "safety": {
    "callsManagedActionsLiveApi": false,
    "writesOpenClawInstanceDirs": false,
    "restartsOpenClawInstances": false,
    "bypassesApproval": false
  }
}
JSON
${packetReady ? "" : "exit 2"}
`,
  );

  await writeExecutable(
    join(scriptDir, "live-healthcheck-approval.sh"),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'approval %s\\n' "$*" >> "${logFile}"
cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "${approvalStatus}",
  "approved": ${approvalStatus === "approved" || approvalStatus === "consumed" ? "true" : "false"},
  "consumed": ${approvalStatus === "consumed" ? "true" : "false"},
  "approvedBy": ${approvalStatus === "needs_manual_approval" ? "\"\"" : "\"Anan\""},
  "instanceId": "tom",
  "action": "healthcheck",
  "operator": "Anan",
  "issues": ${approvalStatus === "needs_manual_approval" ? "[\"approved is not true\"]" : "[]"}
}
JSON
`,
  );

  await writeExecutable(
    join(scriptDir, "live-healthcheck-window.sh"),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'window %s\\n' "$*" >> "${logFile}"
cat <<'TEXT'
[测试] 未检测到临时 override 文件
{"status":"needs_manual_approval","approved":false,"consumed":false,"instanceId":"tom","action":"healthcheck","operator":"Anan"}
READONLY_MODE=true
MANAGED_ACTIONS_LIVE_ENABLED=<unset>
MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED=<unset>
readiness.status=blocked
readiness.liveExecutionAvailable=false
readiness.executor.productionWired=false
TEXT
`,
  );

  return { deployDir, scriptDir, logFile };
}

function runReadiness(harness: Awaited<ReturnType<typeof writeHarness>>, mode: "status" | "check" = "status") {
  const output = execFileSync(SCRIPT, [mode], {
    env: {
      ...process.env,
      DEPLOY_DIR: harness.deployDir,
      SCRIPT_DIR: harness.scriptDir,
      OPENCLAW_TOPOLOGY_MODE: "local-only",
    },
    encoding: "utf8",
  });
  return JSON.parse(output);
}

test("live healthcheck readiness 汇总等待人工批准且不调用 live", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-live-readiness-"));
  try {
    const harness = await writeHarness(dir);
    const report = runReadiness(harness, "status");

    assert.equal(report.status, "waiting_human_approval");
    assert.equal(report.stages.approvalPacket.report.status, "ready");
    assert.equal(report.stages.dryRun.report.status, "ready");
    assert.equal(report.stages.approval.report.status, "needs_manual_approval");
    assert(report.nextCommands.some((command: string) => command.includes("live-healthcheck-approval.sh approve")));
    assert.equal(report.safety.generatesApprovalPacket, false);
    assert.equal(report.safety.writesApprovalFile, false);
    assert.equal(report.safety.opensLiveGate, false);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("live healthcheck readiness 在批准后提示一次性演练命令", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-live-readiness-approved-"));
  try {
    const harness = await writeHarness(dir, { approvalStatus: "approved" });
    const report = runReadiness(harness, "check");

    assert.equal(report.status, "approved_ready_for_live_window");
    assert.equal(report.safety.checkRunsHealthcheckOnly, true);
    assert(report.nextCommands.some((command: string) => command.includes("live-healthcheck-rollout-runner.sh run-approved")));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("live healthcheck readiness 在证据包失效时阻塞前置条件", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-live-readiness-blocked-"));
  try {
    const harness = await writeHarness(dir, { packetReady: false });
    const report = runReadiness(harness);

    assert.equal(report.status, "blocked_preconditions");
    assert(report.issues.some((issue: string) => issue.includes("批准前证据包未 ready")));
    assert(report.nextCommands.some((command: string) => command.includes("live-healthcheck-rollout-runner.sh prepare")));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
