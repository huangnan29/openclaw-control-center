#!/usr/bin/env bash
set -euo pipefail
set +x

# live healthcheck 演练只读 readiness 汇总。
# 本脚本只读取各闸门状态，不生成证据包、不写 approval、不打开 live gate、不调用 live API。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
BUNDLE_DIR="${BUNDLE_DIR:-${DEPLOY_DIR}/runtime/remote-onboarding/remote-oracle}"
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
  live-healthcheck-readiness.sh status
  live-healthcheck-readiness.sh check

说明：
  status 只读取总闸门 status、dry-run 证据、approval、批准前证据包和 live window 状态。
  check 会让总闸门执行只读 healthcheck，用于确认 Tom 现有实例仍正常。
  本脚本不生成新证据包、不写 approval、不打开 live gate、不调用 managed-actions live API。
TEXT
}

run_node() {
  local mode="$1"
  MODE="$mode" \
    DEPLOY_DIR="$DEPLOY_DIR" \
    BUNDLE_DIR="$BUNDLE_DIR" \
    SCRIPT_DIR="$SCRIPT_DIR" \
    OPENCLAW_TOPOLOGY_MODE="$OPENCLAW_TOPOLOGY_MODE" \
    INSTANCE_ID="$INSTANCE_ID" \
    OPERATOR="$OPERATOR" \
    node <<'NODE'
const { spawnSync } = require("node:child_process");
const path = require("node:path");

const mode = process.env.MODE || "status";
const deployDir = path.resolve(process.env.DEPLOY_DIR || "/srv/openclaw-control-center-readonly");
const bundleDir = path.resolve(process.env.BUNDLE_DIR || path.join(deployDir, "runtime", "remote-onboarding", "remote-oracle"));
const scriptDir = path.resolve(process.env.SCRIPT_DIR || path.join(deployDir, "repo", "ops", "tom-readonly"));
const topologyMode = process.env.OPENCLAW_TOPOLOGY_MODE || "local-only";
const instanceId = process.env.INSTANCE_ID || "tom";
const operator = process.env.OPERATOR || "Anan";

const scripts = {
  goLiveGate: process.env.LIVE_HEALTHCHECK_READINESS_GO_LIVE_GATE_SCRIPT || path.join(scriptDir, "go-live-gate.sh"),
  dryRunGate: process.env.LIVE_HEALTHCHECK_READINESS_DRY_RUN_GATE_SCRIPT || path.join(scriptDir, "managed-action-dry-run-gate.sh"),
  approvalPacket: process.env.LIVE_HEALTHCHECK_READINESS_APPROVAL_PACKET_SCRIPT || path.join(scriptDir, "live-healthcheck-approval-packet.sh"),
  approval: process.env.LIVE_HEALTHCHECK_READINESS_APPROVAL_SCRIPT || path.join(scriptDir, "live-healthcheck-approval.sh"),
  liveWindow: process.env.LIVE_HEALTHCHECK_READINESS_WINDOW_SCRIPT || path.join(scriptDir, "live-healthcheck-window.sh"),
};

function run(command, args, extraEnv = {}) {
  const result = spawnSync(command, args, {
    cwd: deployDir,
    env: {
      ...process.env,
      DEPLOY_DIR: deployDir,
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

function extractJsonObjects(text) {
  const objects = [];
  let depth = 0;
  let start = -1;
  let inString = false;
  let escaped = false;
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (char === "\\") {
        escaped = true;
      } else if (char === "\"") {
        inString = false;
      }
      continue;
    }
    if (char === "\"") {
      inString = true;
      continue;
    }
    if (char === "{") {
      if (depth === 0) start = index;
      depth += 1;
      continue;
    }
    if (char === "}") {
      depth -= 1;
      if (depth === 0 && start >= 0) {
        try {
          objects.push(JSON.parse(text.slice(start, index + 1)));
        } catch {
          // 忽略日志中的非 JSON 花括号片段。
        }
        start = -1;
      }
    }
  }
  return objects;
}

function compactLines(text, limit = 60) {
  return String(text || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, limit);
}

function firstMatch(text, pattern) {
  const match = String(text || "").match(pattern);
  return match ? match[1] : undefined;
}

function formatError(error) {
  return error instanceof Error ? error.message : String(error);
}

function readLiveWindow(result) {
  const combined = `${result.stdout}\n${result.stderr}`;
  const approval = extractJsonObjects(combined).find((item) => item && typeof item === "object" && "approved" in item && "consumed" in item);
  return {
    status: result.exitCode === 0 ? "read" : "script_failed",
    exitCode: result.exitCode,
    approvalStatus: approval?.status || "unknown",
    readonlyMode: firstMatch(combined, /READONLY_MODE=([^\s]+)/) || "unknown",
    liveEnabled: firstMatch(combined, /MANAGED_ACTIONS_LIVE_ENABLED=([^\s]+)/) || "unknown",
    executorEnabled: firstMatch(combined, /MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED=([^\s]+)/) || "unknown",
    readinessStatus: firstMatch(combined, /readiness\.status=([^\s]+)/) || "unknown",
    liveExecutionAvailable: firstMatch(combined, /readiness\.liveExecutionAvailable=([^\s]+)/) || "unknown",
    executorProductionWired: firstMatch(combined, /readiness\.executor\.productionWired=([^\s]+)/) || "unknown",
    rawLines: compactLines(combined),
  };
}

function stageFromResult(result, label) {
  const parsed = parseJson(result.stdout, label);
  return {
    exitCode: result.exitCode,
    report: parsed,
    stderrLines: compactLines(result.stderr, 40),
  };
}

function collectIssues(stages) {
  const issues = [];
  const goLiveStatus = stages.goLive.report?.status || "unknown";
  if (!["ready_for_existing_instance_healthcheck", "blocked_managed_actions", "ready_for_live_healthcheck"].includes(goLiveStatus)) {
    issues.push(`总闸门未到管理动作阶段：${goLiveStatus}`);
  }
  if (stages.dryRun.report?.status !== "ready") {
    issues.push(`dry-run 证据未 ready：${stages.dryRun.report?.status || "unknown"}`);
  }
  if (stages.approvalPacket.report?.status !== "ready") {
    const packetIssues = Array.isArray(stages.approvalPacket.report?.issues) ? stages.approvalPacket.report.issues : [];
    issues.push(`批准前证据包未 ready：${stages.approvalPacket.report?.status || "unknown"}`);
    issues.push(...packetIssues.map((item) => `批准前证据包：${item}`));
  }
  if (stages.liveWindow.readonlyMode !== "true") {
    issues.push(`live window 当前不在只读态：READONLY_MODE=${stages.liveWindow.readonlyMode}`);
  }
  if (stages.liveWindow.liveEnabled === "true" || stages.liveWindow.executorEnabled === "true") {
    issues.push("live gate 或 executor 已开启，人工批准前应保持关闭");
  }
  return issues;
}

function decide(stages, issues) {
  if (issues.length > 0) return "blocked_preconditions";
  const approvalStatus = stages.approval.report?.status || "unknown";
  if (approvalStatus === "needs_manual_approval" || approvalStatus === "missing") return "waiting_human_approval";
  if (approvalStatus === "approved") return "approved_ready_for_live_window";
  if (approvalStatus === "consumed") return "approval_consumed";
  return "blocked_approval";
}

function nextCommands(status) {
  if (status === "blocked_preconditions") {
    return [
      "repo/ops/tom-readonly/managed-action-dry-run-gate.sh status",
      "repo/ops/tom-readonly/live-healthcheck-approval-packet.sh generate",
      "repo/ops/tom-readonly/live-healthcheck-approval-packet.sh check",
    ];
  }
  if (status === "waiting_human_approval") {
    return [
      "CONFIRM_APPROVAL_RECORD=I_APPROVE_LIVE_HEALTHCHECK_RECORD APPROVED_BY=Anan repo/ops/tom-readonly/live-healthcheck-approval.sh approve runtime/live-healthcheck-approval.json",
    ];
  }
  if (status === "approved_ready_for_live_window") {
    return [
      "CONFIRM_LIVE_HEALTHCHECK_WINDOW=I_UNDERSTAND_THIS_TEMPORARILY_ENABLES_LIVE_GATE CONFIRM_LIVE_HEALTHCHECK=I_UNDERSTAND_THIS_CALLS_LIVE_API LOCAL_API_TOKEN=<本地令牌> INSTANCE_ID=tom OPERATOR=Anan repo/ops/tom-readonly/live-healthcheck-window.sh run",
    ];
  }
  if (status === "approval_consumed") {
    return [
      "repo/ops/tom-readonly/live-healthcheck-approval.sh prepare runtime/live-healthcheck-approval.json",
    ];
  }
  return [
    "repo/ops/tom-readonly/live-healthcheck-approval.sh status runtime/live-healthcheck-approval.json",
  ];
}

const goLiveResult = run(scripts.goLiveGate, [mode === "check" ? "check" : "status", bundleDir]);
const dryRunResult = run(scripts.dryRunGate, ["status"]);
const approvalPacketResult = run(scripts.approvalPacket, ["check"]);
const approvalResult = run(scripts.approval, ["status", path.join(deployDir, "runtime", "live-healthcheck-approval.json")]);
const liveWindowResult = run(scripts.liveWindow, ["status"]);

const stages = {
  goLive: stageFromResult(goLiveResult, "go-live gate"),
  dryRun: stageFromResult(dryRunResult, "managed action dry-run gate"),
  approvalPacket: stageFromResult(approvalPacketResult, "approval packet"),
  approval: stageFromResult(approvalResult, "approval"),
  liveWindow: readLiveWindow(liveWindowResult),
};

const issues = collectIssues(stages);
if (stages.approval.report?.status && !["needs_manual_approval", "missing", "approved", "consumed"].includes(stages.approval.report.status)) {
  issues.push(`approval 状态异常：${stages.approval.report.status}`);
}
const status = decide(stages, issues);

console.log(JSON.stringify({
  schemaVersion: 1,
  status,
  mode,
  topologyMode,
  generatedAt: new Date().toISOString(),
  target: { instanceId, action: "healthcheck", operator },
  stages,
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
NODE
}

main() {
  require_command node
  case "${1:-status}" in
    status)
      run_node "status"
      ;;
    check)
      run_node "check"
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
