#!/usr/bin/env bash
set -euo pipefail
set +x

# live healthcheck 演练预备 runner。
# status 只读取 readiness；prepare 只准备 approval 模板、生成/校验证据包并刷新 readiness。
# 本脚本不会批准 approval，不会打开 live gate，不会调用 managed-actions live API。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
OPENCLAW_TOPOLOGY_MODE="${OPENCLAW_TOPOLOGY_MODE:-local-only}"
INSTANCE_ID="${INSTANCE_ID:-tom}"
OPERATOR="${OPERATOR:-Anan}"

fail() {
  printf '[失败] %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"
}

usage() {
  cat <<'TEXT'
用法：
  live-healthcheck-rollout-runner.sh status
  live-healthcheck-rollout-runner.sh prepare

说明：
  status 只调用 live-healthcheck-readiness.sh status，不写文件。
  prepare 会自动执行到人工批准前：
    1. 检查 managed-action dry-run 证据。
    2. 准备 approval 模板，已存在则不覆盖。
    3. 生成并校验批准前证据包。
    4. 运行 live-healthcheck-readiness.sh check 汇总下一步。

安全边界：
  - 不批准 approval。
  - 不打开 live gate。
  - 不调用 managed-actions live API。
  - 不修改任何 OpenClaw 实例目录。
TEXT
}

