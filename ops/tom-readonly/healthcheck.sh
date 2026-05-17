#!/usr/bin/env bash
set -euo pipefail

# Tom 灰度控制中心健康检查：确认页面可读、写接口被挡住、容器边界仍然只读。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
CONTAINER_NAME="${CONTAINER_NAME:-openclaw-control-center-readonly}"
BASE_URL="${BASE_URL:-http://127.0.0.1:4311}"
INSTANCE_IDS="${INSTANCE_IDS:-main tom third deepseek spark}"
GATEWAY_PORTS="${GATEWAY_PORTS:-18789 18791 18793 18795 18797}"
INSTANCE_MOUNTS="${INSTANCE_MOUNTS:-/instances/main/config /instances/main/workspace /instances/tom/config /instances/tom/workspace /instances/third/config /instances/third/workspace /instances/deepseek/config /instances/deepseek/workspace /instances/spark/config /instances/spark/workspace}"
TMP_DIR=""

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

require_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  grep -Fq "$needle" "$file" || fail "${label} 未找到：${needle}"
}

cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}

check_http_pages() {
  local base="${BASE_URL%/}"
  TMP_DIR="$(mktemp -d)"

  log "检查多实例总览页面"
  curl -fsS "${base}/?section=overview&lang=zh" -o "${TMP_DIR}/overview.html"
  require_contains "${TMP_DIR}/overview.html" "多实例只读总览" "总览标题"
  require_contains "${TMP_DIR}/overview.html" "实例矩阵" "实例矩阵"
  require_contains "${TMP_DIR}/overview.html" "关注队列" "关注队列"
  require_contains "${TMP_DIR}/overview.html" "最近活动" "最近活动"

  local instance_id
  for instance_id in ${INSTANCE_IDS}; do
    log "检查实例详情页：${instance_id}"
    curl -fsS "${base}/?instance=${instance_id}&section=overview&lang=zh" -o "${TMP_DIR}/detail-${instance_id}.html"
    require_contains "${TMP_DIR}/detail-${instance_id}.html" "只读实例详情" "${instance_id} 详情标题"
    require_contains "${TMP_DIR}/detail-${instance_id}.html" "运行态分布" "${instance_id} 运行态分布"
    require_contains "${TMP_DIR}/detail-${instance_id}.html" "返回总览" "${instance_id} 返回总览"
  done

  log "检查写接口被只读闸门拦截"
  local write_code
  write_code="$(
    curl -sS -o "${TMP_DIR}/write-response.txt" -w "%{http_code}" \
      -X PATCH \
      -H "content-type: application/json" \
      --data '{"theme":"dark"}' \
      "${base}/api/ui/preferences"
  )"
  [ "$write_code" = "403" ] || fail "写接口期望返回 403，实际返回 ${write_code}"
  require_contains "${TMP_DIR}/write-response.txt" "只读" "写接口只读提示"
}

check_gateway_health() {
  local port
  for port in ${GATEWAY_PORTS}; do
    log "检查 OpenClaw gateway 健康端口：${port}"
    curl -fsS "http://127.0.0.1:${port}/health" | grep -Fq '"ok":true' || fail "gateway ${port} 未返回 ok=true"
  done
}

check_container_security() {
  log "检查控制中心容器安全边界"
  docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 || fail "找不到容器：${CONTAINER_NAME}"

  local privileged
  privileged="$(docker inspect -f '{{.HostConfig.Privileged}}' "$CONTAINER_NAME")"
  [ "$privileged" = "false" ] || fail "容器启用了 privileged"

  local port_binding
  port_binding="$(docker port "$CONTAINER_NAME" 4310/tcp 2>/dev/null || true)"
  printf '%s\n' "$port_binding" | grep -Fq "127.0.0.1:4311" || fail "控制中心端口没有绑定到 127.0.0.1:4311"

  local envs
  envs="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME")"
  printf '%s\n' "$envs" | grep -Fxq "READONLY_MODE=true" || fail "READONLY_MODE 未开启"
  printf '%s\n' "$envs" | grep -Fxq "APPROVAL_ACTIONS_ENABLED=false" || fail "审批写动作未禁用"
  printf '%s\n' "$envs" | grep -Fxq "IMPORT_MUTATION_ENABLED=false" || fail "导入写动作未禁用"
  printf '%s\n' "$envs" | grep -Fxq "TASK_HEARTBEAT_ENABLED=false" || fail "任务心跳写动作未禁用"
  printf '%s\n' "$envs" | grep -Fxq "HALL_RUNTIME_DISPATCH_ENABLED=false" || fail "Hall 派发未禁用"
  printf '%s\n' "$envs" | grep -Fxq "HALL_RUNTIME_DIRECT_STREAM_ENABLED=false" || fail "Hall 直连流未禁用"

  local mounts
  mounts="$(docker inspect -f '{{range .Mounts}}{{printf "%s|%s|%t\n" .Source .Destination .RW}}{{end}}' "$CONTAINER_NAME")"
  if printf '%s\n' "$mounts" | grep -Fq "/var/run/docker.sock"; then
    fail "容器挂载了 docker.sock"
  fi

  local mount_path
  for mount_path in ${INSTANCE_MOUNTS}; do
    local line
    line="$(printf '%s\n' "$mounts" | awk -F '|' -v target="$mount_path" '$2 == target { print }')"
    [ -n "$line" ] || fail "缺少实例只读挂载：${mount_path}"
    printf '%s\n' "$line" | grep -Fq "|false" || fail "实例挂载不是只读：${mount_path}"
  done

  local instances_line
  instances_line="$(printf '%s\n' "$mounts" | awk -F '|' '$2 == "/app/config/instances.json" { print }')"
  [ -n "$instances_line" ] || fail "缺少 instances.json 挂载"
  printf '%s\n' "$instances_line" | grep -Fq "|false" || fail "instances.json 挂载不是只读"
}

main() {
  trap cleanup EXIT

  require_command curl
  require_command docker

  [ -d "$DEPLOY_DIR" ] || fail "部署目录不存在：${DEPLOY_DIR}"

  check_gateway_health
  check_http_pages
  check_container_security

  log "健康检查通过：Tom 多实例只读控制中心可继续作为灰度监控入口。"
}

main "$@"
