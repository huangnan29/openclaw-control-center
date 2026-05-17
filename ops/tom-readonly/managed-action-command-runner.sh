#!/usr/bin/env bash
set -euo pipefail
set +x

# OpenClaw/Discord 侧管理动作命令入口。
# plan 只校验命令并输出将要提交的 dry-run payload，不联网、不写审计。
# dry-run 必须显式确认并提供 LOCAL_API_TOKEN，只调用 dry-run API 写审计，不执行实例命令。
# status 只读取控制中心管理动作和 readiness 状态。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
CONTROL_CENTER_BASE_URL="${CONTROL_CENTER_BASE_URL:-http://127.0.0.1:4311}"
CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN="${CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN:-}"
LOCAL_API_TOKEN="${LOCAL_API_TOKEN:-}"
MANAGED_ACTION_COMMAND_TOKEN_SOURCE="${MANAGED_ACTION_COMMAND_TOKEN_SOURCE:-env}"
RESOLVED_LOCAL_API_TOKEN_SOURCE="${LOCAL_API_TOKEN:+env}"
COMMAND_FILE="${2:-${MANAGED_ACTION_COMMAND_FILE:-}}"

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
  managed-action-command-runner.sh status
  managed-action-command-runner.sh plan <command.json|-> 
  managed-action-command-runner.sh dry-run <command.json|->

command.json 示例：
  {
    "instanceId": "tom",
    "action": "skill_run",
    "operator": "Anan",
    "reason": "通过 OpenClaw 指令预览 skill 调用",
    "skillName": "zhihu-human-ops-writing"
  }

dry-run 必须设置：
  CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CALLS_MANAGED_ACTION_DRY_RUN_API
  LOCAL_API_TOKEN=<本地令牌>
  # 如果令牌只在 control-center 容器环境中，可以显式使用：
  MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container

安全边界：
  - plan 不联网、不写文件。
  - dry-run 只调用 /api/managed-actions/dry-run，不执行 OpenClaw 实例命令。
  - 不打开 live gate，不修改 OpenClaw 实例目录，不重启实例。
TEXT
}

resolve_local_api_token_for_dry_run() {
  if [ -n "$LOCAL_API_TOKEN" ]; then
    RESOLVED_LOCAL_API_TOKEN_SOURCE="env"
    return
  fi
  if [ "$MANAGED_ACTION_COMMAND_TOKEN_SOURCE" != "container" ]; then
    RESOLVED_LOCAL_API_TOKEN_SOURCE="missing"
    return
  fi
  require_command docker
  LOCAL_API_TOKEN="$(
    cd "$DEPLOY_DIR" &&
      docker compose exec -T control-center sh -lc 'printf "%s" "$LOCAL_API_TOKEN"'
  )"
  if [ -n "$LOCAL_API_TOKEN" ]; then
    RESOLVED_LOCAL_API_TOKEN_SOURCE="container"
  else
    RESOLVED_LOCAL_API_TOKEN_SOURCE="missing"
  fi
}

run_node() {
  local mode="$1"
  MODE="$mode" \
    DEPLOY_DIR="$DEPLOY_DIR" \
    CONTROL_CENTER_BASE_URL="$CONTROL_CENTER_BASE_URL" \
    CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN="$CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN" \
    LOCAL_API_TOKEN="$LOCAL_API_TOKEN" \
    RESOLVED_LOCAL_API_TOKEN_SOURCE="$RESOLVED_LOCAL_API_TOKEN_SOURCE" \
    COMMAND_FILE="$COMMAND_FILE" \
    node <<'NODE'
const fs = require("node:fs");

const mode = process.env.MODE || "status";
const commandFile = process.env.COMMAND_FILE || "";
const baseUrl = normalizeBaseUrl(process.env.CONTROL_CENTER_BASE_URL || "http://127.0.0.1:4311");
const confirmDryRun = process.env.CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN || "";
const localApiToken = process.env.LOCAL_API_TOKEN || "";
const localApiTokenSource = process.env.RESOLVED_LOCAL_API_TOKEN_SOURCE || "missing";
const dryRunConfirmation = "DRY-RUN-ONLY";
const allowedActions = new Set(["healthcheck", "collector_refresh", "skill_run"]);

function normalizeBaseUrl(value) {
  const parsed = new URL(value);
  parsed.pathname = parsed.pathname.replace(/\/+$/, "");
  parsed.search = "";
  parsed.hash = "";
  return parsed.toString().replace(/\/$/, "");
}

function compactLines(text, limit = 80) {
  return String(text || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, limit);
}

function readCommand() {
  if (!commandFile) throw new Error("缺少 command.json 路径；plan/dry-run 必须提供命令文件。");
  const raw = commandFile === "-" ? fs.readFileSync(0, "utf8") : fs.readFileSync(commandFile, "utf8");
  const parsed = JSON.parse(raw);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("command.json 必须是 JSON object。");
  }
  return parsed;
}

