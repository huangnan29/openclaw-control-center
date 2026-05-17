#!/usr/bin/env bash
set -euo pipefail

# Tom collector 定时任务安装器：只更新当前用户 crontab 中的受控标记块。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
CONTAINER_NAME="${CONTAINER_NAME:-openclaw-control-center-readonly}"
SERVER_ID="${SERVER_ID:-tom-oracle}"
OUTPUT_PATH="${OUTPUT_PATH:-/app/runtime/collectors/${SERVER_ID}/snapshot.json}"
LOG_PATH="${LOG_PATH:-${DEPLOY_DIR}/runtime/collector-snapshot-cron.log}"
OPENCLAW_COLLECTOR_CRON_SCHEDULE="${OPENCLAW_COLLECTOR_CRON_SCHEDULE:-*/2 * * * *}"

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

shell_quote() {
  local value="$1"
  printf "'%s'" "$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
}

main() {
  require_command awk
  require_command crontab
  require_command sed

  [ -d "$DEPLOY_DIR" ] || fail "部署目录不存在：${DEPLOY_DIR}"
  [ -x "${DEPLOY_DIR}/collector-snapshot.sh" ] || fail "collector-snapshot.sh 不存在或不可执行：${DEPLOY_DIR}/collector-snapshot.sh"
  mkdir -p "$(dirname "$LOG_PATH")"

  local deploy_dir_q
  local container_name_q
  local server_id_q
  local output_path_q
  local log_path_q
  deploy_dir_q="$(shell_quote "$DEPLOY_DIR")"
  container_name_q="$(shell_quote "$CONTAINER_NAME")"
  server_id_q="$(shell_quote "$SERVER_ID")"
  output_path_q="$(shell_quote "$OUTPUT_PATH")"
  log_path_q="$(shell_quote "$LOG_PATH")"

  local cron_command
  cron_command="cd ${deploy_dir_q} && CONTAINER_NAME=${container_name_q} SERVER_ID=${server_id_q} OUTPUT_PATH=${output_path_q} ./collector-snapshot.sh >> ${log_path_q} 2>&1"

  local existing
  local cleaned
  existing="$(crontab -l 2>/dev/null || true)"
  cleaned="$(
    printf '%s\n' "$existing" | awk '
      $0 == "# OPENCLAW_COLLECTOR_CRON_BEGIN" { skip = 1; next }
      $0 == "# OPENCLAW_COLLECTOR_CRON_END" { skip = 0; next }
      skip != 1 { print }
    '
  )"

  {
    if [ -n "$cleaned" ]; then
      printf '%s\n' "$cleaned"
    fi
    printf '# OPENCLAW_COLLECTOR_CRON_BEGIN\n'
    printf 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n'
    printf '%s %s\n' "$OPENCLAW_COLLECTOR_CRON_SCHEDULE" "$cron_command"
    printf '# OPENCLAW_COLLECTOR_CRON_END\n'
  } | crontab -

  log "已安装 Tom collector cron：${OPENCLAW_COLLECTOR_CRON_SCHEDULE}"
  log "日志文件：${LOG_PATH}"
}

main "$@"
