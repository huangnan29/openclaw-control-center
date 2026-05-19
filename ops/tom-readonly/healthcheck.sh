#!/usr/bin/env bash
set -euo pipefail

# Tom 灰度控制中心健康检查：确认页面可读、危险写入口仍被挡住，或仅开放受控 live action 白名单。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
CONTAINER_NAME="${CONTAINER_NAME:-openclaw-control-center-readonly}"
BASE_URL="${BASE_URL:-http://127.0.0.1:4311}"
INSTANCE_IDS="${INSTANCE_IDS:-main tom third deepseek spark}"
GATEWAY_PORTS="${GATEWAY_PORTS:-18789 18791 18793 18795 18797}"
GATEWAY_CONTAINERS="${GATEWAY_CONTAINERS:-openclaw-openclaw-gateway-1 openclaw-work-openclaw-gateway-1 openclaw-third-openclaw-gateway-1 openclaw-deepseek-openclaw-gateway-1 openclaw-spark-openclaw-gateway-1}"
INSTANCE_MOUNTS="${INSTANCE_MOUNTS:-/instances/main/config /instances/main/workspace /instances/tom/config /instances/tom/workspace /instances/third/config /instances/third/workspace /instances/deepseek/config /instances/deepseek/workspace /instances/spark/config /instances/spark/workspace}"
INSTANCE_RW_MOUNTS_ALLOWED="${INSTANCE_RW_MOUNTS_ALLOWED:-/instances/tom/config /instances/tom/workspace}"
COLLECTOR_SNAPSHOT_MAX_AGE_SECONDS="${COLLECTOR_SNAPSHOT_MAX_AGE_SECONDS:-300}"
HTTP_RETRY_COUNT="${HTTP_RETRY_COUNT:-20}"
HTTP_RETRY_DELAY_SECONDS="${HTTP_RETRY_DELAY_SECONDS:-1}"
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

curl_to_file() {
  local url="$1"
  local output_file="$2"
  local label="$3"
  local attempt=1

  while true; do
    if curl -fsS "$url" -o "$output_file"; then
      return 0
    fi

    if [ "$attempt" -ge "$HTTP_RETRY_COUNT" ]; then
      fail "${label} 在 ${HTTP_RETRY_COUNT} 次重试后仍不可用：${url}"
    fi

    log "${label} 暂不可用，${HTTP_RETRY_DELAY_SECONDS}s 后重试（${attempt}/${HTTP_RETRY_COUNT}）"
    sleep "$HTTP_RETRY_DELAY_SECONDS"
    attempt=$((attempt + 1))
  done
}

cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}

check_http_pages() {
  local base="${BASE_URL%/}"

  log "检查多实例总览页面"
  curl_to_file "${base}/?section=overview&lang=zh" "${TMP_DIR}/overview.html" "多实例总览页面"
  require_contains "${TMP_DIR}/overview.html" "多实例只读总览" "总览标题"
  require_contains "${TMP_DIR}/overview.html" "服务器健康" "服务器健康"
  require_contains "${TMP_DIR}/overview.html" "实例矩阵" "实例矩阵"
  require_contains "${TMP_DIR}/overview.html" "关注队列" "关注队列"
  require_contains "${TMP_DIR}/overview.html" "最近活动" "最近活动"

  local instance_id
  for instance_id in ${INSTANCE_IDS}; do
    log "检查实例详情页：${instance_id}"
    curl_to_file "${base}/?instance=${instance_id}&section=overview&lang=zh" "${TMP_DIR}/detail-${instance_id}.html" "${instance_id} 实例详情页"
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
  local container
  for container in ${GATEWAY_CONTAINERS}; do
    log "检查 OpenClaw gateway 容器健康状态：${container}"
    docker inspect "$container" >/dev/null 2>&1 || fail "找不到 gateway 容器：${container}"

    local status
    local health
    local restart_count
    status="$(docker inspect -f '{{.State.Status}}' "$container")"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container")"
    restart_count="$(docker inspect -f '{{.RestartCount}}' "$container")"

    [ "$status" = "running" ] || fail "gateway 容器未运行：${container} status=${status} restartCount=${restart_count}"
    [ "$health" = "healthy" ] || fail "gateway 容器健康状态不是 healthy：${container} health=${health} restartCount=${restart_count}"
  done

  local port
  for port in ${GATEWAY_PORTS}; do
    log "检查 OpenClaw gateway 健康端口：${port}"
    curl_to_file "http://127.0.0.1:${port}/health" "${TMP_DIR}/gateway-${port}.json" "gateway ${port}"
    grep -Fq '"ok":true' "${TMP_DIR}/gateway-${port}.json" || fail "gateway ${port} 未返回 ok=true"
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
  local readonly_mode
  readonly_mode="true"
  if printf '%s\n' "$envs" | grep -Fxq "READONLY_MODE=false"; then
    readonly_mode="false"
  fi
  if [ "$readonly_mode" = "true" ]; then
    if printf '%s\n' "$envs" | grep -Fxq "MANAGED_ACTIONS_LIVE_ENABLED=true"; then
      fail "只读模式下管理动作 live gate 被启用"
    fi
    if printf '%s\n' "$envs" | grep -Fxq "MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED=true"; then
      fail "只读模式下管理动作生产执行器被挂载"
    fi
  else
    printf '%s\n' "$envs" | grep -Fxq "MANAGED_ACTIONS_LIVE_ENABLED=true" || fail "受控 live 模式下 MANAGED_ACTIONS_LIVE_ENABLED 未开启"
    printf '%s\n' "$envs" | grep -Fxq "MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED=true" || fail "受控 live 模式下生产执行器未开启"
    printf '%s\n' "$envs" | grep -Eq '^MANAGED_ACTIONS_LIVE_ALLOWED_ACTIONS=(healthcheck|collector_refresh|skill_run|,)+$' || fail "受控 live 动作白名单缺失或包含未知动作"
  fi
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
    [ -n "$line" ] || fail "缺少实例挂载：${mount_path}"
    if printf '%s\n' "$line" | grep -Fq "|true"; then
      printf ' %s ' "$INSTANCE_RW_MOUNTS_ALLOWED" | grep -Fq " ${mount_path} " || fail "实例挂载被意外改成可写：${mount_path}"
    fi
  done

  local instances_line
  instances_line="$(printf '%s\n' "$mounts" | awk -F '|' '$2 == "/app/config/instances.json" { print }')"
  [ -n "$instances_line" ] || fail "缺少 instances.json 挂载"
  printf '%s\n' "$instances_line" | grep -Fq "|false" || fail "instances.json 挂载不是只读"
}

