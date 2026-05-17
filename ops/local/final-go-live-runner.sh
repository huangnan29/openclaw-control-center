#!/usr/bin/env bash
set -euo pipefail
set +x

# 本机侧最终上线推进 runner。
# prepare 自动推进到人工批准边界；run-approved 只在显式确认和本地令牌存在时代理 Tom runner。
# 本脚本不批准 approval，不直接打开 live gate，不修改任何 OpenClaw 实例目录。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DISCOVERY_CONFIG="${DISCOVERY_CONFIG:-${ROOT_DIR}/ops/local/discover-remote-oracle-credentials.example.json}"
FINAL_GO_LIVE_STATUS_SCRIPT="${FINAL_GO_LIVE_STATUS_SCRIPT:-${SCRIPT_DIR}/final-go-live-status.sh}"
SSH_BIN="${FINAL_GO_LIVE_RUNNER_SSH_BIN:-${FINAL_GO_LIVE_STATUS_SSH_BIN:-ssh}}"
OPENCLAW_TOPOLOGY_MODE="${OPENCLAW_TOPOLOGY_MODE:-local-only}"
CONFIRM_FINAL_GO_LIVE_RUNNER="${CONFIRM_FINAL_GO_LIVE_RUNNER:-}"
LOCAL_API_TOKEN="${LOCAL_API_TOKEN:-}"

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
  final-go-live-runner.sh status
  final-go-live-runner.sh prepare
  final-go-live-runner.sh run-approved

说明：
  status：只运行 final-go-live-status.sh status。
  prepare：运行 final-go-live-status.sh check；如果下一步是 Tom live-healthcheck-rollout-runner.sh prepare，就自动 SSH 到 Tom 执行 prepare，再复核最终状态。
  run-approved：必须显式确认并提供 LOCAL_API_TOKEN，才会 SSH 到 Tom 执行 live-healthcheck-rollout-runner.sh run-approved。

run-approved 必须设置：
  CONFIRM_FINAL_GO_LIVE_RUNNER=I_UNDERSTAND_THIS_RUNS_APPROVED_FINAL_GO_LIVE
  LOCAL_API_TOKEN=<本地令牌>

安全边界：
  - 不批准 approval。
  - status/prepare 不打开 live gate，不调用 managed-actions live API。
  - run-approved 只代理已批准的 Tom runner，Tom runner 会再次校验 approval/readiness。
  - 不修改任何 OpenClaw 实例目录。
TEXT
}

