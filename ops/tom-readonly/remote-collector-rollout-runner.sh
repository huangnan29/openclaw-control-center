#!/usr/bin/env bash
set -euo pipefail
set +x

# 跨服务器只读 collector 上线编排器。
# 它只串联现有安全脚本，并按 rollout gate 的当前阶段推进。
# step/run 必须显式提供确认令牌；缺凭据、预检失败、远端 collector 引导失败时会停住。
# 本脚本不会修改任何 OpenClaw 实例目录，不会重启实例，不会调用 managed-actions live API。
# safety: mutatesOpenClawInstance=false, restartsOpenClawInstance=false, callsLiveApi=false

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
BUNDLE_DIR="${BUNDLE_DIR:-${DEPLOY_DIR}/runtime/remote-onboarding/remote-oracle}"
MAX_STEPS="${MAX_STEPS:-8}"
CONFIRM_REMOTE_COLLECTOR_ROLLOUT_RUNNER="${CONFIRM_REMOTE_COLLECTOR_ROLLOUT_RUNNER:-}"

CONFIRM_TEXT="I_UNDERSTAND_THIS_RUNS_SAFE_REMOTE_COLLECTOR_ROLLOUT_STEPS"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

timestamp() {
  date +"%Y-%m-%dT%H:%M:%S%z"
}

log() {
  printf '[%s] %s\n' "$(timestamp)" "$*" >&2
}

fail() {
  printf '[失败] %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"
}

usage() {
  cat <<'TEXT'
用法：
  remote-collector-rollout-runner.sh status <bundle-dir>
  remote-collector-rollout-runner.sh plan <bundle-dir>
  remote-collector-rollout-runner.sh step <bundle-dir>
  remote-collector-rollout-runner.sh run <bundle-dir>

说明：
  status/plan 只调用 rollout gate 查看当前阶段，不写文件、不联网。
  step 执行当前阶段的一步，然后重新输出 rollout gate 状态。
  run 会循环执行已通过安全门禁的阶段，直到进入 ready_for_healthcheck、遇到缺凭据、远端 collector 引导失败或其他失败。

安全确认：
  step/run 必须设置：
    CONFIRM_REMOTE_COLLECTOR_ROLLOUT_RUNNER=I_UNDERSTAND_THIS_RUNS_SAFE_REMOTE_COLLECTOR_ROLLOUT_STEPS

可能执行的动作：
  - 刷新 onboarding bundle：只写 control-center runtime/onboarding。
  - 远端 preflight：只通过 SSH 执行只读检查，并写 Tom 本地 preflight 状态。
  - 远端 collector 节点同步：只把接入包复制到远端 collector deploy 目录。
  - 远端 collector bootstrap：只写 collector-only 部署文件，不启动 OpenClaw 实例。
  - 远端 collector snapshot：只启动/使用 collector-only 容器生成 snapshot。
  - 远端 collector cron：只安装当前用户 crontab 中的 collector 受控块。
  - 远端 snapshot pull：只通过 SSH cat 读取远端 collector JSON，并写 Tom 本地 runtime/collectors。
  - registry register：只备份并更新 Tom control-center config/instances.json。
  - healthcheck：只验证控制中心只读边界、页面和 collector 快照。

不会执行的动作：
  - 不写远端 OpenClaw 实例目录。
  - 不重启 OpenClaw 实例。
  - 不启动或重启 OpenClaw 实例容器。
  - 不启动 managed-actions live API。
  - 不绕过已有脚本的确认令牌和校验。
TEXT
}

json_get() {
  local field="$1"
  node -e '
const field = process.argv[1];
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => input += chunk);
process.stdin.on("end", () => {
  const data = JSON.parse(input);
  const value = field.split(".").reduce((current, key) => current == null ? undefined : current[key], data);
  if (value === undefined || value === null) process.exit(3);
  if (typeof value === "object") {
    process.stdout.write(`${JSON.stringify(value)}\n`);
  } else {
    process.stdout.write(`${String(value)}\n`);
  }
});
' "$field"
}

path_same() {
  local left="$1"
  local right="$2"
  node -e '
const path = require("node:path");
const left = path.resolve(process.argv[1]);
const right = path.resolve(process.argv[2]);
process.exit(left === right ? 0 : 1);
' "$left" "$right"
}

rollout_status() {
  local bundle="$1"
  DEPLOY_DIR="$DEPLOY_DIR" "$SCRIPT_DIR/remote-collector-rollout.sh" status "$bundle"
}

stage_from_status() {
  json_get "stage"
}

