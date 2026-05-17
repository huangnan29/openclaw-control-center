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
PREFLIGHT_SCRIPT="${PREFLIGHT_SCRIPT:-${DEPLOY_DIR}/repo/ops/tom-readonly/live-healthcheck-preflight.sh}"
SMOKE_SCRIPT="${SMOKE_SCRIPT:-${DEPLOY_DIR}/repo/ops/tom-readonly/live-healthcheck-smoke.sh}"
HEALTHCHECK_SCRIPT="${HEALTHCHECK_SCRIPT:-${DEPLOY_DIR}/healthcheck.sh}"
CONFIRM_LIVE_HEALTHCHECK_WINDOW="${CONFIRM_LIVE_HEALTHCHECK_WINDOW:-}"
WINDOW_ACTIVE="false"

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
  [ -x "$PREFLIGHT_SCRIPT" ] || fail "preflight 脚本不存在或不可执行：${PREFLIGHT_SCRIPT}"
  [ -x "$SMOKE_SCRIPT" ] || fail "smoke 脚本不存在或不可执行：${SMOKE_SCRIPT}"
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
  write_rollout_file
  write_override_file
  record_state_marker

  log "临时启用 control-center live healthcheck 窗口"
  cd "$DEPLOY_DIR"
  compose -f "$COMPOSE_FILE" -f "$OVERRIDE_FILE" up -d --build "$SERVICE_NAME"

  log "执行 EXPECT_LIVE_READY=true preflight"
  EXPECT_LIVE_READY=true \
    ROLLOUT_FILE="$ROLLOUT_HOST_FILE" \
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
  fi
  exit "$exit_code"
}

show_status() {
  require_base_paths
  [ -x "$PREFLIGHT_SCRIPT" ] || fail "preflight 脚本不存在或不可执行：${PREFLIGHT_SCRIPT}"
  local rollout_for_status="$ROLLOUT_HOST_FILE"
  if [ -f "$OVERRIDE_FILE" ]; then
    log "检测到临时 override 文件：${OVERRIDE_FILE}"
  else
    log "未检测到临时 override 文件"
  fi
  if [ ! -f "$rollout_for_status" ]; then
    rollout_for_status="$ROLLOUT_SOURCE"
  fi
  ROLLOUT_FILE="$rollout_for_status" \
    CONTAINER_NAME="$CONTAINER_NAME" \
    "$PREFLIGHT_SCRIPT"
}

run_once() {
  require_confirm
  [ -n "${LOCAL_API_TOKEN:-}" ] || fail "必须通过环境变量提供 LOCAL_API_TOKEN"
  [ "${CONFIRM_LIVE_HEALTHCHECK:-}" = "I_UNDERSTAND_THIS_CALLS_LIVE_API" ] || \
    fail "必须设置 CONFIRM_LIVE_HEALTHCHECK=I_UNDERSTAND_THIS_CALLS_LIVE_API"

  trap rollback_on_exit EXIT
  WINDOW_ACTIVE="true"
  start_live_window
  "$SMOKE_SCRIPT"
  WINDOW_ACTIVE="false"
  stop_live_window
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