run_node() {
  local mode="$1"
  MODE="$mode" \
    ROOT_DIR="$ROOT_DIR" \
    DISCOVERY_CONFIG="$DISCOVERY_CONFIG" \
    FINAL_GO_LIVE_STATUS_SCRIPT="$FINAL_GO_LIVE_STATUS_SCRIPT" \
    SSH_BIN="$SSH_BIN" \
    OPENCLAW_TOPOLOGY_MODE="$OPENCLAW_TOPOLOGY_MODE" \
    CONFIRM_FINAL_GO_LIVE_RUNNER="$CONFIRM_FINAL_GO_LIVE_RUNNER" \
    LOCAL_API_TOKEN="$LOCAL_API_TOKEN" \
    node <<'NODE'
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const mode = process.env.MODE || "status";
const rootDir = process.env.ROOT_DIR || process.cwd();
const discoveryConfig = process.env.DISCOVERY_CONFIG;
const finalStatusScript = process.env.FINAL_GO_LIVE_STATUS_SCRIPT;
const sshBin = process.env.SSH_BIN || "ssh";
const topologyMode = normalizeTopologyMode(process.env.OPENCLAW_TOPOLOGY_MODE || "local-only");
const confirm = process.env.CONFIRM_FINAL_GO_LIVE_RUNNER || "";
const localApiToken = process.env.LOCAL_API_TOKEN || "";

function normalizeTopologyMode(value) {
  const text = String(value || "").trim().toLowerCase();
  if (text === "cross-server" || text === "multi-server") return "cross-server";
  return "local-only";
}

function expandHome(value) {
  if (typeof value !== "string") return "";
  if (value === "~") return os.homedir();
  if (value.startsWith("~/")) return path.join(os.homedir(), value.slice(2));
  return value;
}

function readString(value, fallback = "") {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : fallback;
}

function readNumber(value, fallback) {
  const parsed = Number.parseInt(String(value ?? fallback), 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function compactLines(text, limit = 80) {
  return String(text || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, limit);
}

function parseJson(text, label) {
  try {
    return JSON.parse(text);
  } catch (error) {
    return {
      status: "invalid_output",
      label,
      error: error instanceof Error ? error.message : String(error),
      rawLines: compactLines(text, 40),
    };
  }
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || rootDir,
    env: options.env || process.env,
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
    timeout: options.timeout || 300_000,
  });
  return {
    command: [command, ...args].join(" "),
    exitCode: typeof result.status === "number" ? result.status : 1,
    stdout: result.stdout || "",
    stderr: result.stderr || "",
    error: result.error ? (result.error instanceof Error ? result.error.message : String(result.error)) : undefined,
  };
}

function readConfig(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    return {
      status: "invalid_config",
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

function tomConfig() {
  const config = readConfig(discoveryConfig);
  if (config.status === "invalid_config") return { error: config.error };
  const tom = config && typeof config === "object" ? config.tom || {} : {};
  return {
    host: readString(tom.host),
    user: readString(tom.user, "ubuntu"),
    port: readNumber(tom.port, 22),
    deployDir: readString(tom.deployDir, "/srv/openclaw-control-center-readonly"),
    sshKey: expandHome(readString(tom.sshKey)),
    strictHostKeyChecking: readString(tom.strictHostKeyChecking, "accept-new"),
    knownHostsFile: expandHome(readString(tom.knownHostsFile, "/dev/null")),
    connectTimeoutSeconds: readNumber(tom.connectTimeoutSeconds, 15),
  };
}

function runFinalStatus(statusMode) {
  const result = run(finalStatusScript, [statusMode], {
    env: {
      ...process.env,
      DISCOVERY_CONFIG: discoveryConfig,
      OPENCLAW_TOPOLOGY_MODE: topologyMode,
    },
  });
  return {
    exitCode: result.exitCode,
    report: parseJson(result.stdout, `final-go-live-status ${statusMode}`),
    stderrLines: compactLines(result.stderr, 60),
  };
}

function runTomRunner(runnerMode) {
  const tom = tomConfig();
  if (tom.error) {
    return {
      exitCode: 2,
      report: { status: "invalid_config", issues: [tom.error] },
      stderrLines: [],
    };
  }
  if (!tom.host) {
    return {
      exitCode: 2,
      report: { status: "missing_tom_host", issues: ["discovery 配置缺少 tom.host"] },
      stderrLines: [],
    };
  }

  const args = [
    "-p",
    String(tom.port),
    "-o",
    "BatchMode=yes",
    "-o",
    `ConnectTimeout=${tom.connectTimeoutSeconds}`,
    "-o",
    `StrictHostKeyChecking=${tom.strictHostKeyChecking}`,
    "-o",
    `UserKnownHostsFile=${tom.knownHostsFile}`,
  ];
  if (tom.sshKey) args.push("-i", tom.sshKey);

  const remoteEnv = [
    `OPENCLAW_TOPOLOGY_MODE=${shellQuote(topologyMode)}`,
  ];
  if (runnerMode === "run-approved") {
    remoteEnv.push("CONFIRM_LIVE_HEALTHCHECK_RUNNER=I_UNDERSTAND_THIS_RUNS_APPROVED_LIVE_HEALTHCHECK");
    remoteEnv.push(`LOCAL_API_TOKEN=${shellQuote(localApiToken)}`);
  }
  const remoteCommand = [
    `cd ${shellQuote(tom.deployDir)}`,
    `${remoteEnv.join(" ")} repo/ops/tom-readonly/live-healthcheck-rollout-runner.sh ${runnerMode}`,
  ].join(" && ");
  args.push(`${tom.user}@${tom.host}`, remoteCommand);

  const result = run(sshBin, args, { cwd: rootDir, timeout: 300_000 });
  return {
    exitCode: result.exitCode,
    report: parseJson(result.stdout, `Tom live healthcheck runner ${runnerMode}`),
    stderrLines: compactLines(result.stderr, 80),
    commandPreview: `ssh ${tom.user}@${tom.host} <redacted> live-healthcheck-rollout-runner.sh ${runnerMode}`,
  };
}

function hasCommand(report, pattern) {
  const commands = Array.isArray(report?.nextCommands) ? report.nextCommands : [];
  return commands.some((command) => String(command).includes(pattern));
}

function baseSafety(extra = {}) {
  return {
    connectsTomSsh: mode !== "status",
    connectsSecondOracle: topologyMode === "cross-server",
    writesLocalFiles: false,
    writesTomRuntime: mode === "prepare" || mode === "run-approved",
    approvesLiveHealthcheck: false,
    opensLiveGate: mode === "run-approved",
    callsManagedActionsLiveApi: mode === "run-approved",
    writesOpenClawInstanceDirs: false,
    restartsOpenClawInstances: false,
    ...extra,
  };
}

function statusOnly() {
  const finalStatus = runFinalStatus("status");
  return {
    schemaVersion: 1,
    status: finalStatus.report?.status || "unknown",
    mode,
    topologyMode,
    generatedAt: new Date().toISOString(),
    stages: { finalStatus },
    nextCommands: Array.isArray(finalStatus.report?.nextCommands) ? finalStatus.report.nextCommands : [],
    safety: baseSafety({
      connectsTomSsh: true,
      writesTomRuntime: false,
      opensLiveGate: false,
      callsManagedActionsLiveApi: false,
      readsStatusOnly: true,
    }),
  };
}

function prepare() {
  const before = runFinalStatus("check");
  if (before.exitCode !== 0 || before.report?.status === "invalid_output") {
    return {
      schemaVersion: 1,
      status: "blocked_final_status",
      mode,
      topologyMode,
      generatedAt: new Date().toISOString(),
      stages: { before },
      issues: [`final-go-live-status check 未通过：exit=${before.exitCode}`],
      nextCommands: Array.isArray(before.report?.nextCommands) ? before.report.nextCommands : [],
      safety: baseSafety({ connectsTomSsh: true, writesTomRuntime: false, opensLiveGate: false, callsManagedActionsLiveApi: false }),
    };
  }

  if (!hasCommand(before.report, "live-healthcheck-rollout-runner.sh prepare")) {
    return {
      schemaVersion: 1,
      status: "blocked_no_prepare_step",
      mode,
      topologyMode,
      generatedAt: new Date().toISOString(),
      stages: { before },
      issues: ["最终上线状态没有给出 Tom runner prepare 下一步"],
      nextCommands: Array.isArray(before.report?.nextCommands) ? before.report.nextCommands : [],
      safety: baseSafety({ connectsTomSsh: true, writesTomRuntime: false, opensLiveGate: false, callsManagedActionsLiveApi: false }),
    };
  }

  const tomPrepare = runTomRunner("prepare");
  const after = runFinalStatus("check");
  const tomStatus = tomPrepare.report?.status || "unknown";
  const afterStatus = after.report?.status || "unknown";
  const prepared = tomPrepare.exitCode === 0
    && (tomStatus === "prepared_waiting_human_approval" || tomStatus === "prepared_approved_ready_for_live_window");
  const tomNextCommands = Array.isArray(tomPrepare.report?.nextCommands) ? tomPrepare.report.nextCommands : [];
  const afterNextCommands = Array.isArray(after.report?.nextCommands) ? after.report.nextCommands : [];
  return {
    schemaVersion: 1,
    status: prepared ? tomStatus : `blocked_${tomStatus}`,
    mode,
    topologyMode,
    generatedAt: new Date().toISOString(),
    stages: { before, tomPrepare, after },
    issues: prepared ? [] : [`Tom runner prepare 未完成：${tomStatus}`],
    nextCommands: prepared && tomNextCommands.length > 0 ? tomNextCommands : afterNextCommands,
    safety: baseSafety({
      connectsTomSsh: true,
      writesTomRuntime: true,
      writesControlCenterRuntimeOnly: true,
      opensLiveGate: false,
      callsManagedActionsLiveApi: false,
      checkRunsHealthcheckOnly: true,
      finalStatusAfter: afterStatus,
    }),
  };
}

function runApproved() {
  if (confirm !== "I_UNDERSTAND_THIS_RUNS_APPROVED_FINAL_GO_LIVE") {
    return {
      schemaVersion: 1,
      status: "blocked_confirmation_required",
      mode,
      topologyMode,
      generatedAt: new Date().toISOString(),
      issues: ["必须设置 CONFIRM_FINAL_GO_LIVE_RUNNER=I_UNDERSTAND_THIS_RUNS_APPROVED_FINAL_GO_LIVE"],
      nextCommands: [
        "CONFIRM_FINAL_GO_LIVE_RUNNER=I_UNDERSTAND_THIS_RUNS_APPROVED_FINAL_GO_LIVE LOCAL_API_TOKEN=<本地令牌> ops/local/final-go-live-runner.sh run-approved",
      ],
      safety: baseSafety({ connectsTomSsh: false, writesTomRuntime: false, opensLiveGate: false, callsManagedActionsLiveApi: false, blockedBeforeLive: true }),
    };
  }
  if (!localApiToken) {
    return {
      schemaVersion: 1,
      status: "blocked_local_token_required",
      mode,
      topologyMode,
      generatedAt: new Date().toISOString(),
      issues: ["必须通过 LOCAL_API_TOKEN 提供本地令牌"],
      nextCommands: [
        "CONFIRM_FINAL_GO_LIVE_RUNNER=I_UNDERSTAND_THIS_RUNS_APPROVED_FINAL_GO_LIVE LOCAL_API_TOKEN=<本地令牌> ops/local/final-go-live-runner.sh run-approved",
      ],
      safety: baseSafety({ connectsTomSsh: false, writesTomRuntime: false, opensLiveGate: false, callsManagedActionsLiveApi: false, blockedBeforeLive: true }),
    };
  }

  const before = runFinalStatus("check");
  const tomRun = runTomRunner("run-approved");
  const after = runFinalStatus("check");
  const tomStatus = tomRun.report?.status || "unknown";
  const completed = tomRun.exitCode === 0 && tomStatus === "completed_live_healthcheck";
  const tomNextCommands = Array.isArray(tomRun.report?.nextCommands) ? tomRun.report.nextCommands : [];
  const afterNextCommands = Array.isArray(after.report?.nextCommands) ? after.report.nextCommands : [];
  return {
    schemaVersion: 1,
    status: completed ? "completed_final_live_healthcheck" : tomStatus,
    mode,
    topologyMode,
    generatedAt: new Date().toISOString(),
    stages: { before, tomRun, after },
    issues: Array.isArray(tomRun.report?.issues) ? tomRun.report.issues : [],
    nextCommands: completed && afterNextCommands.length > 0 ? afterNextCommands : tomNextCommands,
    safety: baseSafety({
      connectsTomSsh: true,
      opensLiveGate: completed,
      callsManagedActionsLiveApi: completed,
      requiresFinalRunnerConfirmation: true,
      requiresLocalApiToken: true,
      requiresTomApprovedReadiness: true,
      blockedBeforeLive: !completed,
    }),
  };
}

function emit(report) {
  console.log(JSON.stringify(report, null, 2));
  if (mode === "prepare" && String(report.status || "").startsWith("blocked_")) process.exit(2);
  if (mode === "run-approved" && report.status !== "completed_final_live_healthcheck") process.exit(2);
}

if (mode === "status") {
  emit(statusOnly());
} else if (mode === "prepare") {
  emit(prepare());
} else if (mode === "run-approved") {
  emit(runApproved());
} else {
  console.error(`[失败] 未知模式：${mode}`);
  process.exit(2);
}
NODE
}

main() {
  require_command node
  [ -r "$DISCOVERY_CONFIG" ] || fail "找不到 discovery 配置：${DISCOVERY_CONFIG}"
  [ -x "$FINAL_GO_LIVE_STATUS_SCRIPT" ] || fail "final status 脚本不存在或不可执行：${FINAL_GO_LIVE_STATUS_SCRIPT}"

  case "${1:-status}" in
    status)
      run_node "status"
      ;;
    prepare)
      run_node "prepare"
      ;;
    run-approved)
      run_node "run-approved"
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
