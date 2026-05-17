import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "local", "final-go-live-runner.sh");

async function writeExecutable(file: string, content: string): Promise<void> {
  await writeFile(file, content, "utf8");
  await chmod(file, 0o755);
}

async function writeHarness(dir: string, options: { hasPrepareStep?: boolean; tomRunStatus?: "blocked_not_approved" | "completed_live_healthcheck" } = {}) {
  const binDir = join(dir, "bin");
  const stateFile = join(dir, "state.txt");
  const statusScript = join(binDir, "final-go-live-status.sh");
  const ssh = join(binDir, "ssh");
  const sshCalls = join(dir, "ssh-calls.txt");
  const discoveryConfig = join(dir, "discover-remote-oracle.json");
  const key = join(dir, "tom.key");
  const hasPrepareStep = options.hasPrepareStep !== false;
  const tomRunStatus = options.tomRunStatus || "blocked_not_approved";

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
    statusScript,
    `#!/usr/bin/env bash
set -euo pipefail
mode="\${1:-status}"
prepared="false"
if [ -f "${stateFile}" ]; then prepared="true"; fi
if [ "$prepared" = "true" ]; then
  next='["CONFIRM_APPROVAL_RECORD=I_APPROVE_LIVE_HEALTHCHECK_RECORD APPROVED_BY=Anan repo/ops/tom-readonly/live-healthcheck-approval.sh approve runtime/live-healthcheck-approval.json"]'
else
  if [ "${hasPrepareStep ? "1" : "0"}" = "1" ]; then
    next='["repo/ops/tom-readonly/live-healthcheck-rollout-runner.sh prepare"]'
  else
    next='["repo/ops/tom-readonly/managed-action-dry-run-gate.sh status"]'
  fi
fi
cat <<JSON
{
  "schemaVersion": 1,
  "status": "blocked_managed_actions",
  "mode": "$mode",
  "topologyMode": "local-only",
  "tom": {
    "goLiveGate": {
      "report": {
        "status": "blocked_managed_actions",
        "stages": {
          "existingInstances": { "status": "$([ "$mode" = "check" ] && printf passed || printf skipped)" },
          "managedActionDryRunEvidence": { "status": "ready" },
          "managedActions": { "status": "blocked" }
        }
      }
    }
  },
  "nextCommands": $next,
  "safety": {
    "writesLocalFiles": false,
    "writesTomRuntime": false,
    "callsManagedActionsLiveApi": false,
    "writesOpenClawInstanceDirs": false,
    "restartsOpenClawInstances": false
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
if printf '%s\\n' "$*" | grep -q 'live-healthcheck-rollout-runner.sh prepare'; then
  touch "${stateFile}"
  cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "prepared_waiting_human_approval",
  "nextCommands": [
    "CONFIRM_APPROVAL_RECORD=I_APPROVE_LIVE_HEALTHCHECK_RECORD APPROVED_BY=Anan repo/ops/tom-readonly/live-healthcheck-approval.sh approve runtime/live-healthcheck-approval.json"
  ],
  "safety": {
    "approvesLiveHealthcheck": false,
    "opensLiveGate": false,
    "callsManagedActionsLiveApi": false,
    "writesOpenClawInstanceDirs": false
  }
}
JSON
  exit 0
fi
if printf '%s\\n' "$*" | grep -q 'live-healthcheck-rollout-runner.sh run-approved'; then
  if [ "${tomRunStatus}" = "completed_live_healthcheck" ]; then
    cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "completed_live_healthcheck",
  "nextCommands": ["repo/ops/tom-readonly/live-healthcheck-readiness.sh check"],
  "safety": {
    "opensLiveGate": true,
    "callsManagedActionsLiveApi": true,
    "writesOpenClawInstanceDirs": false
  }
}
JSON
    exit 0
  fi
  cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "blocked_not_approved",
  "issues": ["readiness 不是 approved_ready_for_live_window：waiting_human_approval"],
  "nextCommands": [
    "CONFIRM_APPROVAL_RECORD=I_APPROVE_LIVE_HEALTHCHECK_RECORD APPROVED_BY=Anan repo/ops/tom-readonly/live-healthcheck-approval.sh approve runtime/live-healthcheck-approval.json"
  ],
  "safety": {
    "opensLiveGate": false,
    "callsManagedActionsLiveApi": false,
    "writesOpenClawInstanceDirs": false
  }
}
JSON
  exit 2
fi
echo "unexpected ssh command" >&2
exit 2
`,
  );

  return { statusScript, ssh, sshCalls, discoveryConfig };
}

