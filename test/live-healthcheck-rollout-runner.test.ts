import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
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

async function writeHarness(
  dir: string,
  options: {
    dryRunReady?: boolean;
    readinessStatus?: "waiting_human_approval" | "approved_ready_for_live_window";
    alreadyCompleted?: boolean;
    completedReportOnly?: boolean;
    reportReady?: boolean;
  } = {},
) {
  const deployDir = join(dir, "deploy");
  const scriptDir = join(dir, "scripts");
  const logFile = join(dir, "commands.log");
  const consumedFile = join(dir, "approval-consumed.txt");
  const reportDir = join(deployDir, "runtime", "live-healthcheck-reports");
  const dryRunReady = options.dryRunReady !== false;
  const readinessStatus = options.readinessStatus || "waiting_human_approval";
  const reportReady = options.reportReady !== false;
  await mkdir(join(deployDir, "runtime"), { recursive: true });
  await mkdir(reportDir, { recursive: true });
  await mkdir(scriptDir, { recursive: true });
  if (options.alreadyCompleted === true || options.completedReportOnly === true) {
    if (options.alreadyCompleted === true) await writeFile(consumedFile, "consumed\n", "utf8");
    if (reportReady) {
      await writeFile(
        join(reportDir, "live-healthcheck-report-20260517T000000+0000.json"),
        JSON.stringify(
          {
            schemaVersion: 1,
            status: "passed",
            approval: { consumed: true },
            audit: {
              liveResultFound: true,
              liveExecution: true,
              mutatesOpenClawInstance: false,
            },
            impact: { ok: true },
          },
          null,
          2,
        ),
        "utf8",
      );
    }
  }

  await writeExecutable(
    join(scriptDir, "live-healthcheck-readiness.sh"),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'readiness %s\\n' "$*" >> "${logFile}"
status="${readinessStatus}"
approval_status="${readinessStatus === "approved_ready_for_live_window" ? "approved" : "needs_manual_approval"}"
if [ -f "${consumedFile}" ]; then
  status="approval_consumed"
  approval_status="consumed"
fi
cat <<JSON
{
  "schemaVersion": 1,
  "status": "$status",
  "target": { "instanceId": "tom", "action": "healthcheck", "operator": "Anan" },
  "stages": {
    "approvalPacket": { "report": { "status": "ready" } },
    "approval": { "report": { "status": "$approval_status" } },
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

  await writeExecutable(
    join(scriptDir, "live-healthcheck-window.sh"),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'window %s confirm-window=%s confirm-live=%s token=%s\\n' "$*" "\${CONFIRM_LIVE_HEALTHCHECK_WINDOW:-}" "\${CONFIRM_LIVE_HEALTHCHECK:-}" "\${LOCAL_API_TOKEN:-}" >> "${logFile}"
if [ "\${1:-status}" = "status" ]; then
  cat <<'TEXT'
READONLY_MODE=true
MANAGED_ACTIONS_LIVE_ENABLED=<unset>
MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED=<unset>
TEXT
  exit 0
fi
touch "${consumedFile}"
cat > "${reportDir}/live-healthcheck-report-20260517T010000+0000.json" <<'JSON'
{
  "schemaVersion": 1,
  "status": "passed",
  "approval": {
    "consumed": true
  },
  "audit": {
    "liveResultFound": true,
    "liveExecution": true,
    "mutatesOpenClawInstance": false
  },
  "impact": {
    "ok": true
  }
}
JSON
cat <<'TEXT'
live healthcheck window completed
TEXT
`,
  );

  return { deployDir, scriptDir, logFile };
}

function runRunner(harness: Awaited<ReturnType<typeof writeHarness>>, mode: "status" | "prepare" | "run-approved" | "verify-completed", extraEnv: Record<string, string> = {}) {
  const output = execFileSync(SCRIPT, [mode], {
    env: {
      ...process.env,
      DEPLOY_DIR: harness.deployDir,
      SCRIPT_DIR: harness.scriptDir,
      OPENCLAW_TOPOLOGY_MODE: "local-only",
      ...extraEnv,
    },
    encoding: "utf8",
  });
  return JSON.parse(output);
}

function runRunnerResult(harness: Awaited<ReturnType<typeof writeHarness>>, mode: "status" | "prepare" | "run-approved" | "verify-completed", extraEnv: Record<string, string> = {}) {
  const result = spawnSync(SCRIPT, [mode], {
    env: {
      ...process.env,
      DEPLOY_DIR: harness.deployDir,
      SCRIPT_DIR: harness.scriptDir,
      OPENCLAW_TOPOLOGY_MODE: "local-only",
      ...extraEnv,
    },
    encoding: "utf8",
  });
  return {
    exitCode: typeof result.status === "number" ? result.status : 1,
    report: JSON.parse(result.stdout),
    stderr: result.stderr,
  };
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
    const result = runRunnerResult(harness, "prepare");
    const report = result.report;
    const log = await readFile(harness.logFile, "utf8");

    assert.notEqual(result.exitCode, 0);
    assert.equal(report.status, "blocked_dry_run");
    assert(report.issues.some((issue: string) => issue.includes("dry-run 证据未 ready")));
    assert.match(log, /dry-run status/);
    assert.doesNotMatch(log, /approval prepare|packet generate|readiness check|approve/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("live healthcheck rollout runner run-approved 未批准时不会打开窗口", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-live-rollout-runner-unapproved-"));
  try {
    const harness = await writeHarness(dir);
    const result = runRunnerResult(harness, "run-approved");
    const report = result.report;
    const log = await readFile(harness.logFile, "utf8");

    assert.notEqual(result.exitCode, 0);
    assert.equal(report.status, "blocked_not_approved");
    assert.equal(report.safety.opensLiveGate, false);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
    assert.match(log, /readiness check/);
    assert.doesNotMatch(log, /window run/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("live healthcheck rollout runner run-approved 缺确认时不会打开窗口", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-live-rollout-runner-confirm-"));
  try {
    const harness = await writeHarness(dir, { readinessStatus: "approved_ready_for_live_window" });
    const result = runRunnerResult(harness, "run-approved");
    const report = result.report;
    const log = await readFile(harness.logFile, "utf8");

    assert.notEqual(result.exitCode, 0);
    assert.equal(report.status, "blocked_confirmation_required");
    assert.equal(report.safety.opensLiveGate, false);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
    assert.match(log, /readiness check/);
    assert.doesNotMatch(log, /window run/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("live healthcheck rollout runner run-approved 在批准和确认后调用一次性窗口", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-live-rollout-runner-live-"));
  try {
    const harness = await writeHarness(dir, { readinessStatus: "approved_ready_for_live_window" });
    const report = runRunner(harness, "run-approved", {
      CONFIRM_LIVE_HEALTHCHECK_RUNNER: "I_UNDERSTAND_THIS_RUNS_APPROVED_LIVE_HEALTHCHECK",
      LOCAL_API_TOKEN: "test-token",
    });
    const log = await readFile(harness.logFile, "utf8");

    assert.equal(report.status, "completed_live_healthcheck");
    assert.equal(report.safety.opensLiveGate, true);
    assert.equal(report.safety.callsManagedActionsLiveApi, true);
    assert.equal(report.safety.requiresApprovedReadiness, true);
    assert.equal(report.safety.requiresRunnerConfirmation, true);
    assert.equal(report.stages.postLiveVerify.status, "verified_live_healthcheck_completed");
    assert.match(log, /readiness check/);
    assert.match(log, /window run/);
    assert.match(log, /confirm-window=I_UNDERSTAND_THIS_TEMPORARILY_ENABLES_LIVE_GATE/);
    assert.match(log, /confirm-live=I_UNDERSTAND_THIS_CALLS_LIVE_API/);
    assert.match(log, /token=test-token/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("live healthcheck rollout runner verify-completed 只读验收已完成演练", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-live-rollout-runner-verify-"));
  try {
    const harness = await writeHarness(dir, { alreadyCompleted: true });
    const report = runRunner(harness, "verify-completed");
    const log = await readFile(harness.logFile, "utf8");

    assert.equal(report.status, "verified_live_healthcheck_completed");
    assert.equal(report.stages.readiness.report.status, "approval_consumed");
    assert.equal(report.stages.liveWindowStatus.readonlyMode, "true");
    assert.equal(report.stages.latestReport.report.status, "passed");
    assert.equal(report.safety.opensLiveGate, false);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
    assert.equal(report.safety.writesOpenClawInstanceDirs, false);
    assert.match(log, /readiness check/);
    assert.doesNotMatch(log, /window run/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("live healthcheck rollout runner verify-completed 在后续部署导致 readiness 阻塞时仍以 passed 报告验收", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-live-rollout-runner-verify-report-"));
  try {
    const harness = await writeHarness(dir, { completedReportOnly: true });
    const report = runRunner(harness, "verify-completed");
    const log = await readFile(harness.logFile, "utf8");

    assert.equal(report.status, "verified_live_healthcheck_completed");
    assert.equal(report.stages.readiness.report.status, "waiting_human_approval");
    assert.equal(report.stages.latestReport.report.status, "passed");
    assert.equal(report.stages.latestReport.report.approval.consumed, true);
    assert.equal(report.stages.liveWindowStatus.readonlyMode, "true");
    assert.equal(report.safety.opensLiveGate, false);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
    assert.match(log, /readiness check/);
    assert.match(log, /window status/);
    assert.doesNotMatch(log, /window run/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("live healthcheck rollout runner verify-completed 缺报告时阻塞", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-live-rollout-runner-verify-blocked-"));
  try {
    const harness = await writeHarness(dir, { alreadyCompleted: true, reportReady: false });
    const result = runRunnerResult(harness, "verify-completed");
    const log = await readFile(harness.logFile, "utf8");

    assert.notEqual(result.exitCode, 0);
    assert.equal(result.report.status, "blocked_post_live_verification");
    assert(result.report.issues.some((issue: string) => issue.includes("未找到 live healthcheck JSON 报告")));
    assert.equal(result.report.safety.opensLiveGate, false);
    assert.equal(result.report.safety.callsManagedActionsLiveApi, false);
    assert.match(log, /readiness check/);
    assert.doesNotMatch(log, /window run/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