run_node() {
  local mode="$1"
  MODE="$mode" \
    DEPLOY_DIR="$DEPLOY_DIR" \
    SCRIPT_DIR="$SCRIPT_DIR" \
    OPENCLAW_TOPOLOGY_MODE="$OPENCLAW_TOPOLOGY_MODE" \
    INSTANCE_ID="$INSTANCE_ID" \
    OPERATOR="$OPERATOR" \
    node <<'NODE'
const { spawnSync } = require("node:child_process");
const path = require("node:path");

const mode = process.env.MODE || "status";
const deployDir = path.resolve(process.env.DEPLOY_DIR || "/srv/openclaw-control-center-readonly");
const scriptDir = path.resolve(process.env.SCRIPT_DIR || path.join(deployDir, "repo", "ops", "tom-readonly"));
const topologyMode = process.env.OPENCLAW_TOPOLOGY_MODE || "local-only";
const instanceId = process.env.INSTANCE_ID || "tom";
const operator = process.env.OPERATOR || "Anan";
const approvalFile = path.join(deployDir, "runtime", "live-healthcheck-approval.json");

const scripts = {
  readiness: process.env.LIVE_HEALTHCHECK_RUNNER_READINESS_SCRIPT || path.join(scriptDir, "live-healthcheck-readiness.sh"),
  dryRunGate: process.env.LIVE_HEALTHCHECK_RUNNER_DRY_RUN_GATE_SCRIPT || path.join(scriptDir, "managed-action-dry-run-gate.sh"),
  approval: process.env.LIVE_HEALTHCHECK_RUNNER_APPROVAL_SCRIPT || path.join(scriptDir, "live-healthcheck-approval.sh"),
  approvalPacket: process.env.LIVE_HEALTHCHECK_RUNNER_APPROVAL_PACKET_SCRIPT || path.join(scriptDir, "live-healthcheck-approval-packet.sh"),
};

function run(command, args) {
  const result = spawnSync(command, args, {
    cwd: deployDir,
    env: {
      ...process.env,
      DEPLOY_DIR: deployDir,
      OPENCLAW_TOPOLOGY_MODE: topologyMode,
      INSTANCE_ID: instanceId,
      OPERATOR: operator,
    },
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
    timeout: 240_000,
  });
  return {
    command: [command, ...args].join(" "),
    exitCode: typeof result.status === "number" ? result.status : 1,
    stdout: result.stdout || "",
    stderr: result.stderr || "",
    error: result.error ? formatError(result.error) : undefined,
  };
}

function parseJson(text, label) {
  try {
    return JSON.parse(text);
  } catch (error) {
    return {
      status: "invalid_output",
      label,
      error: formatError(error),
      raw: String(text || "").slice(0, 4000),
    };
  }
}

function compactLines(text, limit = 80) {
  return String(text || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, limit);
}

function lastNonEmptyLine(text) {
  return compactLines(text, 200).at(-1) || "";
}

function stage(result, label) {
  return {
    exitCode: result.exitCode,
    report: parseJson(result.stdout, label),
    stdoutLines: compactLines(result.stdout, 40),
    stderrLines: compactLines(result.stderr, 40),
  };
}

function formatError(error) {
  return error instanceof Error ? error.message : String(error);
}

function safety(extra = {}) {
  return {
    writesControlCenterRuntimeOnly: mode === "prepare",
    writesApprovalTemplateOnly: mode === "prepare",
    generatesApprovalPacket: mode === "prepare",
    approvesLiveHealthcheck: false,
    opensLiveGate: false,
    callsManagedActionsLiveApi: false,
    writesOpenClawInstanceDirs: false,
    restartsOpenClawInstances: false,
    ...extra,
  };
}

function statusOnly() {
  const readinessResult = run(scripts.readiness, ["status"]);
  const readiness = stage(readinessResult, "live healthcheck readiness");
  const readinessStatus = readiness.report?.status || "unknown";
  return {
    schemaVersion: 1,
    status: readinessStatus,
    mode,
    generatedAt: new Date().toISOString(),
    target: { instanceId, action: "healthcheck", operator },
    stages: { readiness },
    nextCommands: Array.isArray(readiness.report?.nextCommands) ? readiness.report.nextCommands : [],
    safety: safety({
      writesControlCenterRuntimeOnly: false,
      writesApprovalTemplateOnly: false,
      generatesApprovalPacket: false,
      readsStatusOnly: true,
    }),
  };
}

function prepare() {
  const dryRunResult = run(scripts.dryRunGate, ["status"]);
  const dryRun = stage(dryRunResult, "managed action dry-run gate");
  const dryRunStatus = dryRun.report?.status || "unknown";
  if (dryRunResult.exitCode !== 0 || dryRunStatus !== "ready") {
    return {
      schemaVersion: 1,
      status: "blocked_dry_run",
      mode,
      generatedAt: new Date().toISOString(),
      target: { instanceId, action: "healthcheck", operator },
      stages: { dryRun },
      issues: [`dry-run 证据未 ready：${dryRunStatus}`],
      nextCommands: Array.isArray(dryRun.report?.nextCommands) && dryRun.report.nextCommands.length > 0
        ? dryRun.report.nextCommands
        : ["CONFIRM_MANAGED_ACTION_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CREATES_DRY_RUN_AUDIT_RECORD LOCAL_API_TOKEN=<本地令牌> repo/ops/tom-readonly/managed-action-dry-run-gate.sh run"],
      safety: safety(),
    };
  }

  const approvalPrepareResult = run(scripts.approval, ["prepare", approvalFile]);
  const approvalPrepare = stage(approvalPrepareResult, "approval prepare");
  const packetGenerateResult = run(scripts.approvalPacket, ["generate"]);
  const packetFile = lastNonEmptyLine(packetGenerateResult.stdout);
  const packetGenerate = {
    exitCode: packetGenerateResult.exitCode,
    packetFile,
    stdoutLines: compactLines(packetGenerateResult.stdout, 40),
    stderrLines: compactLines(packetGenerateResult.stderr, 60),
  };
  const packetCheckResult = packetFile
    ? run(scripts.approvalPacket, ["check", packetFile])
    : {
      command: `${scripts.approvalPacket} check <missing-packet>`,
      exitCode: 2,
      stdout: JSON.stringify({ status: "blocked", issues: ["packet file missing after generate"] }),
      stderr: "",
    };
  const packetCheck = stage(packetCheckResult, "approval packet check");
  const readinessResult = run(scripts.readiness, ["check"]);
  const readiness = stage(readinessResult, "live healthcheck readiness");
  const readinessStatus = readiness.report?.status || "unknown";
  const normalizedStatus = readinessStatus === "waiting_human_approval"
    ? "prepared_waiting_human_approval"
    : readinessStatus === "approved_ready_for_live_window"
      ? "prepared_approved_ready_for_live_window"
      : `prepared_${readinessStatus}`;

  return {
    schemaVersion: 1,
    status: normalizedStatus,
    mode,
    generatedAt: new Date().toISOString(),
    target: { instanceId, action: "healthcheck", operator },
    stages: {
      dryRun,
      approvalPrepare,
      packetGenerate,
      packetCheck,
      readiness,
    },
    issues: Array.isArray(readiness.report?.issues) ? readiness.report.issues : [],
    nextCommands: Array.isArray(readiness.report?.nextCommands) ? readiness.report.nextCommands : [],
    safety: safety({
      readsStatusOnly: false,
      checkRunsHealthcheckOnly: true,
    }),
  };
}

if (mode === "status") {
  console.log(JSON.stringify(statusOnly(), null, 2));
} else if (mode === "prepare") {
  console.log(JSON.stringify(prepare(), null, 2));
} else {
  console.error(`[失败] 未知模式：${mode}`);
  process.exit(2);
}
NODE
}

main() {
  require_command node
  case "${1:-status}" in
    status)
      run_node "status"
      ;;
    prepare)
      run_node "prepare"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage
      fail "未知命令：${1:-}"
      ;;
  esac
}

main "$@"