check_collector_snapshot_freshness() {
  log "检查 collector 快照新鲜度"
  docker exec -i \
    -e COLLECTOR_SNAPSHOT_MAX_AGE_SECONDS="$COLLECTOR_SNAPSHOT_MAX_AGE_SECONDS" \
    "$CONTAINER_NAME" \
    node <<'NODE' || fail "collector 快照新鲜度检查失败"
const fs = require("fs");

const configPath = "/app/config/instances.json";
const maxAgeSeconds = Number(process.env.COLLECTOR_SNAPSHOT_MAX_AGE_SECONDS || "300");
if (!Number.isFinite(maxAgeSeconds) || maxAgeSeconds <= 0) {
  console.error(`COLLECTOR_SNAPSHOT_MAX_AGE_SECONDS 非法：${process.env.COLLECTOR_SNAPSHOT_MAX_AGE_SECONDS}`);
  process.exit(2);
}

let config;
try {
  config = JSON.parse(fs.readFileSync(configPath, "utf8"));
} catch (error) {
  console.error(`无法读取 instances registry：${configPath}`);
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(2);
}

const servers = Array.isArray(config.servers) ? config.servers : [];
const targets = servers.filter((server) => {
  return server && typeof server.collectorSnapshotPath === "string" && server.collectorSnapshotPath.trim() !== "";
});

if (targets.length === 0) {
  console.log("未配置 collectorSnapshotPath，跳过 collector 快照新鲜度检查。");
  process.exit(0);
}

let failed = false;
const now = Date.now();
for (const server of targets) {
  const serverId = typeof server.id === "string" && server.id.trim() ? server.id.trim() : "unknown-server";
  const snapshotPath = server.collectorSnapshotPath.trim();

  try {
    const snapshot = JSON.parse(fs.readFileSync(snapshotPath, "utf8"));
    const generatedAtMs = Date.parse(String(snapshot.generatedAt || ""));
    const instances = Array.isArray(snapshot.instances) ? snapshot.instances : [];
    if (!Number.isFinite(generatedAtMs)) {
      throw new Error(`generatedAt 非法：${snapshot.generatedAt}`);
    }
    if (instances.length === 0) {
      throw new Error("instances 为空");
    }

    const ageSeconds = Math.max(0, Math.round((now - generatedAtMs) / 1000));
    if (ageSeconds > maxAgeSeconds) {
      throw new Error(`快照已过期：age=${ageSeconds}s max=${maxAgeSeconds}s`);
    }

    console.log(`collector 快照正常：server=${serverId} age=${ageSeconds}s instances=${instances.length}`);
  } catch (error) {
    failed = true;
    console.error(`collector 快照异常：server=${serverId} path=${snapshotPath}`);
    console.error(error instanceof Error ? error.message : String(error));
  }
}

if (failed) {
  process.exit(2);
}
NODE
}

main() {
  trap cleanup EXIT
  TMP_DIR="$(mktemp -d)"

  require_command curl
  require_command docker

  [ -d "$DEPLOY_DIR" ] || fail "部署目录不存在：${DEPLOY_DIR}"

  check_gateway_health
  check_http_pages
  check_container_security
  check_collector_snapshot_freshness

  log "健康检查通过：Tom 多实例只读控制中心可继续作为灰度监控入口。"
}

main "$@"
