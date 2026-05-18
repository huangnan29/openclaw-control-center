import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "tom-readonly", "live-healthcheck-approval-review.sh");

async function writeExecutable(file: string, text: string) {
  await writeFile(file, text, "utf8");
  await chmod(file, 0o755);
}

async function writeHarness(
  dir: string,
  options: {
    readinessStatus?: "waiting_human_approval" | "approved_ready_for_live_window";
    approvalStatus?: "needs_manual_approval" | "approved";
    packetStatus?: "ready" | "blocked";
    cronStatus?: "inbox_cron_installed" | "inbox_cron_not_installed";
    cronNeedsUpdate?: boolean;
    pendingCount?: number;
  } = {},
) {
  const deployDir = join(dir, "deploy");
  const scriptDir = join(dir, "scripts");
  const logFile = join(dir, "commands.log");
  const readinessStatus = options.readinessStatus || "waiting_human_approval";
  const approvalStatus = options.approvalStatus || "needs_manual_approval";
  const packetStatus = options.packetStatus || "ready";
  const cronStatus = options.cronStatus || "inbox_cron_installed";
  const cronNeedsUpdate = options.cronNeedsUpdate === true;
  const pendingCount = options.pendingCount ?? 0;
  await mkdir(scriptDir, { recursive: true });
  await mkdir(deployDir, { recursive: true });

  await writeExecutable(
    join(scriptDir, "live-healthcheck-readiness.sh"),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'readiness %s\\n' "$*" >> "${logFile}"
cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "${readinessStatus}",
  "stages": {
    "approvalPacket": { "report": { "status": "${packetStatus}", "issues": [] } },
    "approval": { "report": { "status": "${approvalStatus}" } },
    "dryRun": {
      "report": {
        "status": "ready",
        "readiness": {
          "dryRun": {
            "latest": {
              "operationRequestId": "dry-run-1",
              "action": "skill_run",
              "targetInstanceId": "tom",
              "operator": "Anan"
            }
          }
        }
      }
    }
  },
  "issues": [],
  "safety": {
    "opensLiveGate": false,
    "callsManagedActionsLiveApi": false,
    "writesOpenClawInstanceDirs": false,
    "restartsOpenClawInstances": false
  }
}
JSON
`,
  );

  await writeExecutable(
    join(scriptDir, "install-managed-action-inbox-cron.sh"),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'cron %s\\n' "$*" >> "${logFile}"
cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "${cronStatus}",
  "installed": ${cronStatus === "inbox_cron_installed" ? "true" : "false"},
  "needsUpdate": ${cronNeedsUpdate ? "true" : "false"},
  "safety": {
    "callsManagedActionsLiveApi": false,
    "writesOpenClawInstanceDirs": false,
    "restartsOpenClawInstances": false
  }
}
JSON
`,
  );

  await writeExecutable(
    join(scriptDir, "managed-action-inbox-runner.sh"),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'inbox %s\\n' "$*" >> "${logFile}"
cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "${pendingCount > 0 ? "inbox_status_ready" : "inbox_empty"}",
  "pendingCount": ${pendingCount},
  "inbox": {
    "source": "control-center-container",
    "dir": "/instances/tom/workspace/control-center-commands/inbox",
    "candidateCount": ${pendingCount}
  },
  "safety": {
    "callsManagedActionsLiveApi": false,
    "writesOpenClawInstanceDirs": false,
    "restartsOpenClawInstances": false
  }
}
JSON
`,
  );

  return { deployDir, scriptDir, logFile };
}

function runReview(harness: Awaited<ReturnType<typeof writeHarness>>, mode: "status" | "check" = "status") {
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

test("approval review 在等待人工批准时给出 approve 下一步且不写不调用 live", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-approval-review-ready-"));
  try {
    const harness = await writeHarness(dir);
    const report = runReview(harness, "status");
    const log = await readFile(harness.logFile, "utf8");

    assert.equal(report.status, "ready_for_human_approval");
    assert.equal(report.summary.readiness, "waiting_human_approval");
    assert.equal(report.summary.approvalPacket, "ready");
    assert.equal(report.summary.approval, "needs_manual_approval");
    assert.equal(report.summary.inboxCron, "inbox_cron_installed");
    assert.equal(report.summary.inboxPendingCount, 0);
    assert(report.nextCommands.some((command: string) => command.includes("final-go-live-approve-and-run-from-tom-token.sh status")));
    assert(report.nextCommands.some((command: string) => command.includes("final-go-live-approve-and-run-from-tom-token.sh approve-and-run")));
    assert(!report.nextCommands.some((command: string) => command.includes("LOCAL_API_TOKEN=<本地令牌>")));
    assert.match(log, /readiness status/);
    assert.match(log, /cron status/);
    assert.match(log, /inbox status/);
    assert.equal(report.safety.generatesApprovalPacket, false);
    assert.equal(report.safety.writesApprovalFile, false);
    assert.equal(report.safety.opensLiveGate, false);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("approval review 在已批准时给出 run-approved 下一步", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-approval-review-approved-"));
  try {
    const harness = await writeHarness(dir, {
      readinessStatus: "approved_ready_for_live_window",
      approvalStatus: "approved",
    });
    const report = runReview(harness, "check");
    const log = await readFile(harness.logFile, "utf8");

    assert.equal(report.status, "approved_ready_for_live_window");
    assert(report.nextCommands.some((command: string) => command.includes("final-go-live-runner.sh run-approved")));
    assert.equal(report.safety.checkRunsHealthcheckOnly, true);
    assert.match(log, /readiness check/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("approval review 在 dry-run inbox 有待处理请求时阻塞", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-approval-review-pending-"));
  try {
    const harness = await writeHarness(dir, { pendingCount: 2 });

    const result = (() => {
      try {
        return {
          exitCode: 0,
          report: runReview(harness, "status"),
        };
      } catch (error: any) {
        return {
          exitCode: error.status ?? 1,
          report: JSON.parse(error.stdout),
        };
      }
    })();

    assert.equal(result.exitCode, 2);
    assert.equal(result.report.status, "blocked_preconditions");
    assert(result.report.issues.some((issue: string) => issue.includes("dry-run inbox 仍有待处理请求")));
    assert(result.report.nextCommands.some((command: string) => command.includes("final-go-live-runner.sh prepare")));
    assert.equal(result.report.safety.opensLiveGate, false);
    assert.equal(result.report.safety.callsManagedActionsLiveApi, false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
