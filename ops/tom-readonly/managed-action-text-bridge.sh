#!/usr/bin/env bash
set -euo pipefail
set +x

# OpenClaw/Discord 文本指令桥接入口。
# 只把机器人收到的文本写入 control-center runtime，并调用现有 managed-action-command-runner。
# parse/plan 不联网；dry-run 需要桥接层确认，并且只会继续调用 runner 的 dry-run-text。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
if [ "$(basename "$DEFAULT_DEPLOY_DIR")" = "repo" ] && [ -d "${DEFAULT_DEPLOY_DIR}/../runtime" ]; then
  DEFAULT_DEPLOY_DIR="$(cd "${DEFAULT_DEPLOY_DIR}/.." && pwd)"
fi
DEPLOY_DIR="${DEPLOY_DIR:-$DEFAULT_DEPLOY_DIR}"
export DEPLOY_DIR
RUNTIME_DIR="${RUNTIME_DIR:-${DEPLOY_DIR}/runtime}"
MANAGED_ACTION_COMMAND_RUNNER="${MANAGED_ACTION_COMMAND_RUNNER:-${SCRIPT_DIR}/managed-action-command-runner.sh}"
MANAGED_ACTION_TEXT="${MANAGED_ACTION_TEXT:-}"
MANAGED_ACTION_TEXT_FILE="${MANAGED_ACTION_TEXT_FILE:-}"
MANAGED_ACTION_TEXT_BRIDGE_COMMAND_FILE="${MANAGED_ACTION_TEXT_BRIDGE_COMMAND_FILE:-${RUNTIME_DIR}/managed-action-command.txt}"
CONFIRM_MANAGED_ACTION_TEXT_BRIDGE="${CONFIRM_MANAGED_ACTION_TEXT_BRIDGE:-}"
BRIDGE_DRY_RUN_CONFIRMATION="I_UNDERSTAND_THIS_ONLY_RUNS_MANAGED_ACTION_DRY_RUN_TEXT"
RUNNER_DRY_RUN_CONFIRMATION="I_UNDERSTAND_THIS_ONLY_CALLS_MANAGED_ACTION_DRY_RUN_API"

usage() {
  cat <<'TEXT'
用法：
  managed-action-text-bridge.sh parse <command.txt|->
  managed-action-text-bridge.sh plan <command.txt|->
  managed-action-text-bridge.sh dry-run <command.txt|->

也可以通过环境变量传入文本：
  MANAGED_ACTION_TEXT='对 tom 运行 zhihu-human-ops-writing dry-run' managed-action-text-bridge.sh plan
  MANAGED_ACTION_TEXT_FILE=runtime/command.txt managed-action-text-bridge.sh parse

dry-run 必须设置：
  CONFIRM_MANAGED_ACTION_TEXT_BRIDGE=I_UNDERSTAND_THIS_ONLY_RUNS_MANAGED_ACTION_DRY_RUN_TEXT

令牌仍由底层 runner 处理：
  LOCAL_API_TOKEN=<本地令牌>
  MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container

安全边界：
  - parse/plan 只写 control-center runtime 的文本副本，并调用 runner parse-text/plan-text。
  - dry-run 只调用 runner dry-run-text，底层只会请求 dry-run API。
  - 不打开 live gate，不修改 OpenClaw 实例目录，不重启实例。
TEXT
}

json_escape_node='
function compactLines(text, limit = 40) {
  return String(text || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, limit);
}

function baseSafety(extra = {}) {
  return {
    invokesCommandRunner: false,
    callsManagedActionsDryRunApi: false,
    callsManagedActionsLiveApi: false,
    writesControlCenterRuntimeOnly: false,
    writesOpenClawInstanceDirs: false,
    restartsOpenClawInstances: false,
    mutatesOpenClawInstance: false,
    opensLiveGate: false,
    ...extra,
  };
}
'

emit_blocked() {
  local status="$1"
  local issue="$2"
  local mode="${3:-${1:-unknown}}"
  STATUS="$status" ISSUE="$issue" MODE_NAME="$mode" node <<NODE
${json_escape_node}
console.log(JSON.stringify({
  schemaVersion: 1,
  status: process.env.STATUS,
  mode: process.env.MODE_NAME,
  generatedAt: new Date().toISOString(),
  issues: [process.env.ISSUE],
  nextCommands: [
    "repo/ops/tom-readonly/managed-action-text-bridge.sh parse <command.txt>",
    "repo/ops/tom-readonly/managed-action-text-bridge.sh plan <command.txt>",
    "CONFIRM_MANAGED_ACTION_TEXT_BRIDGE=${BRIDGE_DRY_RUN_CONFIRMATION} repo/ops/tom-readonly/managed-action-text-bridge.sh dry-run <command.txt>",
  ],
  safety: baseSafety({
    blockedBeforeRunner: true,
  }),
}, null, 2));
NODE
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    emit_blocked "blocked_missing_dependency" "缺少命令：$1" "${MODE_NAME:-unknown}"
    exit 2
  }
}