function runRunner(
  harness: Awaited<ReturnType<typeof writeHarness>>,
  mode: "status" | "prepare" | "run-approved",
  extraEnv: Record<string, string> = {},
) {
  const result = spawnSync(SCRIPT, [mode], {
    cwd: ROOT,
    env: {
      ...process.env,
      DISCOVERY_CONFIG: harness.discoveryConfig,
      FINAL_GO_LIVE_STATUS_SCRIPT: harness.statusScript,
      FINAL_GO_LIVE_RUNNER_SSH_BIN: harness.ssh,
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

test("final go-live runner status 只读取最终状态", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-final-go-live-runner-"));
  try {
    const harness = await writeHarness(dir);
    const { exitCode, report } = runRunner(harness, "status");

    assert.equal(exitCode, 0);
    assert.equal(report.status, "blocked_managed_actions");
    assert.equal(report.safety.readsStatusOnly, true);
    assert.equal(report.safety.opensLiveGate, false);
    await assert.rejects(readFile(harness.sshCalls, "utf8"));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("final go-live runner prepare 自动推进到人工批准前", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-final-go-live-runner-prepare-"));
  try {
    const harness = await writeHarness(dir);
    const { exitCode, report } = runRunner(harness, "prepare");
    const sshLog = await readFile(harness.sshCalls, "utf8");

    assert.equal(exitCode, 0);
    assert.equal(report.status, "prepared_waiting_human_approval");
    assert.equal(report.safety.opensLiveGate, false);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
    assert(report.nextCommands.some((command: string) => command.includes("live-healthcheck-approval.sh approve")));
    assert.equal(report.nextCommands.some((command: string) => command.includes("live-healthcheck-rollout-runner.sh prepare")), false);
    assert.match(sshLog, /live-healthcheck-rollout-runner\.sh prepare/);
    assert.doesNotMatch(sshLog, /run-approved/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("final go-live runner prepare 没有 prepare 下一步时阻塞", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-final-go-live-runner-blocked-"));
  try {
    const harness = await writeHarness(dir, { hasPrepareStep: false });
    const { exitCode, report } = runRunner(harness, "prepare");

    assert.notEqual(exitCode, 0);
    assert.equal(report.status, "blocked_no_prepare_step");
    assert.equal(report.safety.opensLiveGate, false);
    await assert.rejects(readFile(harness.sshCalls, "utf8"));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("final go-live runner run-approved 缺确认时不连接 Tom", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-final-go-live-runner-confirm-"));
  try {
    const harness = await writeHarness(dir);
    const { exitCode, report } = runRunner(harness, "run-approved");

    assert.notEqual(exitCode, 0);
    assert.equal(report.status, "blocked_confirmation_required");
    assert.equal(report.safety.connectsTomSsh, false);
    assert.equal(report.safety.opensLiveGate, false);
    await assert.rejects(readFile(harness.sshCalls, "utf8"));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("final go-live runner run-approved 透传 Tom 阻断并返回非零", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-final-go-live-runner-run-blocked-"));
  try {
    const harness = await writeHarness(dir);
    const { exitCode, report } = runRunner(harness, "run-approved", {
      CONFIRM_FINAL_GO_LIVE_RUNNER: "I_UNDERSTAND_THIS_RUNS_APPROVED_FINAL_GO_LIVE",
      LOCAL_API_TOKEN: "test-token",
    });
    const sshLog = await readFile(harness.sshCalls, "utf8");

    assert.notEqual(exitCode, 0);
    assert.equal(report.status, "blocked_not_approved");
    assert.equal(report.safety.opensLiveGate, false);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
    assert(report.nextCommands.some((command: string) => command.includes("live-healthcheck-approval.sh approve")));
    assert.equal(report.nextCommands.some((command: string) => command.includes("live-healthcheck-rollout-runner.sh prepare")), false);
    assert.match(sshLog, /live-healthcheck-rollout-runner\.sh run-approved/);
    assert.doesNotMatch(JSON.stringify(report), /test-token/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
