#!/usr/bin/env bash
set -euo pipefail
set +x

# 管理动作 dry-run 证据闸门。
# status 只读取 readiness 与 dry-run audit；run 只创建 dry-run 审计记录。
# 本脚本不调用 managed-actions live API，不修改任何 OpenClaw 实例目录。

BASE_URL="${BASE_URL:-http://127.0.0.1:4311}"
INSTANCE_ID="${INSTANCE_ID:-tom}"
ACTION="${ACTION:-healthcheck}"
OPERATOR="${OPERATOR:-Anan}"
REASON="${REASON:-Tom managed action dry-run evidence}"
MAX_AGE_SECONDS="${MAX_AGE_SECONDS:-86400}"
LOCAL_API_TOKEN="${LOCAL_API_TOKEN:-}"
CONFIRM_MANAGED_ACTION_DRY_RUN="${CONFIRM_MANAGED_ACTION_DRY_RUN:-}"

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
  managed-action-dry-run-gate.sh status
  managed-action-dry-run-gate.sh run

说明：
  status 只读取 /api/managed-actions/readiness 和 /api/managed-actions/audit，不写文件。
  run 只调用 /api/managed-actions/dry-run 创建 dry-run 审计记录，不调用 live API。

安全确认：
  run 必须设置：
    CONFIRM_MANAGED_ACTION_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CREATES_DRY_RUN_AUDIT_RECORD
    LOCAL_API_TOKEN=<本地令牌>
TEXT
}

