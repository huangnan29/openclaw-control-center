#!/usr/bin/env bash
set -euo pipefail
set +x

# 本机侧第二台 Oracle 凭据接入编排器。
# plan 只渲染 push 配置摘要，不写文件、不联网。
# doctor 只读取本机候选 SSH 配置并输出缺口报告，不写文件、不联网。
# apply 必须显式确认，只写本机 push 配置，并通过 SSH 写 Tom control-center runtime。
# run 额外显式确认后，会在 apply 后触发 Tom 端跨服务器只读 rollout runner。
# 本脚本不会修改任何 OpenClaw 实例目录，不调用 managed-actions live API。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DISCOVERY_SCRIPT="${DISCOVERY_SCRIPT:-${SCRIPT_DIR}/discover-remote-oracle-credentials.sh}"
PUSH_SCRIPT="${PUSH_SCRIPT:-${SCRIPT_DIR}/push-remote-collector-credentials.sh}"
DISCOVERY_CONFIG="${DISCOVERY_CONFIG:-${ROOT_DIR}/ops/local/discover-remote-oracle-credentials.example.json}"
PUSH_CONFIG_FILE="${PUSH_CONFIG_FILE:-${ROOT_DIR}/runtime/push-remote-collector-credentials.json}"
CONFIRM_REMOTE_ORACLE_INTAKE="${CONFIRM_REMOTE_ORACLE_INTAKE:-}"
CONFIRM_REMOTE_ORACLE_INTAKE_RUNNER="${CONFIRM_REMOTE_ORACLE_INTAKE_RUNNER:-}"
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
  remote-oracle-intake.sh doctor
  remote-oracle-intake.sh plan
  remote-oracle-intake.sh apply
  remote-oracle-intake.sh run

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
  run 还必须设置：
    CONFIRM_REMOTE_ORACLE_INTAKE_RUNNER=I_UNDERSTAND_THIS_PUSHES_CREDENTIALS_AND_RUNS_TOM_SAFE_ROLLOUT

安全边界：
  doctor 不写文件、不联网，只读取本机 SSH config、host hint 和 key 文件元数据。
  plan 不写文件、不联网。
  apply 只写本机 push 配置和 Tom control-center runtime。
  apply 不连接第二台 Oracle、不写 registry、不修改任何 OpenClaw 实例目录、不调用 managed-actions live API。
  run 会通过 Tom 端 rollout runner 自动推进已满足安全门禁的阶段；它可能只读连接第二台 Oracle、写 Tom control-center registry，但不会写 OpenClaw 实例目录。
TEXT
}

