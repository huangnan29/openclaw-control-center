import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "tom-readonly", "live-healthcheck-rollout-runner.sh");

async function writeExecutable(file: string, text: string) {
  await writeFile(file, text, "utf8");
  await chmod(file, 0o755);
}

async function writeHarness(dir: string, options: { dryRunReady?: boolean } = {}) {
  const deployDir = join(dir, "deploy");
  const scriptDir = join(dir, "scripts");
  const logFile = join(dir, "commands.log");
  const dryRunReady = options.dryRunReady !== false;
  await mkdir(join(deployDir, "runtime"), { recursive: true });
  await mkdir(scriptDir, { recursive: true });

  await writeExecutable(
    join(scriptDir, "live-healthcheck-readiness.sh"),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'readiness %s\\n' "$*" >> "${logFile}"
cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "waiting_human_approval",
  "target": { "instanceId": "tom", "action": "healthcheck", "operator": "Anan" },
  "stages": {
    "approvalPacket": { "report": { "status": "ready" } },
    "approval": { "report": { "status": "needs_manual_approval" } },
    "liveWindow": { "readonlyMode": "true", "liveEnabled": "<unset>" }
  },
  "issues": [],
  "nextCommands": [
    "CONFIRM_APPROVAL_RECORD=I_APPROVE_LIVE_HEALTHCHECK_RECORD APPROVED_BY=Anan repo/ops/tom-readonly/live-healthcheck-approval.sh approve runtime/live-healthcheck-approval.json"
  ],
  "safety": {
    "writesApprovalFile": false,
    "opensLiveGate": false,
    "callsManagedActionsLiveApi": false
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
  "status": "${dryRunReady ? "ready" : "blocked"}",
  "target": { "instanceId": "tom", "action": "healthcheck", "operator": "Anan" },
  "issues": ${dryRunReady ? "[]" : "[\"没有匹配的 dry-run 审计\"]"},
  "nextCommands": [
    "CONFIRM_MANAGED_ACTION_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CREATES_DRY_RUN_AUDIT_RECORD LOCAL_API_TOKEN=<本地令牌> repo/ops/tom-readonly/managed-action-dry-run-gate.sh run"
  ],
  "safety": {
    "callsManagedActionsLiveApi": false
  }
}
JSON
${dryRunReady ? "" : "exit 2"}
`,
  );

  await writeExecutable(
    join(scriptDir, "live-healthcheck-approval.sh"),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'approval %s\\n' "$*" >> "${logFile}"
cat <<'JSON'
{
  "status": "needs_manual_approval",
  "approved": false,
  "consumed": false,
  "instanceId": "tom",
  "action": "healthcheck",
  "operator": "Anan"
}
JSON
`,
  );

  await writeExecutable(
    join(scriptDir, "live-healthcheck-approval-packet.sh"),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'packet %s\\n' "$*" >> "${logFile}"
if [ "$1" = "generate" ]; then
  printf '%s\\n' "${deployDir}/runtime/live-healthcheck-approval-packets/packet.json"
  exit 0
fi
cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "ready",
  "packetFile": "packet.json",
  "target": { "instanceId": "tom", "action": "healthcheck", "operator": "Anan" },
  "issues": [],
  "safety": {
    "callsManagedActionsLiveApi": false,
    "writesOpenClawInstanceDirs": false
  }
}
JSON
`,
  );

  return { deployDir, scriptDir, logFile };
}

function runRunner(harness: Awaited<ReturnType<typeof writeHarness>>, mode: "status" | "prepare") {
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

test("live healthcheck rollout runner status 只读取 readiness", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-live-rollout-runner-"));
  try {
    const harness = await writeHarness(dir);
    const report = runRunner(harness, "status");
    const log = await readFile(harness.logFile, "utf8");

    assert.equal(report.status, "waiting_human_approval");
    assert.equal(report.safety.readsStatusOnly, true);
    assert.equal(report.safety.generatesApprovalPacket, false);
    assert.equal(report.safety.approvesLiveHealthcheck, false);
    assert.equal(report.safety.opensLiveGate, false);
    assert.match(log, /readiness status/);
    assert.doesNotMatch(log, /packet generate|approval prepare|approve|window run/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("live healthcheck rollout runner prepare 自动推进到人工批准前", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-live-rollout-runner-prepare-"));
  try {
    const harness = await writeHarness(dir);
    const report = runRunner(harness, "prepare");
    const log = await readFile(harness.logFile, "utf8");

    assert.equal(report.status, "prepared_waiting_human_approval");
    assert.equal(report.safety.generatesApprovalPacket, true);
    assert.equal(report.safety.writesApprovalTemplateOnly, true);
    assert.equal(report.safety.approvesLiveHealthcheck, false);
    assert.equal(report.safety.opensLiveGate, false);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
    assert.match(log, /dry-run status/);
    assert.match(log, /approval prepare/);
    assert.match(log, /packet generate/);
    assert.match(log, /packet check/);
    assert.match(log, /readiness check/);
    assert.doesNotMatch(log, /approve|live-healthcheck-window\.sh run|managed-actions\/live/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("live healthcheck rollout runner prepare 在 dry-run 不满足时停止", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-live-rollout-runner-blocked-"));
  try {
    const harness = await writeHarness(dir, { dryRunReady: false });
    const report = runRunner(harness, "prepare");
    const log = await readFile(harness.logFile, "utf8");

    assert.equal(report.status, "blocked_dry_run");
    assert(report.issues.some((issue: string) => issue.includes("dry-run 证据未 ready")));
    assert.match(log, /dry-run status/);
    assert.doesNotMatch(log, /approval prepare|packet generate|readiness check|approve/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
