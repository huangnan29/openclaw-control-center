#!/usr/bin/env bash
set -euo pipefail

# Tom 灰度控制中心回滚脚本：切回指定提交并重建控制中心，不触碰 OpenClaw 实例数据。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
SERVICE_NAME="${SERVICE_NAME:-control-center}"
STATE_DIR="${STATE_DIR:-${DEPLOY_DIR}/runtime/deploy-state}"

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

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    fail "缺少 docker compose 或 docker-compose"
  fi
}

ensure_clean_repo() {
  local repo_dir="$1"
  git -C "$repo_dir" diff --quiet || fail "repo 存在未提交改动，停止回滚：${repo_dir}"
  git -C "$repo_dir" diff --cached --quiet || fail "repo 存在暂存改动，停止回滚：${repo_dir}"
}

sync_deploy_scripts() {
  local repo_dir="$1"
  local healthcheck="$2"
  local source_healthcheck="${repo_dir}/ops/tom-readonly/healthcheck.sh"

  [ -f "$source_healthcheck" ] || fail "找不到仓库健康检查脚本：${source_healthcheck}"
  install -m 0755 "$source_healthcheck" "$healthcheck"
  log "已同步健康检查脚本：${healthcheck}"
}

resolve_target_commit() {
  local requested="${1:-}"
  if [ -n "$requested" ]; then
    printf '%s\n' "$requested"
    return
  fi

  local previous_file="${STATE_DIR}/previous-good.commit"
  [ -f "$previous_file" ] || fail "未提供回滚提交，且没有找到 ${previous_file}"
  sed -n '1p' "$previous_file"
}

main() {
  local repo_dir="${DEPLOY_DIR}/repo"
  local healthcheck="${DEPLOY_DIR}/healthcheck.sh"
  local target_commit
  target_commit="$(resolve_target_commit "${1:-}")"

  [ -d "$repo_dir/.git" ] || fail "找不到部署仓库：${repo_dir}"
  [ -n "$target_commit" ] || fail "回滚提交为空"
  ensure_clean_repo "$repo_dir"

  log "准备回滚到提交：${target_commit}"
  git -C "$repo_dir" fetch --all --prune
  git -C "$repo_dir" checkout --detach "$target_commit"

  sync_deploy_scripts "$repo_dir" "$healthcheck"

  log "重新构建并启动控制中心容器"
  cd "$DEPLOY_DIR"
  compose up -d --build "$SERVICE_NAME"

  [ -x "$healthcheck" ] || fail "健康检查脚本不存在或不可执行：${healthcheck}"
  "$healthcheck"

  printf '%s\n' "$target_commit" > "${STATE_DIR}/last-good.commit"
  log "回滚完成。后续再次更新时，update.sh 会切回配置的分支。"
}

main "$@"