doctor_report() {
  SCAN_OUTPUT="$1" RENDER_OUTPUT="${2:-}" RENDER_STATUS="${3:-skipped}" PUSH_CONFIG_FILE="$PUSH_CONFIG_FILE" node <<'NODE'
function parse(name) {
  try {
    return JSON.parse(process.env[name] || "{}");
  } catch (error) {
    return { status: "invalid_json", error: error instanceof Error ? error.message : String(error) };
  }
}

function readString(value) {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : undefined;
}

const scan = parse("SCAN_OUTPUT");
const render = parse("RENDER_OUTPUT");
const renderStatus = process.env.RENDER_STATUS || "skipped";
const hostFromEnv = readString(process.env.REMOTE_ORACLE_HOST);
const keyFromEnv = readString(process.env.REMOTE_ORACLE_KEY_PATH);
const userFromEnv = readString(process.env.REMOTE_ORACLE_USER) || "ubuntu";
const portFromEnv = readString(process.env.REMOTE_ORACLE_PORT) || "22";
const keys = Array.isArray(scan.keys) ? scan.keys : [];
const hosts = Array.isArray(scan.hosts) ? scan.hosts : [];
const probes = Array.isArray(scan.probes) ? scan.probes : [];
const reachable = probes.filter((item) => item && item.status === "reachable");

let status = "needs_remote_host";
if (hostFromEnv && keyFromEnv && renderStatus === "rendered") {
  status = "ready_for_apply";
} else if (hostFromEnv && !keyFromEnv) {
  status = "needs_remote_key";
} else if (!hostFromEnv && keyFromEnv) {
  status = "needs_remote_host";
} else if (reachable.length > 0) {
  status = "reachable_candidate_found";
} else if (hosts.length > 0 && keys.length > 0) {
  status = "candidates_found";
} else if (keys.length === 0) {
  status = "needs_remote_host_and_key";
}

const selected = renderStatus === "rendered" ? {
  host: render.remote?.host || render.server?.host || hostFromEnv,
  user: render.remote?.user || userFromEnv,
  port: render.remote?.port || Number.parseInt(portFromEnv, 10),
  sourceSshKeyPath: render.remote?.sourceSshKeyPath || keyFromEnv,
  targetSshKeyPath: render.remote?.targetSshKeyPath,
  outputConfigFile: render.outputConfigFile,
} : {
  host: hostFromEnv,
  user: userFromEnv,
  port: Number.parseInt(portFromEnv, 10),
  sourceSshKeyPath: keyFromEnv,
};

const firstReachable = reachable[0];
const firstHost = hosts[0];
const firstKey = keys[0];
const suggestedHost = firstReachable?.host || firstHost?.host || "<真实第二台Oracle公网IP>";
const suggestedKey = firstReachable?.keyPath || (keys.length === 1 ? firstKey?.path : undefined) || "<本机只读key路径>";

const nextCommands = status === "ready_for_apply" ? [
  "ops/local/remote-oracle-intake.sh plan",
  "CONFIRM_REMOTE_ORACLE_INTAKE=I_UNDERSTAND_THIS_WRITES_LOCAL_PUSH_CONFIG_AND_TOM_RUNTIME_ONLY ops/local/remote-oracle-intake.sh apply",
  "CONFIRM_REMOTE_ORACLE_INTAKE=I_UNDERSTAND_THIS_WRITES_LOCAL_PUSH_CONFIG_AND_TOM_RUNTIME_ONLY CONFIRM_REMOTE_ORACLE_INTAKE_RUNNER=I_UNDERSTAND_THIS_PUSHES_CREDENTIALS_AND_RUNS_TOM_SAFE_ROLLOUT ops/local/remote-oracle-intake.sh run",
] : [
  `REMOTE_ORACLE_HOST=${suggestedHost} REMOTE_ORACLE_KEY_PATH=${suggestedKey} ops/local/remote-oracle-intake.sh doctor`,
  `REMOTE_ORACLE_HOST=${suggestedHost} REMOTE_ORACLE_KEY_PATH=${suggestedKey} ops/local/remote-oracle-intake.sh plan`,
];

console.log(JSON.stringify({
  schemaVersion: 1,
  status,
  mode: "doctor",
  generatedAt: new Date().toISOString(),
  pushConfigFile: process.env.PUSH_CONFIG_FILE || "",
  selected,
  discovery: {
    status: scan.status,
    summary: scan.summary,
    hosts: hosts.map((item) => ({
      host: item.host,
      user: item.user,
      port: item.port,
      sources: item.sources,
    })),
    keys: keys.map((item) => ({
      path: item.path,
      exists: item.exists,
      mode: item.mode,
      tooOpen: item.tooOpen,
      sizeBytes: item.sizeBytes,
      sources: item.sources,
    })),
    reachable: reachable.map((item) => ({
      host: item.host,
      user: item.user,
      port: item.port,
      keyPath: item.keyPath,
      detail: item.detail,
    })),
  },
  render: renderStatus === "rendered" ? {
    status: "rendered",
    serverId: render.server?.id,
    remote: {
      host: render.remote?.host,
      user: render.remote?.user,
      port: render.remote?.port,
      sourceSshKeyPath: render.remote?.sourceSshKeyPath,
      targetSshKeyPath: render.remote?.targetSshKeyPath,
    },
    outputConfigFile: render.outputConfigFile,
  } : {
    status: renderStatus,
  },
  missing: {
    remoteHost: !hostFromEnv,
    remoteKeyPath: !keyFromEnv,
  },
  nextCommands,
  safety: {
    readsLocalSshConfigOnly: true,
    connectsSsh: false,
    writesLocalFiles: false,
    writesTomRuntime: false,
    connectsTomSsh: false,
    connectsSecondOracle: false,
    writesRemoteFiles: false,
    writesActiveRegistry: false,
    writesOpenClawInstanceDirs: false,
    startsContainers: false,
    mutatesOpenClawInstance: false,
    restartsOpenClawInstance: false,
    callsLiveApi: false,
    outputsPrivateKeyContent: false,
  },
}, null, 2));
NODE
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

parse_run_report() {
  APPLY_REPORT="$1" RUNNER_REPORT="$2" PUSH_CONFIG_FILE="$PUSH_CONFIG_FILE" node <<'NODE'
function parse(name) {
  try {
    return JSON.parse(process.env[name] || "{}");
  } catch (error) {
    return { status: "invalid_json", error: error instanceof Error ? error.message : String(error) };
  }
}
const apply = parse("APPLY_REPORT");
const runner = parse("RUNNER_REPORT");
console.log(JSON.stringify({
  schemaVersion: 1,
  status: runner.exitCode === 0 ? "ran_rollout_runner" : "blocked_after_intake",
  mode: "run",
  generatedAt: new Date().toISOString(),
  pushConfigFile: process.env.PUSH_CONFIG_FILE,
  apply,
  rolloutRunner: runner,
  nextCommands: [
    "repo/ops/tom-readonly/go-live-gate.sh status runtime/remote-onboarding/remote-oracle",
    "repo/ops/tom-readonly/go-live-gate.sh check runtime/remote-onboarding/remote-oracle",
  ],
  safety: {
    writesLocalPushConfig: true,
    writesTomControlCenterRuntime: true,
    mayUpdateTomControlCenterRegistry: true,
    connectsTomSsh: true,
    mayConnectSecondOracleViaTomReadonlyPreflight: true,
    writesRemoteCollectorNode: false,
    writesOpenClawInstanceDirs: false,
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

run_apply_flow() {
  local write_output
  local plan_output
  local apply_output
  write_output="$(write_push_config)"
  plan_output="$("$PUSH_SCRIPT" plan "$PUSH_CONFIG_FILE")"
  apply_output="$(CONFIRM_PUSH_REMOTE_COLLECTOR_CREDENTIALS=I_UNDERSTAND_THIS_ONLY_PUSHES_REMOTE_COLLECTOR_CREDENTIALS_TO_TOM_RUNTIME "$PUSH_SCRIPT" apply "$PUSH_CONFIG_FILE")"
  parse_apply_report "$write_output" "$plan_output" "$apply_output"
}

run_tom_rollout_runner() {
  PUSH_CONFIG_FILE="$PUSH_CONFIG_FILE" node <<'NODE'
const fs = require("node:fs");
const { spawnSync } = require("node:child_process");

function fail(message) {
  console.error(`[失败] ${message}`);
  process.exit(2);
}

function asRecord(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : undefined;
}

function readString(value, fallback = "") {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : fallback;
}

function readPort(value, fallback) {
  const parsed = Number.parseInt(String(value ?? fallback), 10);
  if (!Number.isFinite(parsed) || parsed < 1 || parsed > 65535) fail("tom.port 必须在 1-65535 之间");
  return parsed;
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

const configFile = process.env.PUSH_CONFIG_FILE;
if (!configFile) fail("PUSH_CONFIG_FILE 必须填写");
let config;
try {
  config = JSON.parse(fs.readFileSync(configFile, "utf8"));
} catch (error) {
  fail(`无法读取 push 配置：${error instanceof Error ? error.message : String(error)}`);
}

const tom = asRecord(config.tom) || {};
const server = asRecord(config.server) || {};
const host = readString(tom.host);
if (!host) fail("tom.host 必须填写");
const user = readString(tom.user, "ubuntu");
const port = readPort(tom.port, 22);
const deployDir = readString(tom.deployDir, "/srv/openclaw-control-center-readonly");
const serverId = readString(server.id, "remote-oracle");
const strictHostKeyChecking = readString(tom.strictHostKeyChecking, "accept-new");
const connectTimeoutSeconds = readPort(tom.connectTimeoutSeconds, 15);
const sshKey = readString(tom.sshKey);
const knownHostsFile = readString(tom.knownHostsFile);
const bundlePath = `runtime/remote-onboarding/${serverId}`;
const remoteCommand = [
  `cd ${shellQuote(deployDir)}`,
  `CONFIRM_REMOTE_COLLECTOR_ROLLOUT_RUNNER=I_UNDERSTAND_THIS_RUNS_SAFE_REMOTE_COLLECTOR_ROLLOUT_STEPS repo/ops/tom-readonly/remote-collector-rollout-runner.sh run ${shellQuote(bundlePath)}`,
  `repo/ops/tom-readonly/go-live-gate.sh status ${shellQuote(bundlePath)}`,
].join(" && ");

const args = [
  "-p",
  String(port),
  "-o",
  "BatchMode=yes",
  "-o",
  `ConnectTimeout=${connectTimeoutSeconds}`,
  "-o",
  `StrictHostKeyChecking=${strictHostKeyChecking}`,
];
if (knownHostsFile) args.push("-o", `UserKnownHostsFile=${knownHostsFile}`);
if (sshKey) args.push("-i", sshKey);
args.push(`${user}@${host}`, remoteCommand);

const result = spawnSync("ssh", args, {
  encoding: "utf8",
  maxBuffer: 20 * 1024 * 1024,
});

function compact(text) {
  return String(text || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, 120);
}

console.log(JSON.stringify({
  status: result.status === 0 ? "completed" : "failed",
  exitCode: typeof result.status === "number" ? result.status : 1,
  target: {
    host,
    user,
    port,
    deployDir,
    serverId,
    bundlePath,
  },
  commandPreview: [
    `ssh ${user}@${host} <tom rollout runner>`,
  ],
  stdoutLines: compact(result.stdout),
  stderrLines: compact(result.stderr),
  safety: {
    connectsTomSsh: true,
    mayConnectSecondOracleViaTomReadonlyPreflight: true,
    writesRemoteCollectorNode: false,
    writesOpenClawInstanceDirs: false,
    startsContainers: false,
    mutatesOpenClawInstance: false,
    restartsOpenClawInstance: false,
    callsLiveApi: false,
    outputsPrivateKeyContent: false,
  },
}, null, 2));
NODE
}

require_intake_confirm() {
  [ "$CONFIRM_REMOTE_ORACLE_INTAKE" = "I_UNDERSTAND_THIS_WRITES_LOCAL_PUSH_CONFIG_AND_TOM_RUNTIME_ONLY" ] || \
    fail "必须设置 CONFIRM_REMOTE_ORACLE_INTAKE=I_UNDERSTAND_THIS_WRITES_LOCAL_PUSH_CONFIG_AND_TOM_RUNTIME_ONLY"
}

require_runner_confirm() {
  [ "$CONFIRM_REMOTE_ORACLE_INTAKE_RUNNER" = "I_UNDERSTAND_THIS_PUSHES_CREDENTIALS_AND_RUNS_TOM_SAFE_ROLLOUT" ] || \
    fail "必须设置 CONFIRM_REMOTE_ORACLE_INTAKE_RUNNER=I_UNDERSTAND_THIS_PUSHES_CREDENTIALS_AND_RUNS_TOM_SAFE_ROLLOUT"
}

main() {
  require_command node
  [ -x "$DISCOVERY_SCRIPT" ] || fail "发现脚本不存在或不可执行：${DISCOVERY_SCRIPT}"
  [ -x "$PUSH_SCRIPT" ] || fail "推送脚本不存在或不可执行：${PUSH_SCRIPT}"

  case "${1:-plan}" in
    doctor)
      local scan_output
      local render_output
      local render_status
      scan_output="$("$DISCOVERY_SCRIPT" scan "$DISCOVERY_CONFIG")"
      render_status="skipped_missing_env"
      render_output="{}"
      if [ -n "${REMOTE_ORACLE_HOST:-}" ] && [ -n "${REMOTE_ORACLE_KEY_PATH:-}" ]; then
        render_output="$(render_push_config)"
        render_status="rendered"
      fi
      doctor_report "$scan_output" "$render_output" "$render_status"
      ;;
    plan)
      local rendered
      rendered="$(render_push_config)"
      INPUT_JSON="$rendered" STATUS="planned" MODE="plan" PUSH_CONFIG_FILE="$PUSH_CONFIG_FILE" json_summary
      ;;
    apply)
      require_intake_confirm
      require_command ssh
      run_apply_flow
      ;;
    run)
      require_intake_confirm
      require_runner_confirm
      require_command ssh
      local apply_report
      local runner_report
      apply_report="$(run_apply_flow)"
      runner_report="$(run_tom_rollout_runner)"
      parse_run_report "$apply_report" "$runner_report"
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
