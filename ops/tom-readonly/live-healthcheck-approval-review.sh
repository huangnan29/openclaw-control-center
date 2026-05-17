#!/usr/bin/env bash
set -euo pipefail
set +x

# live healthcheck 人工批准前只读审查汇总。
# 本脚本只读取 readiness、approval packet、dry-run inbox cron 和 inbox 状态；
# 不生成证据包、不批准 approval、不打开 live gate、不调用 managed-actions live API。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
OPENCLAW_TOPOLOGY_MODE="${OPENCLAW_TOPOLOGY_MODE:-local-only}"
INSTANCE_ID="${INSTANCE_ID:-tom}"
OPERATOR="${OPERATOR:-Anan}"
MANAGED_ACTION_INBOX_DIR="${MANAGED_ACTION_INBOX_DIR:-/instances/tom/workspace/control-center-commands/inbox}"
MODE_NAME="${1:-status}"

usage() {
  cat <<'TEXT'
用法：
  live-healthcheck-approval-review.sh status
  live-healthcheck-approval-review.sh check

说明：
  status 只读取 approval readiness、dry-run inbox cron 与 inbox 状态。
  check 会让 readiness 执行只读 healthcheck，用于确认 Tom 现有实例仍正常。
  本脚本不生成证据包、不批准 approval、不打开 live gate、不调用 managed-actions live API。
TEXT
}

case "$MODE_NAME" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

MODE_NAME="$MODE_NAME" \
  DEPLOY_DIR="$DEPLOY_DIR" \
  SCRIPT_DIR="$SCRIPT_DIR" \
  OPENCLAW_TOPOLOGY_MODE="$OPENCLAW_TOPOLOGY_MODE" \
  INSTANCE_ID="$INSTANCE_ID" \
  OPERATOR="$OPERATOR" \
  MANAGED_ACTION_INBOX_DIR="$MANAGED_ACTION_INBOX_DIR" \
  node <<'NODE'
const { spawnSync } = require("node:child_process");
const path = require("node:path");

const mode = process.env.MODE_NAME || "status";
const deployDir = path.resolve(process.env.DEPLOY_DIR || "/srv/openclaw-control-center-readonly");
const scriptDir = path.resolve(process.env.SCRIPT_DIR || path.join(deployDir, "repo", "ops", "tom-readonly"));
const topologyMode = process.env.OPENCLAW_TOPOLOGY_MODE || "local-only";
const instanceId = process.env.INSTANCE_ID || "tom";
const operator = process.env.OPERATOR || "Anan";
const inboxDir = process.env.MANAGED_ACTION_INBOX_DIR || "/instances/tom/workspace/control-center-commands/inbox";

const scripts = {
  readiness: process.env.APPROVAL_REVIEW_READINESS_SCRIPT || path.join(scriptDir, "live-healthcheck-readiness.sh"),
  inboxCron: process.env.APPROVAL_REVIEW_INBOX_CRON_SCRIPT || path.join(scriptDir, "install-managed-action-inbox-cron.sh"),
  inboxRunner: process.env.APPROVAL_REVIEW_INBOX_RUNNER_SCRIPT || path.join(scriptDir, "managed-action-inbox-runner.sh"),
};

function compactLines(text, limit = 80) {
  return String(text || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, limit);
}

function parseJson(text, label) {
  try {
    return JSON.parse(text);
  } catch (error) {
    return {
      status: "invalid_output",
      label,
      error: error instanceof Error ? error.message : String(error),
      rawLines: compactLines(text, 40),
    };
  }
}

function run(command, args, extraEnv = {}) {
  const result = spawnSync(command, args, {
    cwd: deployDir,
    env: {
      ...process.env,
      DEPLOY_DIR: deployDir,
      SCRIPT_DIR: scriptDir,
      OPENCLAW_TOPOLOGY_MODE: topologyMode,
      INSTANCE_ID: instanceId,
      OPERATOR: operator,
      ...extraEnv,
    },
    encoding: "utf8",
    maxBuffer: 24 * 1024 * 1024,
    timeout: 180_000,
  });
  return {
    command: [command, ...args].join(" "),
    exitCode: typeof result.status === "number" ? result.status : 1,
    stdout: result.stdout || "",
    stderr: result.stderr || "",
    error: result.error ? (result.error instanceof Error ? result.error.message : String(result.error)) : undefined,
  };
}

function stage(result, label) {
  return {
    exitCode: result.exitCode,
    report: parseJson(result.stdout, label),
    stderrLines: compactLines(result.stderr, 40),
  };
}

function approvalStatus(readiness) {
  return readiness.stages?.approval?.report?.status || "unknown";
}

function packetStatus(readiness) {
  return readiness.stages?.approvalPacket?.report?.status || "unknown";
}

function latestDryRun(readiness) {
  return readiness.stages?.dryRun?.report?.readiness?.dryRun?.latest
    || readiness.stages?.dryRun?.report?.audit?.latest
    || undefined;
}

function collectIssues(readiness, inboxCron, inbox) {
  const issues = [];
  if (readiness.status !== "waiting_human_approval" && readiness.status !== "approved_ready_for_live_window") {
    issues.push(`readiness 未到批准边界：${readiness.status || "unknown"}`);
  }
  if (packetStatus(readiness) !== "ready") {
    issues.push(`approval packet 未 ready：${packetStatus(readiness)}`);
  }
  const approval = approvalStatus(readiness);
  if (!["needs_manual_approval", "approved"].includes(approval)) {
    issues.push(`approval 状态异常：${approval}`);
  }
  if (inboxCron.status !== "inbox_cron_installed" || inboxCron.needsUpdate === true) {
    issues.push(`dry-run inbox cron 未就绪：${inboxCron.status || "unknown"}`);
  }
  if (Number(inbox.pendingCount || 0) > 0) {
    issues.push(`dry-run inbox 仍有待处理请求：${inbox.pendingCount}`);
  }
  const safety = readiness.safety || {};
  if (safety.opensLiveGate !== false) issues.push("readiness safety.opensLiveGate 不是 false");
  if (safety.callsManagedActionsLiveApi !== false) issues.push("readiness safety.callsManagedActionsLiveApi 不是 false");
  if (safety.writesOpenClawInstanceDirs !== false) issues.push("readiness safety.writesOpenClawInstanceDirs 不是 false");
  if (safety.restartsOpenClawInstances !== false) issues.push("readiness safety.restartsOpenClawInstances 不是 false");
  return issues;
}

