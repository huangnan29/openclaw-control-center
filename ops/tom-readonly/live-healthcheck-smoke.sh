#!/usr/bin/env bash
set -euo pipefail
set +x

# 手动灰度演练脚本：只调用已显式启用的 managed-action live healthcheck。
# 脚本不会修改 OpenClaw 实例目录；如果 live gate/executor/rollout 未启用，会直接失败。

BASE_URL="${BASE_URL:-http://127.0.0.1:4311}"
CONTAINER_NAME="${CONTAINER_NAME:-openclaw-control-center-readonly}"
INSTANCE_ID="${INSTANCE_ID:-tom}"
OPERATOR="${OPERATOR:-Anan}"
REASON="${REASON:-Tom readonly live healthcheck smoke}"
CONFIRM_LIVE_HEALTHCHECK="${CONFIRM_LIVE_HEALTHCHECK:-}"
LOCAL_API_TOKEN="${LOCAL_API_TOKEN:-}"

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

json_string() {
  docker exec -i "$CONTAINER_NAME" node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(s)));'
}

json_field() {
  local field="$1"
  docker exec -i "$CONTAINER_NAME" node -e '
let s="";
process.stdin.on("data", d => s += d);
process.stdin.on("end", () => {
  const body = JSON.parse(s);
  const path = process.argv[1].split(".");
  let value = body;
  for (const key of path) value = value?.[key];
  if (value === undefined || value === null) process.exit(2);
  process.stdout.write(String(value));
});
' "$field"
}

post_json() {
  local path="$1"
  local payload="$2"
  curl -fsS \
    -H "content-type: application/json" \
    -H "x-local-token: ${LOCAL_API_TOKEN}" \
    --data "$payload" \
    "${BASE_URL%/}${path}"
}

main() {
  require_command curl
  require_command docker

  [ "$CONFIRM_LIVE_HEALTHCHECK" = "I_UNDERSTAND_THIS_CALLS_LIVE_API" ] || fail "必须设置 CONFIRM_LIVE_HEALTHCHECK=I_UNDERSTAND_THIS_CALLS_LIVE_API"
  [ -n "$LOCAL_API_TOKEN" ] || fail "必须通过环境变量提供 LOCAL_API_TOKEN"

  log "检查 readiness 是否允许 live healthcheck"
  local readiness
  readiness="$(curl -fsS "${BASE_URL%/}/api/managed-actions/readiness")"
  local live_available
  live_available="$(printf '%s' "$readiness" | json_field "liveExecutionAvailable")"
  [ "$live_available" = "true" ] || fail "readiness 尚未允许 live execution；不会继续调用 live API"

  local instance_json
  local operator_json
  local reason_json
  instance_json="$(printf '%s' "$INSTANCE_ID" | json_string)"
  operator_json="$(printf '%s' "$OPERATOR" | json_string)"
  reason_json="$(printf '%s' "$REASON" | json_string)"

  log "提交 dry-run 申请：instance=${INSTANCE_ID} operator=${OPERATOR}"
  local dry_payload
  dry_payload="{\"instanceId\":${instance_json},\"action\":\"healthcheck\",\"operator\":${operator_json},\"reason\":${reason_json},\"confirmedText\":\"DRY-RUN-ONLY\"}"
  local dry_response
  dry_response="$(post_json "/api/managed-actions/dry-run" "$dry_payload")"
  local operation_request_id
  operation_request_id="$(printf '%s' "$dry_response" | json_field "review.operationRequestId")"

  log "调用 live healthcheck：operationRequestId=${operation_request_id}"
  local request_json
  request_json="$(printf '%s' "$operation_request_id" | json_string)"
  local live_payload
  live_payload="{\"instanceId\":${instance_json},\"action\":\"healthcheck\",\"operator\":${operator_json},\"reason\":${reason_json},\"operationRequestId\":${request_json},\"confirmedText\":\"LIVE-ACTION-APPROVED\"}"
  local live_response
  live_response="$(post_json "/api/managed-actions/live" "$live_payload")"

  local live_status
  local live_execution
  local mutates
  live_status="$(printf '%s' "$live_response" | json_field "status")"
  live_execution="$(printf '%s' "$live_response" | json_field "liveExecution")"
  mutates="$(printf '%s' "$live_response" | json_field "safety.mutatesOpenClawInstance")"

  [ "$live_status" = "executed_readonly_healthcheck" ] || fail "live healthcheck 状态异常：${live_status}"
  [ "$live_execution" = "true" ] || fail "liveExecution 未标记为 true"
  [ "$mutates" = "false" ] || fail "只读 healthcheck 不应修改 OpenClaw 实例"

  log "live healthcheck 演练通过：status=${live_status} mutatesOpenClawInstance=${mutates}"
}

main "$@"