normalize_mode() {
  case "$1" in
    parse) printf '%s' "parse-text" ;;
    plan) printf '%s' "plan-text" ;;
    dry-run) printf '%s' "dry-run-text" ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      emit_blocked "blocked_invalid_mode" "未知模式：$1。支持 parse、plan、dry-run。" "$1"
      exit 2
      ;;
  esac
}

read_input_text() {
  local input_arg="${1:-}"
  if [ -n "$input_arg" ]; then
    if [ "$input_arg" = "-" ]; then
      cat
      return
    fi
    [ -f "$input_arg" ] || {
      emit_blocked "blocked_input_missing" "输入文件不存在：$input_arg" "$MODE_NAME"
      exit 2
    }
    cat "$input_arg"
    return
  fi

  if [ -n "$MANAGED_ACTION_TEXT_FILE" ]; then
    [ -f "$MANAGED_ACTION_TEXT_FILE" ] || {
      emit_blocked "blocked_input_missing" "MANAGED_ACTION_TEXT_FILE 不存在：$MANAGED_ACTION_TEXT_FILE" "$MODE_NAME"
      exit 2
    }
    cat "$MANAGED_ACTION_TEXT_FILE"
    return
  fi

  if [ -n "$MANAGED_ACTION_TEXT" ]; then
    printf '%s' "$MANAGED_ACTION_TEXT"
    return
  fi

  emit_blocked "blocked_input_required" "必须提供 command.txt、标准输入、MANAGED_ACTION_TEXT 或 MANAGED_ACTION_TEXT_FILE。" "$MODE_NAME"
  exit 2
}

write_runtime_command_text() {
  local text="$1"
  mkdir -p "$(dirname "$MANAGED_ACTION_TEXT_BRIDGE_COMMAND_FILE")"
  printf '%s\n' "$text" > "$MANAGED_ACTION_TEXT_BRIDGE_COMMAND_FILE"
}

emit_summary() {
  local bridge_status="$1"
  local runner_exit_code="$2"
  local runner_stdout_file="$3"
  local runner_stderr_file="$4"
  local text_preview="$5"
  BRIDGE_STATUS="$bridge_status" \
    MODE_NAME="$MODE_NAME" \
    RUNNER_MODE="$RUNNER_MODE" \
    RUNNER_EXIT_CODE="$runner_exit_code" \
    RUNNER_STDOUT_FILE="$runner_stdout_file" \
    RUNNER_STDERR_FILE="$runner_stderr_file" \
    COMMAND_FILE="$MANAGED_ACTION_TEXT_BRIDGE_COMMAND_FILE" \
    TEXT_PREVIEW="$text_preview" \
    node <<NODE
const fs = require("node:fs");
${json_escape_node}

const stdout = fs.existsSync(process.env.RUNNER_STDOUT_FILE)
  ? fs.readFileSync(process.env.RUNNER_STDOUT_FILE, "utf8")
  : "";
const stderr = fs.existsSync(process.env.RUNNER_STDERR_FILE)
  ? fs.readFileSync(process.env.RUNNER_STDERR_FILE, "utf8")
  : "";
let runnerReport = null;
try {
  runnerReport = stdout.trim() ? JSON.parse(stdout) : null;
} catch (error) {
  runnerReport = {
    status: "invalid_runner_json",
    issues: [error instanceof Error ? error.message : String(error)],
    rawLines: compactLines(stdout, 40),
  };
}

const runnerSafety = runnerReport?.safety || {};
const target = runnerReport?.target || runnerReport?.command || undefined;
const operationRequestId = runnerReport?.dryRunApi?.body?.review?.operationRequestId
  || runnerReport?.review?.operationRequestId
  || undefined;
const commandPreview = runnerReport?.dryRunApi?.body?.commandPreview
  || runnerReport?.commandPreview
  || [];
const runnerExitCode = Number(process.env.RUNNER_EXIT_CODE || "1");
const ok = runnerExitCode === 0;
const status = ok ? process.env.BRIDGE_STATUS : "blocked_bridge_runner";

console.log(JSON.stringify({
  schemaVersion: 1,
  status,
  mode: process.env.MODE_NAME,
  runnerMode: process.env.RUNNER_MODE,
  runnerStatus: runnerReport?.status || "unknown",
  runnerExitCode,
  generatedAt: new Date().toISOString(),
  inputPath: process.env.COMMAND_FILE,
  inputPreview: process.env.TEXT_PREVIEW,
  ...(target ? { target } : {}),
  ...(operationRequestId ? { operationRequestId } : {}),
  ...(commandPreview.length ? { commandPreview } : {}),
  ...(ok ? {} : {
    issues: [
      ...(Array.isArray(runnerReport?.issues) ? runnerReport.issues : []),
      ...compactLines(stderr, 20),
    ].filter(Boolean),
  }),
  nextCommands: Array.isArray(runnerReport?.nextCommands)
    ? runnerReport.nextCommands
    : [
      "repo/ops/tom-readonly/managed-action-text-bridge.sh plan <command.txt>",
      "CONFIRM_MANAGED_ACTION_TEXT_BRIDGE=${BRIDGE_DRY_RUN_CONFIRMATION} repo/ops/tom-readonly/managed-action-text-bridge.sh dry-run <command.txt>",
    ],
  safety: baseSafety({
    invokesCommandRunner: true,
    commandFileWritesControlCenterRuntimeOnly: true,
    writesControlCenterRuntimeOnly: true,
    callsManagedActionsDryRunApi: runnerSafety.callsManagedActionsDryRunApi === true,
    callsManagedActionsLiveApi: false,
    writesOpenClawInstanceDirs: false,
    restartsOpenClawInstances: false,
    mutatesOpenClawInstance: false,
    opensLiveGate: false,
    requiresBridgeDryRunConfirmation: process.env.MODE_NAME === "dry-run",
  }),
}, null, 2));
NODE
}

