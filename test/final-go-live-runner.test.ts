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

async function writeHarness(
  dir: string,
  options: {
    hasPrepareStep?: boolean;
    includeApprovalWithPrepare?: boolean;
    approvalReviewStatus?: "ready_for_human_approval" | "blocked_preconditions" | "approved_ready_for_live_window";
    tomRunStatus?: "blocked_not_approved" | "completed_live_healthcheck";
  } = {},
) {
  const binDir = join(dir, "bin");
  const stateFile = join(dir, "state.txt");
  const statusScript = join(binDir, "final-go-live-status.sh");
  const ssh = join(binDir, "ssh");
  const sshCalls = join(dir, "ssh-calls.txt");
  const discoveryConfig = join(dir, "discover-remote-oracle.json");
  const key = join(dir, "tom.key");
  const hasPrepareStep = options.hasPrepareStep !== false;
  const includeApprovalWithPrepare = options.includeApprovalWithPrepare === true;
  const approvalReviewStatus = options.approvalReviewStatus || "ready_for_human_approval";
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
    if [ "${includeApprovalWithPrepare ? "1" : "0"}" = "1" ]; then
      next='["repo/ops/tom-readonly/live-healthcheck-rollout-runner.sh prepare","CONFIRM_APPROVAL_RECORD=I_APPROVE_LIVE_HEALTHCHECK_RECORD APPROVED_BY=Anan repo/ops/tom-readonly/live-healthcheck-approval.sh approve runtime/live-healthcheck-approval.json"]'
    else
      next='["repo/ops/tom-readonly/live-healthcheck-rollout-runner.sh prepare"]'
    fi
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
if printf '%s\\n' "$*" | grep -q 'live-healthcheck-rollout-runner.sh status'; then
  if [ -f "${stateFile}" ]; then
    cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "waiting_human_approval",
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
    exit 0
  fi
  cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "blocked_preconditions",
  "nextCommands": [
    "repo/ops/tom-readonly/live-healthcheck-rollout-runner.sh prepare"
  ],
  "safety": {
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
if printf '%s\\n' "$*" | grep -q 'live-healthcheck-rollout-runner.sh verify-completed'; then
  cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "verified_live_healthcheck_completed",
  "issues": [],
  "nextCommands": ["repo/ops/tom-readonly/live-healthcheck-readiness.sh check"],
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
if printf '%s\\n' "$*" | grep -q 'live-healthcheck-approval-review.sh check'; then
  if [ "${approvalReviewStatus}" = "blocked_preconditions" ]; then
    cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "blocked_preconditions",
  "issues": ["dry-run inbox 仍有待处理请求：1"],
  "nextCommands": ["ops/local/final-go-live-runner.sh prepare"],
  "safety": {
    "writesApprovalFile": false,
    "opensLiveGate": false,
    "callsManagedActionsLiveApi": false,
    "writesOpenClawInstanceDirs": false
  }
}
JSON
    exit 2
  fi
  if [ "${approvalReviewStatus}" = "approved_ready_for_live_window" ]; then
    cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "approved_ready_for_live_window",
  "issues": [],
  "nextCommands": [
    "CONFIRM_FINAL_GO_LIVE_RUNNER=I_UNDERSTAND_THIS_RUNS_APPROVED_FINAL_GO_LIVE LOCAL_API_TOKEN=<本地令牌> ops/local/final-go-live-runner.sh run-approved"
  ],
  "safety": {
    "writesApprovalFile": false,
    "opensLiveGate": false,
    "callsManagedActionsLiveApi": false,
    "writesOpenClawInstanceDirs": false
  }
}
JSON
    exit 0
  fi
  cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "ready_for_human_approval",
  "issues": [],
  "nextCommands": [
    "CONFIRM_APPROVAL_RECORD=I_APPROVE_LIVE_HEALTHCHECK_RECORD APPROVED_BY=Anan repo/ops/tom-readonly/live-healthcheck-approval.sh approve runtime/live-healthcheck-approval.json"
  ],
  "safety": {
    "writesApprovalFile": false,
    "opensLiveGate": false,
    "callsManagedActionsLiveApi": false,
    "writesOpenClawInstanceDirs": false
  }
}
JSON
  exit 0
fi
if printf '%s\\n' "$*" | grep -q 'live-healthcheck-approval.sh approve'; then
  cat <<'JSON'
{
  "status": "approved",
  "file": "runtime/live-healthcheck-approval.json",
  "approvedBy": "Anan",
  "instanceId": "tom",
  "action": "healthcheck",
  "operator": "Anan",
  "risk": "low",
  "mutatesOpenClawInstance": false
}
JSON
  exit 0
