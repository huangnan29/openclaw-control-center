#!/usr/bin/env bash
set -euo pipefail
set +x

# 一次性 live healthcheck 演练窗口。
# 只临时调整控制中心容器配置，不修改、不重启、不写入任何 OpenClaw 实例目录。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
SERVICE_NAME="${SERVICE_NAME:-control-center}"
CONTAINER_NAME="${CONTAINER_NAME:-openclaw-control-center-readonly}"
COMPOSE_FILE="${COMPOSE_FILE:-${DEPLOY_DIR}/docker-compose.yml}"
STATE_DIR="${STATE_DIR:-${DEPLOY_DIR}/runtime/deploy-state}"
OVERRIDE_FILE="${OVERRIDE_FILE:-${DEPLOY_DIR}/runtime/docker-compose.live-healthcheck.override.yml}"
ROLLOUT_HOST_FILE="${ROLLOUT_HOST_FILE:-${DEPLOY_DIR}/runtime/managed-action-healthcheck-rollout.json}"
ROLLOUT_SOURCE="${ROLLOUT_SOURCE:-${DEPLOY_DIR}/repo/ops/tom-readonly/managed-action-healthcheck-rollout.example.json}"
APPROVAL_FILE="${APPROVAL_FILE:-${DEPLOY_DIR}/runtime/live-healthcheck-approval.json}"
APPROVAL_SCRIPT="${APPROVAL_SCRIPT:-${DEPLOY_DIR}/repo/ops/tom-readonly/live-healthcheck-approval.sh}"
APPROVAL_PACKET_FILE="${APPROVAL_PACKET_FILE:-}"
APPROVAL_PACKET_SCRIPT="${APPROVAL_PACKET_SCRIPT:-${DEPLOY_DIR}/repo/ops/tom-readonly/live-healthcheck-approval-packet.sh}"
PREFLIGHT_SCRIPT="${PREFLIGHT_SCRIPT:-${DEPLOY_DIR}/repo/ops/tom-readonly/live-healthcheck-preflight.sh}"
SMOKE_SCRIPT="${SMOKE_SCRIPT:-${DEPLOY_DIR}/repo/ops/tom-readonly/live-healthcheck-smoke.sh}"
REPORT_SCRIPT="${REPORT_SCRIPT:-${DEPLOY_DIR}/repo/ops/tom-readonly/live-healthcheck-report.sh}"
HEALTHCHECK_SCRIPT="${HEALTHCHECK_SCRIPT:-${DEPLOY_DIR}/healthcheck.sh}"
IMPACT_SCRIPT="${IMPACT_SCRIPT:-${DEPLOY_DIR}/repo/ops/tom-readonly/instance-impact-snapshot.sh}"
CONFIRM_LIVE_HEALTHCHECK_WINDOW="${CONFIRM_LIVE_HEALTHCHECK_WINDOW:-}"
WINDOW_ACTIVE="false"
IMPACT_BEFORE=""

timestamp() {
  date +"%Y-%m-%dT%H:%M:%S%z"
}

log() {
  printf '[%s] %s\n' "$(timestamp)" "$*"
}

fail() {
  printf '[失败] %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"
}

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    fail "缺少 docker compose 或 docker-compose"
  fi
}

require_confirm() {
  [ "$CONFIRM_LIVE_HEALTHCHECK_WINDOW" = "I_UNDERSTAND_THIS_TEMPORARILY_ENABLES_LIVE_GATE" ] || \
    fail "必须设置 CONFIRM_LIVE_HEALTHCHECK_WINDOW=I_UNDERSTAND_THIS_TEMPORARILY_ENABLES_LIVE_GATE"
}

require_base_paths() {
  [ -d "$DEPLOY_DIR" ] || fail "部署目录不存在：${DEPLOY_DIR}"
  [ -f "$COMPOSE_FILE" ] || fail "docker-compose.yml 不存在：${COMPOSE_FILE}"
  [ -x "$HEALTHCHECK_SCRIPT" ] || fail "healthcheck 脚本不存在或不可执行：${HEALTHCHECK_SCRIPT}"
}

require_live_paths() {
  [ -f "$ROLLOUT_SOURCE" ] || fail "rollout 样板不存在：${ROLLOUT_SOURCE}"
  [ -x "$APPROVAL_SCRIPT" ] || fail "批准校验脚本不存在或不可执行：${APPROVAL_SCRIPT}"
  [ -x "$APPROVAL_PACKET_SCRIPT" ] || fail "批准前证据包脚本不存在或不可执行：${APPROVAL_PACKET_SCRIPT}"
  [ -x "$PREFLIGHT_SCRIPT" ] || fail "preflight 脚本不存在或不可执行：${PREFLIGHT_SCRIPT}"
  [ -x "$SMOKE_SCRIPT" ] || fail "smoke 脚本不存在或不可执行：${SMOKE_SCRIPT}"
  [ -x "$REPORT_SCRIPT" ] || fail "报告脚本不存在或不可执行：${REPORT_SCRIPT}"
}

