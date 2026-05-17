#!/usr/bin/env bash
set -euo pipefail
set +x

# 本机侧第二台 Oracle 凭据接入编排器。
# plan 只渲染 push 配置摘要，不写文件、不联网。
# apply 必须显式确认，只写本机 push 配置，并通过 SSH 写 Tom control-center runtime。
# 本脚本不连接第二台 Oracle，不写 Tom registry，不修改任何 OpenClaw 实例目录，不调用 managed-actions live API。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DISCOVERY_SCRIPT="${DISCOVERY_SCRIPT:-${SCRIPT_DIR}/discover-remote-oracle-credentials.sh}"
PUSH_SCRIPT="${PUSH_SCRIPT:-${SCRIPT_DIR}/push-remote-collector-credentials.sh}"
DISCOVERY_CONFIG="${DISCOVERY_CONFIG:-${ROOT_DIR}/ops/local/discover-remote-oracle-credentials.example.json}"
PUSH_CONFIG_FILE="${PUSH_CONFIG_FILE:-${ROOT_DIR}/runtime/push-remote-collector-credentials.json}"
CONFIRM_REMOTE_ORACLE_INTAKE="${CONFIRM_REMOTE_ORACLE_INTAKE:-}"
REMOTE_ORACLE_INTAKE_OVERWRITE="${REMOTE_ORACLE_INTAKE_OVERWRITE:-false}"

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
  remote-oracle-intake.sh plan
  remote-oracle-intake.sh apply

必填环境变量：
  REMOTE_ORACLE_HOST=<真实第二台 Oracle 公网 IP 或域名>
  REMOTE_ORACLE_KEY_PATH=<本机只读 SSH key 绝对路径>

可选环境变量：
  REMOTE_ORACLE_USER=ubuntu
  REMOTE_ORACLE_PORT=22
  DISCOVERY_CONFIG=ops/local/discover-remote-oracle-credentials.example.json
  PUSH_CONFIG_FILE=runtime/push-remote-collector-credentials.json
  REMOTE_ORACLE_INTAKE_OVERWRITE=true

安全确认：
  apply 必须设置：
    CONFIRM_REMOTE_ORACLE_INTAKE=I_UNDERSTAND_THIS_WRITES_LOCAL_PUSH_CONFIG_AND_TOM_RUNTIME_ONLY

安全边界：
  plan 不写文件、不联网。
  apply 只写本机 push 配置和 Tom control-center runtime。
  apply 不连接第二台 Oracle、不写 registry、不修改任何 OpenClaw 实例目录、不调用 managed-actions live API。
TEXT
}

json_summary() {
  node <<'NODE'
const input = JSON.parse(process.env.INPUT_JSON || "{}");
const status = process.env.STATUS || "planned";
const mode = process.env.MODE || "plan";
const pushConfigFile = process.env.PUSH_CONFIG_FILE || "";
const report = {
  schemaVersion: 1,
  status,
  mode,
  generatedAt: new Date().toISOString(),
  pushConfigFile,
  target: {
    serverId: input.server?.id,
    serverName: input.server?.name,
    host: input.remote?.host || input.server?.host,
    user: input.remote?.user,
    port: input.remote?.port,
    sourceSshKeyPath: input.remote?.sourceSshKeyPath,
    targetSshKeyPath: input.remote?.targetSshKeyPath,
    onboardingConfigFile: input.outputConfigFile,
  },
  nextCommands: status === "planned" ? [
    "CONFIRM_REMOTE_ORACLE_INTAKE=I_UNDERSTAND_THIS_WRITES_LOCAL_PUSH_CONFIG_AND_TOM_RUNTIME_ONLY ops/local/remote-oracle-intake.sh apply",
  ] : [
    "CONFIRM_REMOTE_COLLECTOR_ROLLOUT_RUNNER=I_UNDERSTAND_THIS_RUNS_SAFE_REMOTE_COLLECTOR_ROLLOUT_STEPS repo/ops/tom-readonly/remote-collector-rollout-runner.sh run runtime/remote-onboarding/remote-oracle",
  ],
  safety: {
    writesLocalPushConfig: status === "applied",
    writesTomControlCenterRuntimeOnly: status === "applied",
    connectsTomSsh: status === "applied",
    connectsSecondOracle: false,
    writesRemoteCollectorNode: false,
    writesActiveRegistry: false,
    startsContainers: false,
    mutatesOpenClawInstance: false,
    restartsOpenClawInstance: false,
    callsLiveApi: false,
    outputsPrivateKeyContent: false,
  },
};
console.log(JSON.stringify(report, null, 2));
NODE
}

