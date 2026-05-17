#!/usr/bin/env bash
set -euo pipefail

# Tom 本地 collector 快照导出：只读取容器内已只读挂载的实例数据，并写入控制中心 runtime。

CONTAINER_NAME="${CONTAINER_NAME:-openclaw-control-center-readonly}"
SERVER_ID="${SERVER_ID:-tom-oracle}"
OUTPUT_PATH="${OUTPUT_PATH:-/app/runtime/collectors/${SERVER_ID}/snapshot.json}"

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

main() {
  command -v docker >/dev/null 2>&1 || fail "缺少命令：docker"
  docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 || fail "找不到容器：${CONTAINER_NAME}"

  log "生成 collector 快照：server=${SERVER_ID} output=${OUTPUT_PATH}"
  docker exec \
    -e OPENCLAW_COLLECTOR_SERVER_ID="$SERVER_ID" \
    "$CONTAINER_NAME" \
    node dist/index.js collector-snapshot "$OUTPUT_PATH"

  docker exec "$CONTAINER_NAME" test -s "$OUTPUT_PATH" || fail "collector 快照文件为空或不存在：${OUTPUT_PATH}"
  docker exec "$CONTAINER_NAME" node -e "const fs=require('fs'); const s=JSON.parse(fs.readFileSync(process.argv[1], 'utf8')); if (!Array.isArray(s.instances) || s.instances.length === 0) process.exit(2); console.log(JSON.stringify({serverId:s.serverId, instances:s.instances.length, generatedAt:s.generatedAt}))" "$OUTPUT_PATH"

  log "collector 快照已生成。"
}

main "$@"