check_approval_packet() {
  log "校验 live healthcheck 批准前证据包"
  if [ -n "$APPROVAL_PACKET_FILE" ]; then
    INSTANCE_ID="${INSTANCE_ID:-tom}" \
      ACTION="healthcheck" \
      OPERATOR="${OPERATOR:-Anan}" \
      "$APPROVAL_PACKET_SCRIPT" check "$APPROVAL_PACKET_FILE"
  else
    INSTANCE_ID="${INSTANCE_ID:-tom}" \
      ACTION="healthcheck" \
      OPERATOR="${OPERATOR:-Anan}" \
      "$APPROVAL_PACKET_SCRIPT" check
  fi
}

check_approval_file() {
  log "校验 live healthcheck 人工批准文件：${APPROVAL_FILE}"
  INSTANCE_ID="${INSTANCE_ID:-tom}" \
    OPERATOR="${OPERATOR:-Anan}" \
    "$APPROVAL_SCRIPT" check "$APPROVAL_FILE"
}

consume_approval_file() {
  log "标记 live healthcheck 人工批准记录为已使用：${APPROVAL_FILE}"
  INSTANCE_ID="${INSTANCE_ID:-tom}" \
    OPERATOR="${OPERATOR:-Anan}" \
    "$APPROVAL_SCRIPT" consume "$APPROVAL_FILE"
}

write_rollout_file() {
  mkdir -p "$(dirname "$ROLLOUT_HOST_FILE")"
  install -m 0644 "$ROLLOUT_SOURCE" "$ROLLOUT_HOST_FILE"
  log "已写入演练 rollout：${ROLLOUT_HOST_FILE}"
}

write_override_file() {
  mkdir -p "$(dirname "$OVERRIDE_FILE")"
  cat > "$OVERRIDE_FILE" <<'YAML'
services:
  control-center:
    environment:
      READONLY_MODE: "false"
      MANAGED_ACTIONS_LIVE_ENABLED: "true"
      MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED: "true"
      MANAGED_ACTIONS_LIVE_ALLOWED_ACTIONS: "healthcheck"
      MANAGED_ACTIONS_LIVE_ROLLOUT_FILE: "/app/runtime/managed-action-healthcheck-rollout.json"
YAML
  log "已写入临时 compose override：${OVERRIDE_FILE}"
}

record_state_marker() {
  mkdir -p "$STATE_DIR"
  {
    printf 'startedAt=%s\n' "$(timestamp)"
    printf 'composeFile=%s\n' "$COMPOSE_FILE"
    printf 'overrideFile=%s\n' "$OVERRIDE_FILE"
    printf 'rolloutHostFile=%s\n' "$ROLLOUT_HOST_FILE"
    if [ -d "${DEPLOY_DIR}/repo/.git" ]; then
      printf 'repoCommit=%s\n' "$(git -C "${DEPLOY_DIR}/repo" rev-parse HEAD)"
    fi
  } > "${STATE_DIR}/live-healthcheck-window.state"
}

start_live_window() {
  require_confirm
  require_base_paths
  require_live_paths
  check_approval_packet
  check_approval_file
  write_rollout_file
  write_override_file
  record_state_marker

  log "临时启用 control-center live healthcheck 窗口"
  cd "$DEPLOY_DIR"
  compose -f "$COMPOSE_FILE" -f "$OVERRIDE_FILE" up -d --build "$SERVICE_NAME"

  log "执行 EXPECT_LIVE_READY=true preflight"
  EXPECT_LIVE_READY=true \
    ROLLOUT_FILE="$ROLLOUT_HOST_FILE" \
    INSTANCE_ID="${INSTANCE_ID:-tom}" \
    OPERATOR="${OPERATOR:-Anan}" \
    CONTAINER_NAME="$CONTAINER_NAME" \
    "$PREFLIGHT_SCRIPT"
}

stop_live_window() {
  require_base_paths
  log "恢复 control-center 只读配置"
  cd "$DEPLOY_DIR"
  compose -f "$COMPOSE_FILE" up -d --build "$SERVICE_NAME"
  rm -f "$OVERRIDE_FILE"
  "$HEALTHCHECK_SCRIPT"
  rm -f "${STATE_DIR}/live-healthcheck-window.state"
  log "已恢复只读监控状态"
}