ensure_confirmed() {
  if [ "$CONFIRM_REMOTE_COLLECTOR_ROLLOUT_RUNNER" != "$CONFIRM_TEXT" ]; then
    fail "必须设置 CONFIRM_REMOTE_COLLECTOR_ROLLOUT_RUNNER=$CONFIRM_TEXT"
  fi
}

healthcheck_script() {
  if [ -x "$DEPLOY_DIR/healthcheck.sh" ]; then
    printf '%s\n' "$DEPLOY_DIR/healthcheck.sh"
  else
    printf '%s\n' "$SCRIPT_DIR/healthcheck.sh"
  fi
}

run_onboarding_refresh() {
  local bundle="$1"
  local credentials_config="${DEPLOY_DIR}/runtime/remote-collector-credentials.json"
  local onboarding_config="${DEPLOY_DIR}/runtime/remote-collector-onboarding.json"

  if [ -f "$credentials_config" ]; then
    log "发现 Tom 本地远端凭据配置，先安装到 control-center runtime。"
    DEPLOY_DIR="$DEPLOY_DIR" "$SCRIPT_DIR/remote-collector-credentials.sh" plan "$credentials_config"
    CONFIRM_REMOTE_COLLECTOR_CREDENTIALS=I_UNDERSTAND_THIS_ONLY_WRITES_CONTROL_CENTER_REMOTE_CREDENTIALS \
      DEPLOY_DIR="$DEPLOY_DIR" "$SCRIPT_DIR/remote-collector-credentials.sh" apply "$credentials_config"
  fi

  if [ ! -f "$onboarding_config" ]; then
    fail "缺少 ${onboarding_config}；请先用本机 push-remote-collector-credentials.sh 或 Tom 端 remote-collector-credentials.sh 准备真实远端凭据。"
  fi

  local plan_json
  plan_json="$(DEPLOY_DIR="$DEPLOY_DIR" "$SCRIPT_DIR/remote-collector-onboarding.sh" plan "$onboarding_config")"
  printf '%s\n' "$plan_json"
  local output_dir
  output_dir="$(printf '%s' "$plan_json" | json_get "outputDir")"
  if ! path_same "$output_dir" "$bundle"; then
    fail "onboarding outputDir 与当前 bundle-dir 不一致：outputDir=${output_dir} bundle=${bundle}"
  fi

  log "刷新远端 onboarding bundle。"
  CONFIRM_REMOTE_COLLECTOR_ONBOARDING=I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_ONBOARDING_BUNDLE \
    DEPLOY_DIR="$DEPLOY_DIR" "$SCRIPT_DIR/remote-collector-onboarding.sh" write "$onboarding_config"
  DEPLOY_DIR="$DEPLOY_DIR" "$SCRIPT_DIR/remote-collector-onboarding.sh" verify "$bundle"
}

run_preflight() {
  local bundle="$1"
  DEPLOY_DIR="$DEPLOY_DIR" "$SCRIPT_DIR/remote-collector-preflight.sh" plan "$bundle"
  CONFIRM_REMOTE_COLLECTOR_PREFLIGHT=I_UNDERSTAND_THIS_ONLY_READS_REMOTE_PREREQUISITES \
    DEPLOY_DIR="$DEPLOY_DIR" "$SCRIPT_DIR/remote-collector-preflight.sh" check "$bundle"
}

run_pull() {
  local bundle="$1"
  local config="${bundle}/remote-collector-pull.sources.json"
  DEPLOY_DIR="$DEPLOY_DIR" "$SCRIPT_DIR/remote-collector-pull.sh" plan "$config"
  CONFIRM_REMOTE_COLLECTOR_PULL=I_UNDERSTAND_THIS_ONLY_READS_REMOTE_COLLECTOR_SNAPSHOTS \
    DEPLOY_DIR="$DEPLOY_DIR" "$SCRIPT_DIR/remote-collector-pull.sh" pull "$config"
}