run_node() {
  local mode="$1"
  MODE="$mode" \
    BASE_URL="$BASE_URL" \
    INSTANCE_ID="$INSTANCE_ID" \
    ACTION="$ACTION" \
    OPERATOR="$OPERATOR" \
    REASON="$REASON" \
    MAX_AGE_SECONDS="$MAX_AGE_SECONDS" \
    LOCAL_API_TOKEN="$LOCAL_API_TOKEN" \
    CONFIRM_MANAGED_ACTION_DRY_RUN="$CONFIRM_MANAGED_ACTION_DRY_RUN" \
    node <<'NODE'
const { spawnSync } = require("node:child_process");

const mode = process.env.MODE || "status";
const baseUrl = (process.env.BASE_URL || "http://127.0.0.1:4311").replace(/\/$/, "");
const instanceId = process.env.INSTANCE_ID || "tom";
const action = process.env.ACTION || "healthcheck";
const operator = process.env.OPERATOR || "Anan";
const reason = process.env.REASON || "Tom managed action dry-run evidence";
const maxAgeSeconds = Number.parseInt(process.env.MAX_AGE_SECONDS || "86400", 10);
const localApiToken = process.env.LOCAL_API_TOKEN || "";
const confirm = process.env.CONFIRM_MANAGED_ACTION_DRY_RUN || "";

function fail(message) {
  console.error(`[失败] ${message}`);
  process.exit(2);
}

function curlJson(args, input) {
  const result = spawnSync("curl", ["-fsS", ...args], {
    input,
    encoding: "utf8",
    maxBuffer: 5 * 1024 * 1024,
  });
  if (result.status !== 0) {
    throw new Error((result.stderr || result.stdout || `curl exit=${result.status}`).trim());
  }
  try {
    return JSON.parse(result.stdout);
  } catch (error) {
    throw new Error(`响应不是 JSON：${formatError(error)}`);
  }
}

function getJson(path) {
  return curlJson([`${baseUrl}${path}`]);
}

function postJson(path, payload) {
  const headers = ["-H", "content-type: application/json"];
  if (localApiToken) headers.push("-H", `x-local-token: ${localApiToken}`);
  return curlJson([...headers, "--data", JSON.stringify(payload), `${baseUrl}${path}`]);
}

function statusFrom(audit, readiness) {
  const latest = Array.isArray(audit.records) ? audit.records[0] : undefined;
  const issues = [];
  if (!latest) {
    issues.push("没有匹配的 managed action dry-run 审计记录");
  } else {
    if (latest.action !== action) issues.push(`action 不匹配：${latest.action}`);
    if (latest.targetInstanceId !== instanceId) issues.push(`instanceId 不匹配：${latest.targetInstanceId}`);
    if (latest.operator !== operator) issues.push(`operator 不匹配：${latest.operator}`);
    if (latest.confirmationTextMatched !== true) issues.push("dry-run 确认短语未通过");
    if (latest.mutatesOpenClawInstance !== false) issues.push("dry-run 不应修改 OpenClaw 实例");
    const ageSeconds = Math.max(0, Math.round((Date.now() - Date.parse(String(latest.timestamp || ""))) / 1000));
    if (!Number.isFinite(ageSeconds)) issues.push("dry-run timestamp 不可解析");
    if (Number.isFinite(ageSeconds) && ageSeconds > maxAgeSeconds) {
      issues.push(`dry-run 已过期：age=${ageSeconds}s max=${maxAgeSeconds}s`);
    }
  }
  return {
    status: issues.length === 0 ? "ready" : "blocked",
    issues,
    latest,
    readinessDryRun: readiness?.dryRun,
  };
}

function buildStatus(runResult) {
  const readiness = getJson("/api/managed-actions/readiness");
  const audit = getJson(`/api/managed-actions/audit?limit=1&instanceId=${encodeURIComponent(instanceId)}&operator=${encodeURIComponent(operator)}&action=${encodeURIComponent(action)}`);
  const evaluated = statusFrom(audit, readiness);
  return {
    schemaVersion: 1,
    status: evaluated.status,
    mode,
    generatedAt: new Date().toISOString(),
    target: { instanceId, action, operator },
    runResult,
    audit: {
      path: audit.path,
      count: audit.count,
      latest: evaluated.latest,
    },
    readiness: {
      status: readiness.status,
      liveExecutionAvailable: readiness.liveExecutionAvailable,
      dryRun: evaluated.readinessDryRun,
    },
    issues: evaluated.issues,
    nextCommands: evaluated.status === "ready" ? [
      "repo/ops/tom-readonly/live-healthcheck-approval.sh prepare runtime/live-healthcheck-approval.json",
      "repo/ops/tom-readonly/live-healthcheck-approval-packet.sh generate",
      "repo/ops/tom-readonly/live-healthcheck-approval-packet.sh check",
      "CONFIRM_APPROVAL_RECORD=I_APPROVE_LIVE_HEALTHCHECK_RECORD APPROVED_BY=Anan repo/ops/tom-readonly/live-healthcheck-approval.sh approve runtime/live-healthcheck-approval.json",
    ] : [
      "CONFIRM_MANAGED_ACTION_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CREATES_DRY_RUN_AUDIT_RECORD LOCAL_API_TOKEN=<本地令牌> repo/ops/tom-readonly/managed-action-dry-run-gate.sh run",
    ],
    safety: {
      readsStatusOnly: mode === "status",
      createsDryRunAuditOnly: mode === "run",
      callsManagedActionsDryRunApi: mode === "run",
      callsManagedActionsLiveApi: false,
      writesOpenClawInstanceDirs: false,
      restartsOpenClawInstances: false,
      mutatesOpenClawInstance: false,
    },
  };
}

function formatError(error) {
  return error instanceof Error ? error.message : String(error);
}

try {
  let runResult;
  if (mode === "run") {
    if (confirm !== "I_UNDERSTAND_THIS_ONLY_CREATES_DRY_RUN_AUDIT_RECORD") {
      fail("必须设置 CONFIRM_MANAGED_ACTION_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CREATES_DRY_RUN_AUDIT_RECORD");
    }
    if (!localApiToken) fail("必须通过 LOCAL_API_TOKEN 提供本地令牌");
    runResult = postJson("/api/managed-actions/dry-run", {
      instanceId,
      action,
      operator,
      reason,
      confirmedText: "DRY-RUN-ONLY",
    });
  } else if (mode !== "status") {
    fail(`未知模式：${mode}`);
  }
  console.log(JSON.stringify(buildStatus(runResult), null, 2));
} catch (error) {
  fail(formatError(error));
}
NODE
}

main() {
  require_command node
  require_command curl
  case "${1:-status}" in
    status)
      run_node "status"
      ;;
    run)
      run_node "run"
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