fi
echo "unexpected ssh command" >&2
exit 2
`,
  );

  return { statusScript, ssh, sshCalls, discoveryConfig };
}

function runRunner(
  harness: Awaited<ReturnType<typeof writeHarness>>,
  mode: "status" | "prepare" | "run-approved" | "approve-and-run",
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

test("final go-live runner prepare 同时看到 prepare 和 approval 时仍先执行 prepare", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-final-go-live-runner-prepare-first-"));
  try {
    const harness = await writeHarness(dir, { includeApprovalWithPrepare: true });
    const { exitCode, report } = runRunner(harness, "prepare");
    const sshLog = await readFile(harness.sshCalls, "utf8");

    assert.equal(exitCode, 0);
    assert.equal(report.status, "prepared_waiting_human_approval");
    assert.equal(report.safety.writesTomRuntime, true);
    assert.equal(report.safety.opensLiveGate, false);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
    assert.match(sshLog, /live-healthcheck-rollout-runner\.sh prepare/);
    assert.doesNotMatch(sshLog, /run-approved/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("final go-live runner prepare 已在人工批准边界时幂等返回", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-final-go-live-runner-prepare-idempotent-"));
  try {
    const harness = await writeHarness(dir);
    const first = runRunner(harness, "prepare");
    const second = runRunner(harness, "prepare");
    const sshLog = await readFile(harness.sshCalls, "utf8");
    const prepareCalls = sshLog.match(/live-healthcheck-rollout-runner\.sh prepare/g) ?? [];

    assert.equal(first.exitCode, 0);
    assert.equal(second.exitCode, 0);
    assert.equal(second.report.status, "prepared_waiting_human_approval");
    assert.equal(second.report.safety.writesTomRuntime, false);
    assert.equal(second.report.safety.opensLiveGate, false);
    assert.equal(second.report.safety.callsManagedActionsLiveApi, false);
    assert.equal(second.report.safety.alreadyAtHumanApprovalBoundary, true);
    assert(second.report.nextCommands.some((command: string) => command.includes("live-healthcheck-approval.sh approve")));
    assert.equal(prepareCalls.length, 1);
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
    assert.equal(report.safety.writesTomRuntime, false);
    assert.equal(report.safety.writesControlCenterRuntimeOnly, false);
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

test("final go-live runner approve-and-run 缺确认时不连接 Tom", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-final-go-live-runner-approve-confirm-"));
  try {
    const harness = await writeHarness(dir);
    const { exitCode, report } = runRunner(harness, "approve-and-run", {
      APPROVED_BY: "Anan",
      LOCAL_API_TOKEN: "test-token",
    });

    assert.notEqual(exitCode, 0);
    assert.equal(report.status, "blocked_approve_and_run_confirmation_required");
    assert.equal(report.safety.connectsTomSsh, false);
    assert.equal(report.safety.approvesLiveHealthcheck, false);
    assert.equal(report.safety.opensLiveGate, false);
    await assert.rejects(readFile(harness.sshCalls, "utf8"));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("final go-live runner approve-and-run 在 approval review 未 ready 时不会批准", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-final-go-live-runner-review-blocked-"));
  try {
    const harness = await writeHarness(dir, { approvalReviewStatus: "blocked_preconditions" });
    const { exitCode, report } = runRunner(harness, "approve-and-run", {
      CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN: "I_APPROVE_AND_RUN_FINAL_LIVE_HEALTHCHECK",
      APPROVED_BY: "Anan",
      LOCAL_API_TOKEN: "test-token",
    });
    const sshLog = await readFile(harness.sshCalls, "utf8");

    assert.notEqual(exitCode, 0);
    assert.equal(report.status, "blocked_approval_review_not_ready");
    assert.equal(report.safety.approvesLiveHealthcheck, false);
    assert.equal(report.safety.opensLiveGate, false);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
    assert.match(sshLog, /live-healthcheck-approval-review\.sh check/);
    assert.doesNotMatch(sshLog, /live-healthcheck-approval\.sh approve/);
    assert.doesNotMatch(sshLog, /live-healthcheck-rollout-runner\.sh run-approved/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("final go-live runner approve-and-run 批准后执行一次性 live healthcheck", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-final-go-live-runner-approve-run-"));
  try {
    const harness = await writeHarness(dir, { tomRunStatus: "completed_live_healthcheck" });
    const { exitCode, report } = runRunner(harness, "approve-and-run", {
      CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN: "I_APPROVE_AND_RUN_FINAL_LIVE_HEALTHCHECK",
      APPROVED_BY: "Anan",
      LOCAL_API_TOKEN: "test-token",
    });
    const sshLog = await readFile(harness.sshCalls, "utf8");
    const reviewIndex = sshLog.indexOf("live-healthcheck-approval-review.sh check");
    const approvalIndex = sshLog.indexOf("live-healthcheck-approval.sh approve");
    const runIndex = sshLog.indexOf("live-healthcheck-rollout-runner.sh run-approved");
    const verifyIndex = sshLog.indexOf("live-healthcheck-rollout-runner.sh verify-completed");

    assert.equal(exitCode, 0);
    assert.equal(report.status, "completed_final_live_healthcheck");
    assert.equal(report.safety.approvesLiveHealthcheck, true);
    assert.equal(report.safety.opensLiveGate, true);
    assert.equal(report.safety.callsManagedActionsLiveApi, true);
    assert.equal(report.safety.writesOpenClawInstanceDirs, false);
    assert(reviewIndex >= 0);
    assert(approvalIndex > reviewIndex);
    assert(runIndex > approvalIndex);
    assert(verifyIndex > runIndex);
    assert.doesNotMatch(JSON.stringify(report), /test-token/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("final go-live runner verify-completed 只读代理 Tom 演练后验收", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-final-go-live-runner-verify-"));
  try {
    const harness = await writeHarness(dir);
    const { exitCode, report } = runRunner(harness, "verify-completed");
    const sshLog = await readFile(harness.sshCalls, "utf8");

    assert.equal(exitCode, 0);
    assert.equal(report.status, "verified_final_live_healthcheck_completed");
    assert.equal(report.safety.opensLiveGate, false);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
    assert.equal(report.safety.writesTomRuntime, false);
    assert.match(sshLog, /live-healthcheck-rollout-runner\.sh verify-completed/);
    assert.doesNotMatch(sshLog, /live-healthcheck-rollout-runner\.sh run-approved/);
    assert.doesNotMatch(sshLog, /live-healthcheck-approval\.sh approve/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