run_remote_collector_node() {
  local bundle="$1"
  log "同步远端 collector 接入包。"
  DEPLOY_DIR="$DEPLOY_DIR" "$SCRIPT_DIR/remote-collector-node-sync.sh" plan "$bundle"
  CONFIRM_REMOTE_COLLECTOR_NODE_SYNC=I_UNDERSTAND_THIS_ONLY_COPIES_COLLECTOR_BUNDLE_TO_REMOTE \
    DEPLOY_DIR="$DEPLOY_DIR" "$SCRIPT_DIR/remote-collector-node-sync.sh" sync "$bundle"

  log "执行远端 collector bootstrap plan。"
  CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_PLAN=I_UNDERSTAND_THIS_ONLY_RUNS_REMOTE_BOOTSTRAP_PLAN \
    DEPLOY_DIR="$DEPLOY_DIR" "$SCRIPT_DIR/remote-collector-node-sync.sh" bootstrap-plan "$bundle"

  log "写入远端 collector-only 部署文件。"
  CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_WRITE=I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_COLLECTOR_NODE_FILES \
    DEPLOY_DIR="$DEPLOY_DIR" "$SCRIPT_DIR/remote-collector-node-sync.sh" bootstrap-write "$bundle"

  log "生成远端 collector snapshot。"
  CONFIRM_REMOTE_COLLECTOR_NODE_SNAPSHOT=I_UNDERSTAND_THIS_RUNS_REMOTE_COLLECTOR_SNAPSHOT_ONLY \
    DEPLOY_DIR="$DEPLOY_DIR" "$SCRIPT_DIR/remote-collector-node-sync.sh" snapshot "$bundle"

  log "安装远端 collector cron。"
  CONFIRM_REMOTE_COLLECTOR_NODE_CRON=I_UNDERSTAND_THIS_ONLY_INSTALLS_REMOTE_COLLECTOR_CRON \
    DEPLOY_DIR="$DEPLOY_DIR" "$SCRIPT_DIR/remote-collector-node-sync.sh" install-cron "$bundle"
}

run_register() {
  local bundle="$1"
  local config="${bundle}/register-remote-collector.json"
  DEPLOY_DIR="$DEPLOY_DIR" "$SCRIPT_DIR/register-remote-collector.sh" plan "$config"
  CONFIRM_REMOTE_COLLECTOR_REGISTER=I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_REGISTRY \
    DEPLOY_DIR="$DEPLOY_DIR" "$SCRIPT_DIR/register-remote-collector.sh" apply "$config"
}

run_healthcheck() {
  local script
  script="$(healthcheck_script)"
  log "执行控制中心健康检查：${script}"
  DEPLOY_DIR="$DEPLOY_DIR" "$script"
}

run_stage() {
  local stage="$1"
  local bundle="$2"
  case "$stage" in
    needs_onboarding_verify)
      DEPLOY_DIR="$DEPLOY_DIR" "$SCRIPT_DIR/remote-collector-onboarding.sh" verify "$bundle"
      ;;
    needs_remote_credentials)
      run_onboarding_refresh "$bundle"
      ;;
    needs_remote_preflight)
      run_preflight "$bundle"
      ;;
    needs_remote_collector_pull)
      run_remote_collector_node "$bundle"
      run_pull "$bundle"
      ;;
    needs_registry_register)
      run_register "$bundle"
      ;;
    ready_for_healthcheck)
      run_healthcheck
      ;;
    *)
      fail "未知 rollout 阶段：${stage}"
      ;;
  esac
}

run_step() {
  local bundle="$1"
  local before
  before="$(rollout_status "$bundle")"
  local stage
  stage="$(printf '%s' "$before" | stage_from_status)"
  log "当前 rollout 阶段：${stage}"
  run_stage "$stage" "$bundle"
  rollout_status "$bundle"
}

run_all() {
  local bundle="$1"
  local previous_stage=""
  local index=1
  while [ "$index" -le "$MAX_STEPS" ]; do
    local before
    before="$(rollout_status "$bundle")"
    local stage
    stage="$(printf '%s' "$before" | stage_from_status)"
    log "第 ${index}/${MAX_STEPS} 步，当前 rollout 阶段：${stage}"
    run_stage "$stage" "$bundle"

    local after
    after="$(rollout_status "$bundle")"
    local next_stage
    next_stage="$(printf '%s' "$after" | stage_from_status)"
    printf '%s\n' "$after"

    if [ "$stage" = "ready_for_healthcheck" ]; then
      log "跨服务器只读接入已经到达 healthcheck 验收阶段。"
      return 0
    fi
    if [ "$next_stage" = "$stage" ] && [ "$previous_stage" = "$stage" ]; then
      fail "阶段连续两次没有推进，当前仍是 ${stage}。请查看上方输出处理阻塞。"
    fi
    previous_stage="$stage"
    index=$((index + 1))
  done
  fail "超过 MAX_STEPS=${MAX_STEPS}，为避免误循环已停止。"
}

main() {
  require_command node
  local mode="${1:-status}"
  local bundle="${2:-$BUNDLE_DIR}"
  case "$mode" in
    status|plan)
      rollout_status "$bundle"
      ;;
    step)
      ensure_confirmed
      run_step "$bundle"
      ;;
    run)
      ensure_confirmed
      run_all "$bundle"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage
      fail "未知命令：${mode}"
      ;;
  esac
}

main "$@"
