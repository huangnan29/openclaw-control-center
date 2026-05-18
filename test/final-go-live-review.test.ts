import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "local", "final-go-live-review.sh");

async function writeExecutable(file: string, content: string): Promise<void> {
  await writeFile(file, content, "utf8");
  await chmod(file, 0o755);
}

async function writeHarness(dir: string, options: { inboxCronStatus?: string; inboxNeedsUpdate?: boolean } = {}) {
  const binDir = join(dir, "bin");
  const ssh = join(binDir, "ssh");
  const sshCalls = join(dir, "ssh-calls.txt");
  const discoveryConfig = join(dir, "discover.json");
  const key = join(dir, "tom.key");
  await mkdir(binDir, { recursive: true });
  await writeFile(key, "fake key\n", "utf8");
  await chmod(key, 0o600);
  await writeFile(
    discoveryConfig,
    JSON.stringify(
      {
        tom: {
          host: "146.235.226.66",
          user: "ubuntu",
          port: 22,
          sshKey: key,
          deployDir: "/srv/openclaw-control-center-readonly",
          strictHostKeyChecking: "accept-new",
        },
      },
      null,
      2,
    ),
    "utf8",
  );

  const inboxStatus = options.inboxCronStatus || "inbox_cron_installed";
  const inboxNeedsUpdate = options.inboxNeedsUpdate === true;
  await writeExecutable(
    ssh,
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "${sshCalls}"
if printf '%s\\n' "$*" | grep -q 'git -C repo rev-parse'; then
  printf '2441930\\n'
  exit 0
fi
if printf '%s\\n' "$*" | grep -q 'live-healthcheck-readiness.sh status'; then
  cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "waiting_human_approval",
  "stages": {
    "approvalPacket": { "report": { "status": "ready", "issues": [] } },
    "approval": { "report": { "status": "needs_manual_approval" } }
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
  exit 0
fi
if printf '%s\\n' "$*" | grep -q 'install-managed-action-inbox-cron.sh status'; then
  cat <<JSON
{
  "schemaVersion": 1,
  "status": "${inboxStatus}",
  "installed": true,
  "needsUpdate": ${inboxNeedsUpdate ? "true" : "false"}
}
JSON
  exit 0
fi
if printf '%s\\n' "$*" | grep -q 'install-heartbeat-burn-alert-cron.sh status'; then
  cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "heartbeat_burn_alert_cron_installed",
  "installed": true,
  "needsUpdate": false
}
JSON
  exit 0
fi
if printf '%s\\n' "$*" | grep -q 'heartbeat-burn-alert-runner.sh status'; then
  cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "heartbeat_burn_alert_status_ready",
  "latest": {
    "status": "heartbeat_burn_alert_triggered",
    "generatedAt": "2026-05-18T15:45:02.278Z",
    "suspiciousRows": 2,
    "suspiciousInstances": [
      { "instanceId": "main", "signal": "periodic_small_growth" },
      { "instanceId": "deepseek", "signal": "periodic_small_growth" }
    ]
  }
}
JSON
  exit 0
fi
printf 'unexpected ssh command: %s\\n' "$*" >&2
exit 3
`,
  );

  return { discoveryConfig, ssh, sshCalls };
}

function runReview(env: Record<string, string>) {
  const result = spawnSync(SCRIPT, ["status"], {
    cwd: ROOT,
    env: {
      ...process.env,
      ...env,
    },
    encoding: "utf8",
  });
  return {
    exitCode: typeof result.status === "number" ? result.status : 1,
    stdout: result.stdout,
    stderr: result.stderr,
    report: JSON.parse(result.stdout),
  };
}

test("final go-live review 汇总人工批准前状态并保留用量告警为 warning", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-final-go-live-review-"));
  try {
    const harness = await writeHarness(dir);
    const result = runReview({
      DISCOVERY_CONFIG: harness.discoveryConfig,
      FINAL_GO_LIVE_REVIEW_SSH_BIN: harness.ssh,
    });

    assert.equal(result.exitCode, 0);
    assert.equal(result.report.status, "ready_for_human_approval_with_usage_alerts");
    assert.equal(result.report.summary.readiness.status, "waiting_human_approval");
    assert.equal(result.report.summary.readiness.approvalPacket, "ready");
    assert.equal(result.report.summary.readiness.approval, "needs_manual_approval");
    assert.equal(result.report.summary.dryRunInboxCron.needsUpdate, false);
    assert.equal(result.report.summary.heartbeatBurnAlertCron.needsUpdate, false);
    assert.equal(result.report.summary.heartbeatBurnAlert.latest.suspiciousRows, 2);
    assert(result.report.warnings.some((warning: string) => warning.includes("main(periodic_small_growth)")));
    assert(result.report.warnings.some((warning: string) => warning.includes("deepseek(periodic_small_growth)")));
    assert.equal(result.report.safety.opensLiveGate, false);
    assert.equal(result.report.safety.callsManagedActionsLiveApi, false);
    assert.equal(result.report.safety.writesOpenClawInstanceDirs, false);
    assert(result.report.nextCommands.some((command: string) => command.includes("final-go-live-approve-and-run-from-tom-token.sh status")));
    assert(result.report.nextCommands.some((command: string) => command.includes("final-go-live-approve-and-run-from-tom-token.sh approve-and-run")));
    assert(!result.report.nextCommands.some((command: string) => command.includes("LOCAL_API_TOKEN=<本地令牌>")));
    const sshCalls = await readFile(harness.sshCalls, "utf8");
    assert.doesNotMatch(sshCalls, /approve runtime\/live-healthcheck-approval/);
    assert.doesNotMatch(sshCalls, /managed-actions\/live/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("final go-live review 在 dry-run inbox cron 需要更新时阻断批准建议", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-final-go-live-review-blocked-"));
  try {
    const harness = await writeHarness(dir, {
      inboxCronStatus: "inbox_cron_needs_update",
      inboxNeedsUpdate: true,
    });
    const result = runReview({
      DISCOVERY_CONFIG: harness.discoveryConfig,
      FINAL_GO_LIVE_REVIEW_SSH_BIN: harness.ssh,
    });

    assert.equal(result.exitCode, 2);
    assert.equal(result.report.status, "blocked_preconditions");
    assert(result.report.issues.some((issue: string) => issue.includes("dry-run inbox cron")));
    assert(!result.report.nextCommands.some((command: string) => command.includes("approve-and-run")));
    assert.equal(result.report.safety.opensLiveGate, false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
