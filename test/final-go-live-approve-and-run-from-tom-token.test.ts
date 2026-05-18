import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "local", "final-go-live-approve-and-run-from-tom-token.sh");

async function writeExecutable(file: string, content: string): Promise<void> {
  await writeFile(file, content, "utf8");
  await chmod(file, 0o755);
}

async function writeHarness(dir: string, options: { token?: string } = {}) {
  const binDir = join(dir, "bin");
  const ssh = join(binDir, "ssh");
  const runner = join(binDir, "final-go-live-runner.sh");
  const review = join(binDir, "final-go-live-review.sh");
  const sshCalls = join(dir, "ssh-calls.txt");
  const runnerCalls = join(dir, "runner-calls.txt");
  const runnerToken = join(dir, "runner-token.txt");
  const discoveryConfig = join(dir, "discover.json");
  const key = join(dir, "tom.key");
  const token = options.token ?? "secret-token";
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
    ssh,
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "${sshCalls}"
if printf '%s\\n' "$*" | grep -q 'awk.*length'; then
  printf '%s\\n' "${token.length}"
  exit 0
fi
printf '%s\\n' "${token}"
`,
  );
  await writeExecutable(
    review,
    `#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{
  "status": "ready_for_human_approval_with_usage_alerts",
  "tom": { "head": "ce2d89d" },
  "summary": {
    "readiness": {
      "status": "waiting_human_approval",
      "approvalPacket": "ready",
      "approval": "needs_manual_approval"
    },
    "dryRunInboxCron": {
      "status": "inbox_cron_installed",
      "needsUpdate": false
    },
    "heartbeatBurnAlertCron": {
      "status": "heartbeat_burn_alert_cron_installed",
      "needsUpdate": false
    },
    "heartbeatBurnAlert": {
      "latest": {
        "status": "heartbeat_burn_alert_triggered"
      }
    }
  },
  "warnings": ["heartbeat/token 告警当前存在 2 个可疑实例"]
}
JSON
`,
  );
  await writeExecutable(
    runner,
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "${runnerCalls}"
printf '%s' "$LOCAL_API_TOKEN" > "${runnerToken}"
cat <<'JSON'
{
  "status": "completed_final_live_healthcheck",
  "tokenEcho": "redacted"
}
JSON
`,
  );
  return { ssh, runner, review, sshCalls, runnerCalls, runnerToken, discoveryConfig, token };
}

function runWrapper(env: Record<string, string>, args: string[] = []) {
  const result = spawnSync(SCRIPT, args, {
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
  };
}

test("approve wrapper status 只读检查 token 长度和 approval review，不要求确认", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-final-approve-token-wrapper-status-"));
  try {
    const harness = await writeHarness(dir);
    const result = runWrapper({
      DISCOVERY_CONFIG: harness.discoveryConfig,
      FINAL_GO_LIVE_APPROVE_TOKEN_SSH_BIN: harness.ssh,
      FINAL_GO_LIVE_RUNNER_SCRIPT: harness.runner,
      FINAL_GO_LIVE_REVIEW_SCRIPT: harness.review,
    }, ["status"]);

    assert.equal(result.exitCode, 0);
    assert.doesNotMatch(result.stdout, /secret-token/);
    const report = JSON.parse(result.stdout);
    assert.equal(report.status, "preflight_ready_for_human_approval");
    assert.equal(report.token.available, true);
    assert.equal(report.token.length, "secret-token".length);
    assert.equal(report.review.status, "ready_for_human_approval_with_usage_alerts");
    assert.equal(report.safety.readsTomContainerTokenLengthOnly, true);
    assert.equal(report.safety.delegatesToFinalRunner, false);
    assert.equal(existsSync(harness.runnerCalls), false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("approve wrapper 缺确认短语时不连接 Tom", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-final-approve-token-wrapper-missing-confirm-"));
  try {
    const harness = await writeHarness(dir);
    const result = runWrapper({
      DISCOVERY_CONFIG: harness.discoveryConfig,
      FINAL_GO_LIVE_APPROVE_TOKEN_SSH_BIN: harness.ssh,
      FINAL_GO_LIVE_RUNNER_SCRIPT: harness.runner,
      FINAL_GO_LIVE_REVIEW_SCRIPT: harness.review,
      APPROVED_BY: "Anan",
    });

    assert.equal(result.exitCode, 2);
    const report = JSON.parse(result.stdout);
    assert.equal(report.status, "blocked_confirmation_required");
    assert.equal(report.safety.blockedBeforeSsh, true);
    assert.equal(existsSync(harness.sshCalls), false);
    assert.equal(existsSync(harness.runnerCalls), false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("approve wrapper 从 Tom 容器取令牌后委托既有 runner 且不打印令牌", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-final-approve-token-wrapper-success-"));
  try {
    const harness = await writeHarness(dir);
    const result = runWrapper({
      DISCOVERY_CONFIG: harness.discoveryConfig,
      FINAL_GO_LIVE_APPROVE_TOKEN_SSH_BIN: harness.ssh,
      FINAL_GO_LIVE_RUNNER_SCRIPT: harness.runner,
      FINAL_GO_LIVE_REVIEW_SCRIPT: harness.review,
      CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN: "I_APPROVE_AND_RUN_FINAL_LIVE_HEALTHCHECK",
      APPROVED_BY: "Anan",
      FINAL_GO_LIVE_OUTPUT: "summary",
    }, ["approve-and-run"]);

    assert.equal(result.exitCode, 0);
    assert.doesNotMatch(result.stdout, /secret-token/);
    assert.doesNotMatch(result.stderr, /secret-token/);
    const sshCalls = await readFile(harness.sshCalls, "utf8");
    assert.match(sshCalls, /docker inspect/);
    const runnerCalls = await readFile(harness.runnerCalls, "utf8");
    assert.match(runnerCalls, /approve-and-run/);
    const delegatedToken = await readFile(harness.runnerToken, "utf8");
    assert.equal(delegatedToken, "secret-token");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("approve wrapper 在 Tom 容器令牌为空时不委托 runner", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-final-approve-token-wrapper-empty-token-"));
  try {
    const harness = await writeHarness(dir, { token: "" });
    const result = runWrapper({
      DISCOVERY_CONFIG: harness.discoveryConfig,
      FINAL_GO_LIVE_APPROVE_TOKEN_SSH_BIN: harness.ssh,
      FINAL_GO_LIVE_RUNNER_SCRIPT: harness.runner,
      FINAL_GO_LIVE_REVIEW_SCRIPT: harness.review,
      CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN: "I_APPROVE_AND_RUN_FINAL_LIVE_HEALTHCHECK",
      APPROVED_BY: "Anan",
    }, ["approve-and-run"]);

    assert.equal(result.exitCode, 2);
    const report = JSON.parse(result.stdout);
    assert.equal(report.status, "blocked_local_token_missing_in_tom_container");
    assert.equal(existsSync(harness.runnerCalls), false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
