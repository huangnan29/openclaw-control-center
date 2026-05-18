#!/usr/bin/env bash
set -euo pipefail

# Tom 灰度控制中心更新脚本：只更新控制中心自身，不修改任何 OpenClaw 实例目录。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
BRANCH="${BRANCH:-multi-instance-readonly-control-center}"
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
  git -C "$repo_dir" diff --quiet || fail "repo 存在未提交改动，停止更新：${repo_dir}"
  git -C "$repo_dir" diff --cached --quiet || fail "repo 存在暂存改动，停止更新：${repo_dir}"
}

sync_deploy_scripts() {
  local repo_dir="$1"
  local healthcheck="$2"
  local source_healthcheck="${repo_dir}/ops/tom-readonly/healthcheck.sh"

  [ -f "$source_healthcheck" ] || fail "找不到仓库健康检查脚本：${source_healthcheck}"
  install -m 0755 "$source_healthcheck" "$healthcheck"
  log "已同步健康检查脚本：${healthcheck}"
}

main() {
  local repo_dir="${DEPLOY_DIR}/repo"
  local healthcheck="${DEPLOY_DIR}/healthcheck.sh"

  [ -d "$repo_dir/.git" ] || fail "找不到部署仓库：${repo_dir}"
  [ -f "${DEPLOY_DIR}/docker-compose.yml" ] || fail "找不到 docker-compose.yml：${DEPLOY_DIR}"

  mkdir -p "$STATE_DIR"
  ensure_clean_repo "$repo_dir"

  local before_commit
  before_commit="$(git -C "$repo_dir" rev-parse HEAD)"
  printf '%s\n' "$before_commit" > "${STATE_DIR}/previous-good.commit"
  log "当前提交：${before_commit}"

  log "拉取远端分支：origin/${BRANCH}"
  git -C "$repo_dir" fetch --prune origin "+refs/heads/${BRANCH}:refs/remotes/origin/${BRANCH}"
  git -C "$repo_dir" checkout "$BRANCH"
  git -C "$repo_dir" merge --ff-only "origin/${BRANCH}"

  local after_commit
  after_commit="$(git -C "$repo_dir" rev-parse HEAD)"
  log "更新后提交：${after_commit}"

  sync_deploy_scripts "$repo_dir" "$healthcheck"

  log "重新构建并启动控制中心容器"
  cd "$DEPLOY_DIR"
  compose up -d --build "$SERVICE_NAME"

  [ -x "$healthcheck" ] || fail "健康检查脚本不存在或不可执行：${healthcheck}"
  "$healthcheck"

  printf '%s\n' "$after_commit" > "${STATE_DIR}/last-good.commit"
  log "更新完成。上一个可回滚提交已记录在 ${STATE_DIR}/previous-good.commit"
}

main "$@"
