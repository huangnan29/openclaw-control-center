import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "local", "final-go-live-completion-audit.sh");

async function writeExecutable(file: string, content: string): Promise<void> {
  await writeFile(file, content, "utf8");
  await chmod(file, 0o755);
}

async function writeHarness(dir: string, options: { healthcheckOk?: boolean } = {}) {
  const binDir = join(dir, "bin");
  const review = join(binDir, "final-go-live-review.sh");
  const ssh = join(binDir, "ssh");
  const sshCalls = join(dir, "ssh-calls.txt");
  const discoveryConfig = join(dir, "discover.json");
  const key = join(dir, "tom.key");
  const healthcheckOk = options.healthcheckOk !== false;
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
  await writeExecutable(
    review,
    `#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "ready_for_human_approval_with_usage_alerts",
  "mode": "status",
  "tom": { "head": "be582a5" },
  "summary": {
    "readiness": {
      "status": "waiting_human_approval",
      "approvalPacket": "ready",
      "approval": "needs_manual_approval",
      "issues": []
    },
    "dryRunInboxCron": {
      "status": "inbox_cron_installed",
      "installed": true,
      "needsUpdate": false
    },
    "heartbeatBurnAlertCron": {
      "status": "heartbeat_burn_alert_cron_installed",
      "installed": true,
      "needsUpdate": false
    },
    "heartbeatBurnAlert": {
      "status": "heartbeat_burn_alert_status_ready",
      "latest": {
        "status": "heartbeat_burn_alert_triggered",
        "suspiciousRows": 2,
        "suspiciousInstances": [
          { "instanceId": "main", "signal": "periodic_small_growth" },
          { "instanceId": "deepseek", "signal": "periodic_small_growth" }
        ]
      }
    }
  },
  "warnings": ["heartbeat/token 告警当前存在 2 个可疑实例：main(periodic_small_growth)，deepseek(periodic_small_growth)"],
  "safety": {
    "opensLiveGate": false,
    "callsManagedActionsLiveApi": false,
    "writesOpenClawInstanceDirs": false
  }
}
JSON
`,
  );
  await writeExecutable(
    ssh,
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "${sshCalls}"
if printf '%s\\n' "$*" | grep -q './healthcheck.sh'; then
  if [ "${healthcheckOk ? "1" : "0"}" = "1" ]; then
    printf '[ok] 健康检查通过\\n'
    exit 0
  fi
  printf '[失败] healthcheck failed\\n' >&2
  exit 2
fi
printf 'unexpected ssh command: %s\\n' "$*" >&2
exit 3
`,
  );
  return { review, ssh, sshCalls, discoveryConfig };
}

function runAudit(env: Record<string, string>) {
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

test("final go-live completion audit 标出人工 approval 为唯一硬阻塞", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-final-go-live-completion-audit-"));
  try {
    const harness = await writeHarness(dir);
    const result = runAudit({
      DISCOVERY_CONFIG: harness.discoveryConfig,
      FINAL_GO_LIVE_REVIEW_SCRIPT: harness.review,
      FINAL_GO_LIVE_AUDIT_SSH_BIN: harness.ssh,
    });

    assert.equal(result.exitCode, 0);
    assert.equal(result.report.status, "blocked_human_approval_required");
    assert.equal(result.report.progress.warnings, 1);
    assert(result.report.requirements.some((item: { id: string; status: string }) => item.id === "usage_alerts_review" && item.status === "warning"));
    assert(result.report.requirements.some((item: { id: string; detail: string }) => item.id === "usage_alerts_review" && item.detail.includes("main(periodic_small_growth)")));
    assert(result.report.requirements.some((item: { id: string; status: string }) => item.id === "final_live_healthcheck" && item.status === "pending"));
    assert(result.report.hardBlockers.some((item: string) => item.includes("最终 live healthcheck")));
    assert.equal(result.report.safety.opensLiveGate, false);
    assert.equal(result.report.safety.callsManagedActionsLiveApi, false);
    assert.equal(result.report.safety.writesOpenClawInstanceDirs, false);
    assert(result.report.nextCommands.some((command: string) => command.includes("final-go-live-approve-and-run-from-tom-token.sh status")));
    assert(result.report.nextCommands.some((command: string) => command.includes("final-go-live-approve-and-run-from-tom-token.sh approve-and-run")));
    assert(!result.report.nextCommands.some((command: string) => command.includes("LOCAL_API_TOKEN=<本地令牌>")));
    const sshCalls = await readFile(harness.sshCalls, "utf8");
    assert.match(sshCalls, /\.\/healthcheck\.sh/);
    assert.doesNotMatch(sshCalls, /approve runtime\/live-healthcheck-approval/);
    assert.doesNotMatch(sshCalls, /managed-actions\/live/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("final go-live completion audit 在 Tom healthcheck 失败时返回 precondition blocker", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-final-go-live-completion-audit-healthcheck-"));
  try {
    const harness = await writeHarness(dir, { healthcheckOk: false });
    const result = runAudit({
      DISCOVERY_CONFIG: harness.discoveryConfig,
      FINAL_GO_LIVE_REVIEW_SCRIPT: harness.review,
      FINAL_GO_LIVE_AUDIT_SSH_BIN: harness.ssh,
    });

    assert.equal(result.exitCode, 2);
    assert.equal(result.report.status, "blocked_preconditions");
    assert(result.report.requirements.some((item: { id: string; status: string }) => item.id === "tom_readonly_health" && item.status === "fail"));
    assert(result.report.hardBlockers.some((item: string) => item.includes("Tom 单 Oracle 多实例只读健康检查")));
    assert(result.report.nextCommands.some((command: string) => command.includes("./healthcheck.sh")));
    assert(result.report.nextCommands.some((command: string) => command.includes("final-go-live-runner.sh prepare")));
    assert(!result.report.nextCommands.some((command: string) => command.includes("approve-and-run")));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