rollback_on_exit() {
  local exit_code=$?
  if [ "$WINDOW_ACTIVE" = "true" ]; then
    log "退出前自动恢复只读状态"
    if ! stop_live_window; then
      printf '[失败] 自动恢复只读状态失败，请立即手动运行：%s disable\n' "$0" >&2
      exit 1
    fi
    if [ -n "$IMPACT_BEFORE" ] && [ -x "$IMPACT_SCRIPT" ]; then
      local impact_after
      impact_after="$("$IMPACT_SCRIPT" snapshot "after-live-healthcheck-rollback")"
      "$IMPACT_SCRIPT" compare "$IMPACT_BEFORE" "$impact_after"
    fi
  fi
  exit "$exit_code"
}

show_status() {
  require_base_paths
  [ -x "$PREFLIGHT_SCRIPT" ] || fail "preflight 脚本不存在或不可执行：${PREFLIGHT_SCRIPT}"
  [ -x "$APPROVAL_SCRIPT" ] || fail "批准校验脚本不存在或不可执行：${APPROVAL_SCRIPT}"
  local rollout_for_status="$ROLLOUT_HOST_FILE"
  if [ -f "$OVERRIDE_FILE" ]; then
    log "检测到临时 override 文件：${OVERRIDE_FILE}"
  else
    log "未检测到临时 override 文件"
  fi
  log "读取 approval 状态：${APPROVAL_FILE}"
  INSTANCE_ID="${INSTANCE_ID:-tom}" \
    OPERATOR="${OPERATOR:-Anan}" \
    "$APPROVAL_SCRIPT" status "$APPROVAL_FILE"
  if [ ! -f "$rollout_for_status" ]; then
    rollout_for_status="$ROLLOUT_SOURCE"
  fi
  ROLLOUT_FILE="$rollout_for_status" \
    CONTAINER_NAME="$CONTAINER_NAME" \
    "$PREFLIGHT_SCRIPT"
}

run_once() {
  require_confirm
  [ -x "$IMPACT_SCRIPT" ] || fail "实例影响快照脚本不存在或不可执行：${IMPACT_SCRIPT}"
  [ -n "${LOCAL_API_TOKEN:-}" ] || fail "必须通过环境变量提供 LOCAL_API_TOKEN"
  [ "${CONFIRM_LIVE_HEALTHCHECK:-}" = "I_UNDERSTAND_THIS_CALLS_LIVE_API" ] || \
    fail "必须设置 CONFIRM_LIVE_HEALTHCHECK=I_UNDERSTAND_THIS_CALLS_LIVE_API"

  IMPACT_BEFORE="$("$IMPACT_SCRIPT" snapshot "before-live-healthcheck")"
  trap rollback_on_exit EXIT
  WINDOW_ACTIVE="true"
  start_live_window
  INSTANCE_ID="${INSTANCE_ID:-tom}" \
    OPERATOR="${OPERATOR:-Anan}" \
    "$SMOKE_SCRIPT"
  consume_approval_file
  WINDOW_ACTIVE="false"
  stop_live_window
  local impact_after
  impact_after="$("$IMPACT_SCRIPT" snapshot "after-live-healthcheck")"
  "$IMPACT_SCRIPT" compare "$IMPACT_BEFORE" "$impact_after"
  "$REPORT_SCRIPT" report "$IMPACT_BEFORE" "$impact_after" "$APPROVAL_FILE"
  trap - EXIT
}

usage() {
  cat <<'TEXT'
用法：
  live-healthcheck-window.sh status
  live-healthcheck-window.sh enable
  live-healthcheck-window.sh disable
  live-healthcheck-window.sh run

安全确认：
  enable/run 必须设置：
    CONFIRM_LIVE_HEALTHCHECK_WINDOW=I_UNDERSTAND_THIS_TEMPORARILY_ENABLES_LIVE_GATE

  run 还必须设置：
    CONFIRM_LIVE_HEALTHCHECK=I_UNDERSTAND_THIS_CALLS_LIVE_API
    LOCAL_API_TOKEN=<本地令牌>

  run 还必须存在通过校验的批准文件：
    /srv/openclaw-control-center-readonly/runtime/live-healthcheck-approval.json

  run 还必须存在新鲜、匹配当前提交且通过校验的批准前证据包：
    /srv/openclaw-control-center-readonly/runtime/live-healthcheck-approval-packets/

  run 会自动生成 before/after 实例影响快照并比较。
  run 成功后会生成 live healthcheck 演练报告。
TEXT
}

main() {
  require_command docker

  case "${1:-status}" in
    status)
      show_status
      ;;
    enable)
      start_live_window
      ;;
    disable)
      stop_live_window
      ;;
    run)
      run_once
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