main() {
  MODE_NAME="${1:-parse}"
  RUNNER_MODE="$(normalize_mode "$MODE_NAME")"
  local input_arg="${2:-}"

  require_command node
  [ -x "$MANAGED_ACTION_COMMAND_RUNNER" ] || {
    emit_blocked "blocked_runner_missing" "managed-action-command-runner 不存在或不可执行：$MANAGED_ACTION_COMMAND_RUNNER" "$MODE_NAME"
    exit 2
  }

  if [ "$MODE_NAME" = "dry-run" ] && [ "$CONFIRM_MANAGED_ACTION_TEXT_BRIDGE" != "$BRIDGE_DRY_RUN_CONFIRMATION" ]; then
    emit_blocked "blocked_confirmation_required" "dry-run 必须设置 CONFIRM_MANAGED_ACTION_TEXT_BRIDGE=${BRIDGE_DRY_RUN_CONFIRMATION}。" "$MODE_NAME"
    exit 2
  fi

  local text
  text="$(read_input_text "$input_arg")"
  text="$(printf '%s' "$text" | sed -e 's/[[:space:]]*$//')"
  [ -n "$text" ] || {
    emit_blocked "blocked_input_required" "文本指令不能为空。" "$MODE_NAME"
    exit 2
  }

  write_runtime_command_text "$text"

  local runner_stdout_file
  local runner_stderr_file
  runner_stdout_file="$(mktemp "${TMPDIR:-/tmp}/openclaw-text-bridge-stdout.XXXXXX")"
  runner_stderr_file="$(mktemp "${TMPDIR:-/tmp}/openclaw-text-bridge-stderr.XXXXXX")"
  local runner_exit_code

  if [ "$MODE_NAME" = "dry-run" ]; then
    export CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN="${CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN:-$RUNNER_DRY_RUN_CONFIRMATION}"
  fi

  set +e
  "$MANAGED_ACTION_COMMAND_RUNNER" "$RUNNER_MODE" "$MANAGED_ACTION_TEXT_BRIDGE_COMMAND_FILE" >"$runner_stdout_file" 2>"$runner_stderr_file"
  runner_exit_code=$?
  set -e

  local bridge_status
  case "$MODE_NAME" in
    parse) bridge_status="bridge_parse_completed" ;;
    plan) bridge_status="bridge_plan_completed" ;;
    dry-run) bridge_status="bridge_dry_run_completed" ;;
    *) bridge_status="bridge_completed" ;;
  esac

  local text_preview
  text_preview="$(printf '%s' "$text" | tr '\n' ' ' | cut -c 1-180)"
  emit_summary "$bridge_status" "$runner_exit_code" "$runner_stdout_file" "$runner_stderr_file" "$text_preview"
  rm -f "$runner_stdout_file" "$runner_stderr_file"
  [ "$runner_exit_code" -eq 0 ]
}

main "$@"