parse_apply_report() {
  WRITE_OUTPUT="$1" PLAN_OUTPUT="$2" APPLY_OUTPUT="$3" PUSH_CONFIG_FILE="$PUSH_CONFIG_FILE" node <<'NODE'
function parse(name) {
  try {
    return JSON.parse(process.env[name] || "{}");
  } catch (error) {
    return { status: "invalid_json", error: error instanceof Error ? error.message : String(error) };
  }
}
const write = parse("WRITE_OUTPUT");
const plan = parse("PLAN_OUTPUT");
const apply = parse("APPLY_OUTPUT");
const target = apply.remote || plan.remote || write.selected || {};
console.log(JSON.stringify({
  schemaVersion: 1,
  status: "applied",
  mode: "apply",
  generatedAt: new Date().toISOString(),
  pushConfigFile: process.env.PUSH_CONFIG_FILE,
  write,
  plan: {
    status: plan.status,
    serverId: plan.serverId,
    remote: plan.remote,
    outputConfigFile: plan.outputConfigFile,
    safety: plan.safety,
  },
  apply: {
    status: apply.status,
    serverId: apply.serverId,
    remote: apply.remote,
    outputConfigFile: apply.outputConfigFile,
    remoteResult: apply.remoteResult,
    safety: apply.safety,
  },
  target,
  nextCommands: [
    "CONFIRM_REMOTE_COLLECTOR_ROLLOUT_RUNNER=I_UNDERSTAND_THIS_RUNS_SAFE_REMOTE_COLLECTOR_ROLLOUT_STEPS repo/ops/tom-readonly/remote-collector-rollout-runner.sh run runtime/remote-onboarding/remote-oracle",
    "repo/ops/tom-readonly/go-live-gate.sh status runtime/remote-onboarding/remote-oracle",
  ],
  safety: {
    writesLocalPushConfig: true,
    writesTomControlCenterRuntimeOnly: true,
    connectsTomSsh: true,
    connectsSecondOracle: false,
    writesRemoteCollectorNode: false,
    writesActiveRegistry: false,
    startsContainers: false,
    mutatesOpenClawInstance: false,
    restartsOpenClawInstance: false,
    callsLiveApi: false,
    outputsPrivateKeyContent: false,
  },
}, null, 2));
NODE
}

render_push_config() {
  "$DISCOVERY_SCRIPT" render-push-config "$DISCOVERY_CONFIG"
}

write_push_config() {
  CONFIRM_REMOTE_ORACLE_PUSH_CONFIG_WRITE=I_UNDERSTAND_THIS_ONLY_WRITES_LOCAL_PUSH_CONFIG \
    REMOTE_ORACLE_PUSH_CONFIG_OUTPUT="$PUSH_CONFIG_FILE" \
    REMOTE_ORACLE_PUSH_CONFIG_OVERWRITE="$REMOTE_ORACLE_INTAKE_OVERWRITE" \
    "$DISCOVERY_SCRIPT" write-push-config "$DISCOVERY_CONFIG"
}

main() {
  require_command node
  [ -x "$DISCOVERY_SCRIPT" ] || fail "发现脚本不存在或不可执行：${DISCOVERY_SCRIPT}"
  [ -x "$PUSH_SCRIPT" ] || fail "推送脚本不存在或不可执行：${PUSH_SCRIPT}"

  case "${1:-plan}" in
    plan)
      local rendered
      rendered="$(render_push_config)"
      INPUT_JSON="$rendered" STATUS="planned" MODE="plan" PUSH_CONFIG_FILE="$PUSH_CONFIG_FILE" json_summary
      ;;
    apply)
      [ "$CONFIRM_REMOTE_ORACLE_INTAKE" = "I_UNDERSTAND_THIS_WRITES_LOCAL_PUSH_CONFIG_AND_TOM_RUNTIME_ONLY" ] || \
        fail "必须设置 CONFIRM_REMOTE_ORACLE_INTAKE=I_UNDERSTAND_THIS_WRITES_LOCAL_PUSH_CONFIG_AND_TOM_RUNTIME_ONLY"
      require_command ssh
      local write_output
      local plan_output
      local apply_output
      write_output="$(write_push_config)"
      plan_output="$("$PUSH_SCRIPT" plan "$PUSH_CONFIG_FILE")"
      apply_output="$(CONFIRM_PUSH_REMOTE_COLLECTOR_CREDENTIALS=I_UNDERSTAND_THIS_ONLY_PUSHES_REMOTE_COLLECTOR_CREDENTIALS_TO_TOM_RUNTIME "$PUSH_SCRIPT" apply "$PUSH_CONFIG_FILE")"
      parse_apply_report "$write_output" "$plan_output" "$apply_output"
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
