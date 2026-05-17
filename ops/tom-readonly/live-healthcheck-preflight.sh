#!/usr/bin/env bash
set -euo pipefail
set +x

# 只读 preflight：检查 live healthcheck 演练条件是否齐备。
# 本脚本不会调用 managed-actions live 接口，也不会修改 OpenClaw 实例目录。

BASE_URL="${BASE_URL:-http://127.0.0.1:4311}"
CONTAINER_NAME="${CONTAINER_NAME:-openclaw-control-center-readonly}"
ROLLOUT_FILE="${ROLLOUT_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/managed-action-healthcheck-rollout.example.json}"
INSTANCE_ID="${INSTANCE_ID:-tom}"
OPERATOR="${OPERATOR:-Anan}"
EXPECT_LIVE_READY="${EXPECT_LIVE_READY:-false}"

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

warn() {
  printf '[提示] %s\n' "$*" >&2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"
}

json_field() {
  local field="$1"
  docker exec -i "$CONTAINER_NAME" node -e '
let s = "";
process.stdin.on("data", d => s += d);
process.stdin.on("end", () => {
  const body = JSON.parse(s);
  const path = process.argv[1].split(".");
  let value = body;
  for (const key of path) value = value?.[key];
  if (value === undefined || value === null) process.exit(2);
  if (Array.isArray(value) || (typeof value === "object")) {
    process.stdout.write(JSON.stringify(value));
    return;
  }
  process.stdout.write(String(value));
});
' "$field"
}

check_rollout_file() {
  log "检查 rollout 样板：${ROLLOUT_FILE}"
  [ -f "$ROLLOUT_FILE" ] || fail "rollout 文件不存在：${ROLLOUT_FILE}"
  docker exec -i "$CONTAINER_NAME" node -e '
let s = "";
process.stdin.on("data", d => s += d);
process.stdin.on("end", () => {
  const config = JSON.parse(s);
  if (config.enabled !== true) throw new Error("rollout.enabled 必须为 true");
  if (!Array.isArray(config.rules)) throw new Error("rollout.rules 必须为数组");
  const rule = config.rules.find((item) => {
    return item &&
      item.enabled !== false &&
      item.action === "healthcheck" &&
      item.instanceId === process.env.INSTANCE_ID &&
      (Array.isArray(item.operators) && (item.operators.includes(process.env.OPERATOR) || item.operators.includes("*"))) &&
      item.risk === "low";
  });
  if (!rule) {
    throw new Error(`未找到匹配 healthcheck rollout 规则：instance=${process.env.INSTANCE_ID} operator=${process.env.OPERATOR}`);
  }
  process.stdout.write(JSON.stringify({
    action: rule.action,
    instanceId: rule.instanceId,
    operators: rule.operators,
    risk: rule.risk,
    maxDryRunAgeMinutes: rule.maxDryRunAgeMinutes
  }));
});
' < "$ROLLOUT_FILE" || fail "rollout 样板校验失败"
  printf '\n'
}

check_container_live_flags() {
  log "检查容器 live 开关"
  local envs
  envs="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME")"

  local live_gate
  local live_executor
  local readonly_mode
  local allowed_actions
  live_gate="$(printf '%s\n' "$envs" | awk -F= '$1 == "MANAGED_ACTIONS_LIVE_ENABLED" { print $2 }' | tail -n 1)"
  live_executor="$(printf '%s\n' "$envs" | awk -F= '$1 == "MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED" { print $2 }' | tail -n 1)"
  readonly_mode="$(printf '%s\n' "$envs" | awk -F= '$1 == "READONLY_MODE" { print $2 }' | tail -n 1)"
  allowed_actions="$(printf '%s\n' "$envs" | awk -F= '$1 == "MANAGED_ACTIONS_LIVE_ALLOWED_ACTIONS" { print $2 }' | tail -n 1)"

  printf 'READONLY_MODE=%s\n' "${readonly_mode:-<unset>}"
  printf 'MANAGED_ACTIONS_LIVE_ENABLED=%s\n' "${live_gate:-<unset>}"
  printf 'MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED=%s\n' "${live_executor:-<unset>}"
  printf 'MANAGED_ACTIONS_LIVE_ALLOWED_ACTIONS=%s\n' "${allowed_actions:-<unset>}"

  if [ "$EXPECT_LIVE_READY" = "true" ]; then
    [ "$readonly_mode" = "false" ] || fail "EXPECT_LIVE_READY=true 时 READONLY_MODE 必须为 false"
    [ "$live_gate" = "true" ] || fail "EXPECT_LIVE_READY=true 时 MANAGED_ACTIONS_LIVE_ENABLED 必须为 true"
    [ "$live_executor" = "true" ] || fail "EXPECT_LIVE_READY=true 时 MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED 必须为 true"
    printf '%s' "$allowed_actions" | tr ',' '\n' | grep -Fxq "healthcheck" || fail "允许动作中缺少 healthcheck"
  fi
}

check_readiness() {
  log "读取 readiness"
  local readiness
  readiness="$(curl -fsS "${BASE_URL%/}/api/managed-actions/readiness")"
  local status
  local live_available
  local executor_wired
  status="$(printf '%s' "$readiness" | json_field "status")"
  live_available="$(printf '%s' "$readiness" | json_field "liveExecutionAvailable")"
  executor_wired="$(printf '%s' "$readiness" | json_field "executor.productionWired")"

  printf 'readiness.status=%s\n' "$status"
  printf 'readiness.liveExecutionAvailable=%s\n' "$live_available"
  printf 'readiness.executor.productionWired=%s\n' "$executor_wired"

  if [ "$EXPECT_LIVE_READY" = "true" ]; then
    [ "$status" = "ready" ] || fail "EXPECT_LIVE_READY=true 时 readiness.status 必须为 ready"
    [ "$live_available" = "true" ] || fail "EXPECT_LIVE_READY=true 时 liveExecutionAvailable 必须为 true"
    [ "$executor_wired" = "true" ] || fail "EXPECT_LIVE_READY=true 时 productionWired 必须为 true"
  else
    warn "当前为只读 preflight；EXPECT_LIVE_READY 未开启，不要求 readiness ready。"
  fi
}

main() {
  require_command curl
  require_command docker

  check_rollout_file
  check_container_live_flags
  check_readiness

  log "preflight 完成：未调用 live API。"
}

main "$@"