function readRequiredString(obj, key, limit) {
  const value = typeof obj[key] === "string" ? obj[key].trim() : "";
  if (!value) throw new Error(`${key} 不能为空。`);
  if (value.length > limit) throw new Error(`${key} 不能超过 ${limit} 个字符。`);
  return value;
}

function readOptionalString(obj, key, limit) {
  const value = typeof obj[key] === "string" ? obj[key].trim() : "";
  if (!value) return undefined;
  if (value.length > limit) throw new Error(`${key} 不能超过 ${limit} 个字符。`);
  return value;
}

function buildPayload(command) {
  const instanceId = readRequiredString(command, "instanceId", 120);
  const action = readRequiredString(command, "action", 80);
  if (!allowedActions.has(action)) throw new Error("action must be one of: healthcheck, collector_refresh, skill_run.");
  const operator = readRequiredString(command, "operator", 120);
  const reason = readRequiredString(command, "reason", 240);
  const skillName = readOptionalString(command, "skillName", 120);
  if (action === "skill_run" && !skillName) throw new Error("action=skill_run 时必须提供 skillName。");
  const confirmedText = readOptionalString(command, "confirmedText", 80) || dryRunConfirmation;
  if (confirmedText !== dryRunConfirmation) throw new Error(`confirmedText must equal ${dryRunConfirmation}.`);
  return {
    instanceId,
    action,
    operator,
    reason,
    confirmedText,
    ...(skillName ? { skillName } : {}),
  };
}

function safePayloadForOutput(payload) {
  return { ...payload };
}

async function requestJson(path, options = {}) {
  const response = await fetch(`${baseUrl}${path}`, {
    method: options.method || "GET",
    headers: {
      ...(options.body ? { "content-type": "application/json" } : {}),
      ...(options.token ? { "x-local-token": options.token } : {}),
    },
    body: options.body ? JSON.stringify(options.body) : undefined,
  });
  const text = await response.text();
  let body;
  try {
    body = text ? JSON.parse(text) : {};
  } catch (error) {
    body = { status: "invalid_json", rawLines: compactLines(text, 40), error: String(error?.message || error) };
  }
  return { statusCode: response.status, ok: response.ok, body };
}

function baseSafety(extra = {}) {
  return {
    callsManagedActionsDryRunApi: false,
    callsManagedActionsLiveApi: false,
    writesOpenClawInstanceDirs: false,
    restartsOpenClawInstances: false,
    mutatesOpenClawInstance: false,
    opensLiveGate: false,
    ...extra,
  };
}

function nextDryRunCommand() {
  return "CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CALLS_MANAGED_ACTION_DRY_RUN_API LOCAL_API_TOKEN=<本地令牌> repo/ops/tom-readonly/managed-action-command-runner.sh dry-run <command.json>";
}

function plannedReport(payload) {
  return {
    schemaVersion: 1,
    status: "planned",
    mode,
    generatedAt: new Date().toISOString(),
    baseUrl,
    target: {
      instanceId: payload.instanceId,
      action: payload.action,
      operator: payload.operator,
      ...(payload.skillName ? { skillName: payload.skillName } : {}),
    },
    payload: safePayloadForOutput(payload),
    nextCommands: [nextDryRunCommand()],
    safety: baseSafety({
      readsCommandFileOnly: true,
      requiresDryRunConfirmation: true,
      requiresLocalApiToken: true,
    }),
  };
}