function decideStatus(readiness, issues) {
  if (issues.length > 0) return "blocked_preconditions";
  if (readiness.status === "approved_ready_for_live_window") return "approved_ready_for_live_window";
  return "ready_for_human_approval";
}

function nextCommands(status) {
  if (status === "ready_for_human_approval") {
    return [
      "CONFIRM_APPROVAL_RECORD=I_APPROVE_LIVE_HEALTHCHECK_RECORD APPROVED_BY=Anan repo/ops/tom-readonly/live-healthcheck-approval.sh approve runtime/live-healthcheck-approval.json",
    ];
  }
  if (status === "approved_ready_for_live_window") {
    return [
      "CONFIRM_FINAL_GO_LIVE_RUNNER=I_UNDERSTAND_THIS_RUNS_APPROVED_FINAL_GO_LIVE LOCAL_API_TOKEN=<本地令牌> ops/local/final-go-live-runner.sh run-approved",
      "CONFIRM_LIVE_HEALTHCHECK_RUNNER=I_UNDERSTAND_THIS_RUNS_APPROVED_LIVE_HEALTHCHECK LOCAL_API_TOKEN=<本地令牌> repo/ops/tom-readonly/live-healthcheck-rollout-runner.sh run-approved",
    ];
  }
  return [
    "ops/local/final-go-live-runner.sh prepare",
    "repo/ops/tom-readonly/live-healthcheck-rollout-runner.sh prepare",
  ];
}

if (!["status", "check"].includes(mode)) {
  console.log(JSON.stringify({
    schemaVersion: 1,
    status: "blocked_invalid_mode",
    mode,
    issues: [`未知模式：${mode}。支持 status、check。`],
    safety: {
      readsStatusOnly: true,
      checkRunsHealthcheckOnly: false,
      generatesApprovalPacket: false,
      writesApprovalFile: false,
      opensLiveGate: false,
      callsManagedActionsLiveApi: false,
      writesOpenClawInstanceDirs: false,
      restartsOpenClawInstances: false,
    },
  }, null, 2));
  process.exit(2);
}

const readinessResult = run(scripts.readiness, [mode === "check" ? "check" : "status"]);
const inboxCronResult = run(scripts.inboxCron, ["status"]);
const inboxResult = run(scripts.inboxRunner, ["status"], {
  MANAGED_ACTION_INBOX_SOURCE: "control-center-container",
  MANAGED_ACTION_INBOX_DIR: inboxDir,
});

const readiness = parseJson(readinessResult.stdout, "live healthcheck readiness");
const inboxCron = parseJson(inboxCronResult.stdout, "managed action inbox cron");
const inbox = parseJson(inboxResult.stdout, "managed action inbox runner");
const issues = collectIssues(readiness, inboxCron, inbox);
const status = decideStatus(readiness, issues);

const reviewItems = [
  {
    id: "readiness",
    ok: readiness.status === "waiting_human_approval" || readiness.status === "approved_ready_for_live_window",
    status: readiness.status || "unknown",
  },
  {
    id: "approval_packet",
    ok: packetStatus(readiness) === "ready",
    status: packetStatus(readiness),
  },
  {
    id: "approval",
    ok: ["needs_manual_approval", "approved"].includes(approvalStatus(readiness)),
    status: approvalStatus(readiness),
  },
  {
    id: "dry_run_inbox_cron",
    ok: inboxCron.status === "inbox_cron_installed" && inboxCron.needsUpdate === false,
    status: inboxCron.status || "unknown",
    needsUpdate: inboxCron.needsUpdate,
  },
  {
    id: "dry_run_inbox",
    ok: Number(inbox.pendingCount || 0) === 0,
    pendingCount: Number(inbox.pendingCount || 0),
  },
];

console.log(JSON.stringify({
  schemaVersion: 1,
  status,
  mode,
  topologyMode,
  generatedAt: new Date().toISOString(),
  target: { instanceId, action: "healthcheck", operator },
  summary: {
    readiness: readiness.status || "unknown",
    approvalPacket: packetStatus(readiness),
    approval: approvalStatus(readiness),
    inboxCron: inboxCron.status || "unknown",
    inboxPendingCount: Number(inbox.pendingCount || 0),
    latestDryRun: latestDryRun(readiness),
  },
  reviewItems,
  stages: {
    readiness: stage(readinessResult, "live healthcheck readiness"),
    inboxCron: stage(inboxCronResult, "managed action inbox cron"),
    inbox: stage(inboxResult, "managed action inbox runner"),
  },
  issues,
  nextCommands: nextCommands(status),
  safety: {
    readsStatusOnly: true,
    checkRunsHealthcheckOnly: mode === "check",
    generatesApprovalPacket: false,
    writesApprovalFile: false,
    opensLiveGate: false,
    callsManagedActionsLiveApi: false,
    writesOpenClawInstanceDirs: false,
    restartsOpenClawInstances: false,
  },
}, null, 2));

if (status === "blocked_preconditions") process.exit(2);
NODE