async function statusReport() {
  const actions = await requestJson("/api/managed-actions");
  const readiness = await requestJson("/api/managed-actions/readiness");
  const ok = actions.ok && readiness.ok;
  return {
    schemaVersion: 1,
    status: ok ? "status_ready" : "blocked_status_api",
    mode,
    generatedAt: new Date().toISOString(),
    baseUrl,
    stages: {
      actions: { statusCode: actions.statusCode, body: actions.body },
      readiness: { statusCode: readiness.statusCode, body: readiness.body },
    },
    nextCommands: ["repo/ops/tom-readonly/managed-action-command-runner.sh plan <command.json>"],
    safety: baseSafety({
      readsStatusOnly: true,
    }),
  };
}

async function dryRunReport(payload) {
  if (confirmDryRun !== "I_UNDERSTAND_THIS_ONLY_CALLS_MANAGED_ACTION_DRY_RUN_API") {
    return {
      schemaVersion: 1,
      status: "blocked_confirmation_required",
      mode,
      generatedAt: new Date().toISOString(),
      issues: ["必须设置 CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CALLS_MANAGED_ACTION_DRY_RUN_API。"],
      nextCommands: [nextDryRunCommand()],
      safety: baseSafety({
        blockedBeforeApi: true,
        requiresDryRunConfirmation: true,
      }),
    };
  }
  if (!localApiToken.trim()) {
    return {
      schemaVersion: 1,
      status: "blocked_local_token_required",
      mode,
      generatedAt: new Date().toISOString(),
      issues: ["必须通过 LOCAL_API_TOKEN 提供本地令牌。"],
      nextCommands: [nextDryRunCommand()],
      safety: baseSafety({
        blockedBeforeApi: true,
        requiresLocalApiToken: true,
        localApiTokenSource,
      }),
    };
  }

  const result = await requestJson("/api/managed-actions/dry-run", {
    method: "POST",
    token: localApiToken,
    body: payload,
  });
  const ok = result.ok && result.body?.ok === true && result.body?.dryRun === true;
  return {
    schemaVersion: 1,
    status: ok ? "dry_run_completed" : "blocked_dry_run_api",
    mode,
    generatedAt: new Date().toISOString(),
    target: {
      instanceId: payload.instanceId,
      action: payload.action,
      operator: payload.operator,
      ...(payload.skillName ? { skillName: payload.skillName } : {}),
    },
    dryRunApi: {
      statusCode: result.statusCode,
      body: result.body,
    },
    nextCommands: ok
      ? [
        "repo/ops/tom-readonly/managed-action-command-runner.sh status",
        "repo/ops/tom-readonly/live-healthcheck-readiness.sh status",
      ]
      : [nextDryRunCommand()],
    safety: baseSafety({
      callsManagedActionsDryRunApi: true,
      createsDryRunAuditOnly: ok,
      requiresDryRunConfirmation: true,
      requiresLocalApiToken: true,
      localApiTokenSource,
    }),
  };
}

async function main() {
  if (mode === "status") return statusReport();
  if (mode !== "plan" && mode !== "dry-run") throw new Error(`未知模式：${mode}`);
  const payload = buildPayload(readCommand());
  if (mode === "plan") return plannedReport(payload);
  return dryRunReport(payload);
}

main()
  .then((report) => {
    console.log(JSON.stringify(report, null, 2));
    process.exit(String(report.status || "").startsWith("blocked_") ? 2 : 0);
  })
  .catch((error) => {
    console.log(JSON.stringify({
      schemaVersion: 1,
      status: "blocked_invalid_command",
      mode,
      generatedAt: new Date().toISOString(),
      issues: [error instanceof Error ? error.message : String(error)],
      nextCommands: mode === "status" ? [] : ["repo/ops/tom-readonly/managed-action-command-runner.sh plan <command.json>"],
      safety: baseSafety({
        blockedBeforeApi: true,
      }),
    }, null, 2));
    process.exit(2);
  });
NODE
}

main() {
  require_command node
  case "${1:-status}" in
    status)
      run_node "status"
      ;;
    plan)
      [ -n "$COMMAND_FILE" ] || fail "plan 必须提供 command.json 路径"
      run_node "plan"
      ;;
    dry-run)
      [ -n "$COMMAND_FILE" ] || fail "dry-run 必须提供 command.json 路径"
      resolve_local_api_token_for_dry_run
      run_node "dry-run"
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
