#!/usr/bin/env bash
set -euo pipefail
set +x

# 本机侧最终上线状态汇总入口。
# status/check 会同时读取本机远端 Oracle 凭据 doctor 与 Tom 最终上线总闸门。
# 本脚本不写本机 push 配置、不写 Tom runtime、不连接第二台 Oracle、不修改任何 OpenClaw 实例目录、不调用 managed-actions live API。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DISCOVERY_CONFIG="${DISCOVERY_CONFIG:-${ROOT_DIR}/ops/local/discover-remote-oracle-credentials.example.json}"
INTAKE_SCRIPT="${INTAKE_SCRIPT:-${SCRIPT_DIR}/remote-oracle-intake.sh}"
TOM_BUNDLE="${TOM_BUNDLE:-runtime/remote-onboarding/remote-oracle}"
SSH_BIN="${FINAL_GO_LIVE_STATUS_SSH_BIN:-ssh}"

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
  final-go-live-status.sh status
  final-go-live-status.sh check

说明：
  status：本机执行 remote-oracle-intake.sh doctor，并 SSH 到 Tom 执行 go-live-gate.sh status。
  check：在 status 基础上让 Tom 执行 go-live-gate.sh check，额外验证 Tom 现有实例 healthcheck。

可选环境变量：
  DISCOVERY_CONFIG=ops/local/discover-remote-oracle-credentials.example.json
  INTAKE_SCRIPT=ops/local/remote-oracle-intake.sh
  TOM_BUNDLE=runtime/remote-onboarding/remote-oracle
  FINAL_GO_LIVE_STATUS_SSH_BIN=ssh
  REMOTE_ORACLE_HOST=<真实第二台 Oracle 公网 IP 或域名>
  REMOTE_ORACLE_KEY_PATH=<本机只读 SSH key 绝对路径>

安全边界：
  - 不写本机 push 配置。
  - 不写 Tom runtime。
  - 不连接第二台 Oracle。
  - 不修改任何 OpenClaw 实例目录。
  - 不重启任何 OpenClaw 实例。
  - 不调用 managed-actions live API。
TEXT
}

main() {
  require_command node
  [ -r "$DISCOVERY_CONFIG" ] || fail "找不到 discovery 配置：${DISCOVERY_CONFIG}"
  [ -x "$INTAKE_SCRIPT" ] || fail "intake 脚本不存在或不可执行：${INTAKE_SCRIPT}"

  case "${1:-status}" in
    status|plan)
      MODE="status" ROOT_DIR="$ROOT_DIR" DISCOVERY_CONFIG="$DISCOVERY_CONFIG" INTAKE_SCRIPT="$INTAKE_SCRIPT" TOM_BUNDLE="$TOM_BUNDLE" SSH_BIN="$SSH_BIN" node <<'NODE'
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const mode = process.env.MODE || "status";
const rootDir = process.env.ROOT_DIR || process.cwd();
const discoveryConfig = process.env.DISCOVERY_CONFIG;
const intakeScript = process.env.INTAKE_SCRIPT;
const tomBundle = process.env.TOM_BUNDLE || "runtime/remote-onboarding/remote-oracle";
const sshBin = process.env.SSH_BIN || "ssh";

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

function extractJson(text) {
  const content = String(text || "");
  const first = content.indexOf("{");
  const last = content.lastIndexOf("}");
  if (first < 0 || last < first) return undefined;
  return content.slice(first, last + 1);
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || rootDir,
    env: options.env || process.env,
    encoding: "utf8",
    maxBuffer: 20 * 1024 * 1024,
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

function gitSummary() {
  const branch = run("git", ["branch", "--show-current"]);
  const head = run("git", ["rev-parse", "--short", "HEAD"]);
  const status = run("git", ["status", "--porcelain"]);
  const upstream = run("git", ["status", "-sb"]);
  return {
    branch: branch.exitCode === 0 ? branch.stdout.trim() : "unknown",
    head: head.exitCode === 0 ? head.stdout.trim() : "unknown",
    dirty: status.exitCode === 0 ? status.stdout.trim().length > 0 : true,
    statusLines: compactLines(upstream.stdout, 20),
  };
}

function runLocalDoctor() {
  const env = {
    ...process.env,
    DISCOVERY_CONFIG: discoveryConfig,
  };
  const result = run(intakeScript, ["doctor"], { env });
  return {
    status: result.exitCode === 0 ? "completed" : "failed",
    exitCode: result.exitCode,
    report: result.exitCode === 0 ? parseJson(result.stdout, "remote Oracle doctor") : undefined,
    stdoutLines: result.exitCode === 0 ? [] : compactLines(result.stdout, 40),
    stderrLines: compactLines(result.stderr, 40),
    command: `${path.relative(rootDir, intakeScript)} doctor`,
  };
}

function runTomGate(config) {
  const tom = config && typeof config === "object" ? config.tom || {} : {};
  const host = readString(tom.host);
  const user = readString(tom.user, "ubuntu");
  const port = readNumber(tom.port, 22);
  const deployDir = readString(tom.deployDir, "/srv/openclaw-control-center-readonly");
  const sshKey = expandHome(readString(tom.sshKey));
  const strictHostKeyChecking = readString(tom.strictHostKeyChecking, "accept-new");
  const knownHostsFile = expandHome(readString(tom.knownHostsFile, "/dev/null"));
  const connectTimeoutSeconds = readNumber(tom.connectTimeoutSeconds, 15);

  if (!host) {
    return {
      status: "failed",
      exitCode: 2,
      error: "discovery 配置缺少 tom.host",
      report: undefined,
      stdoutLines: [],
      stderrLines: [],
    };
  }

  const remoteCommand = [
    `cd ${shellQuote(deployDir)}`,
    `printf '__OPENCLAW_TOM_HEAD__%s\\n' "$(git -C repo rev-parse --short HEAD 2>/dev/null || true)"`,
    `repo/ops/tom-readonly/go-live-gate.sh ${mode} ${shellQuote(tomBundle)}`,
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
    "-o",
    `UserKnownHostsFile=${knownHostsFile}`,
  ];
  if (sshKey) args.push("-i", sshKey);
  args.push(`${user}@${host}`, remoteCommand);

  const result = run(sshBin, args, { cwd: rootDir });
  const headMatch = String(result.stdout || "").match(/__OPENCLAW_TOM_HEAD__(\S*)/);
  const jsonText = extractJson(result.stdout);
  const parsed = jsonText ? parseJson(jsonText, "Tom go-live gate") : undefined;
  return {
    status: result.exitCode === 0 && parsed && parsed.status !== "invalid_output" ? "completed" : "failed",
    exitCode: result.exitCode,
    tom: {
      host,
      user,
      port,
      deployDir,
      bundle: tomBundle,
      head: headMatch ? headMatch[1] : "unknown",
    },
    report: parsed,
    stdoutLines: parsed ? [] : compactLines(result.stdout, 60),
    stderrLines: compactLines(result.stderr, 60),
    error: result.error,
    commandPreview: `ssh ${user}@${host} repo/ops/tom-readonly/go-live-gate.sh ${mode} ${tomBundle}`,
  };
}

function doctorBlocker(report) {
  const status = report?.status || "unknown";
  if (status === "ready_for_apply") return undefined;
  if (status === "needs_remote_host") return "缺少第二台 Oracle host。";
  if (status === "needs_remote_key") return "缺少第二台 Oracle 只读 SSH key。";
  if (status === "needs_remote_host_and_key") return "缺少第二台 Oracle host 和只读 SSH key。";
  if (status === "reachable_candidate_found") return "已有可达候选，但仍需要显式选择 REMOTE_ORACLE_HOST 和 REMOTE_ORACLE_KEY_PATH。";
  if (status === "candidates_found") return "已有候选 host/key，但还没有完成只读探测和显式选择。";
  return `本机远端凭据 doctor 未就绪：${status}`;
}

function collectGateBlockers(gate, decision) {
  if (!gate || typeof gate !== "object") return [];
  const blockers = [];
  if (typeof gate.status === "string" && gate.status.startsWith("blocked")) {
    blockers.push(`Tom 总闸门阻塞：${gate.status}`);
  }
  const stages = gate.stages || {};
  const cross = stages.crossServerReadonlyMonitoring || {};
  const remoteAccessIssues = cross.remoteAccess && Array.isArray(cross.remoteAccess.issues) ? cross.remoteAccess.issues : [];
  if (decision.startsWith("blocked_remote_oracle") || decision === "blocked_cross_server_readonly") {
    blockers.push(...remoteAccessIssues.map((item) => `跨服务器只读接入：${item}`));
    return blockers;
  }
  const dryRunIssues = stages.managedActionDryRunEvidence && Array.isArray(stages.managedActionDryRunEvidence.issues)
    ? stages.managedActionDryRunEvidence.issues
    : [];
  if (decision === "blocked_managed_action_dry_run") {
    blockers.push(...dryRunIssues.map((item) => `dry-run 证据：${item}`));
    return blockers;
  }
  const liveIssues = stages.managedActions && Array.isArray(stages.managedActions.issues)
    ? stages.managedActions.issues
    : [];
  if (decision === "blocked_managed_actions") {
    blockers.push(...liveIssues.map((item) => `管理动作：${item}`));
  }
  return blockers;
}

function localNextCommands(doctor) {
  const report = doctor.report || {};
  if (Array.isArray(report.nextCommands) && report.nextCommands.length > 0) return report.nextCommands;
  return [
    "ops/local/remote-oracle-intake.sh doctor",
    "ops/local/discover-remote-oracle-credentials.sh scan ops/local/discover-remote-oracle-credentials.example.json",
    "CONFIRM_REMOTE_ORACLE_DISCOVERY=I_UNDERSTAND_THIS_ONLY_PROBES_SSH_READONLY ops/local/discover-remote-oracle-credentials.sh probe ops/local/discover-remote-oracle-credentials.example.json",
  ];
}

function unique(values) {
  return [...new Set(values.filter((value) => typeof value === "string" && value.trim() !== ""))];
}

function decide(doctor, tomGate) {
  if (doctor.status !== "completed") return "blocked_local_doctor";
  if (tomGate.status !== "completed") return "blocked_tom_go_live_gate";

  const doctorStatus = doctor.report?.status || "unknown";
  if (doctorStatus === "needs_remote_host") return "blocked_remote_oracle_host";
  if (doctorStatus === "needs_remote_key") return "blocked_remote_oracle_key";
  if (doctorStatus === "needs_remote_host_and_key") return "blocked_remote_oracle_credentials";
  if (doctorStatus === "reachable_candidate_found" || doctorStatus === "candidates_found") return "blocked_remote_oracle_selection";
  if (doctorStatus !== "ready_for_apply") return "blocked_remote_oracle_credentials";

  return tomGate.report?.status || "unknown";
}

const config = readConfig(discoveryConfig);
const localDoctor = runLocalDoctor();
const tomGate = runTomGate(config);
const decision = decide(localDoctor, tomGate);
const doctorIssue = localDoctor.status === "completed" ? doctorBlocker(localDoctor.report) : "本机 remote-oracle-intake doctor 执行失败。";
const gateBlockers = tomGate.status === "completed" ? collectGateBlockers(tomGate.report, decision) : ["Tom go-live gate 无法执行或输出无效。"];
const blockers = unique([
  doctorIssue,
  ...gateBlockers,
]);
const gateNextCommands = Array.isArray(tomGate.report?.nextCommands) ? tomGate.report.nextCommands : [];
const nextCommands = unique([
  ...(doctorIssue ? localNextCommands(localDoctor) : []),
  ...gateNextCommands,
]);

console.log(JSON.stringify({
  schemaVersion: 1,
  status: decision,
  mode,
  generatedAt: new Date().toISOString(),
  local: {
    git: gitSummary(),
    remoteOracleDoctor: localDoctor,
  },
  tom: {
    goLiveGate: tomGate,
  },
  blockers,
  nextCommands,
  safety: {
    readsLocalSshConfigOnly: true,
    writesLocalFiles: false,
    writesTomRuntime: false,
    connectsTomSsh: true,
    connectsSecondOracle: false,
    writesRemoteFiles: false,
    writesOpenClawInstanceDirs: false,
    restartsOpenClawInstances: false,
    callsManagedActionsLiveApi: false,
    checkRunsHealthcheckOnly: mode === "check",
    outputsPrivateKeyContent: false,
  },
}, null, 2));
NODE
      ;;
    check)
      MODE="check" ROOT_DIR="$ROOT_DIR" DISCOVERY_CONFIG="$DISCOVERY_CONFIG" INTAKE_SCRIPT="$INTAKE_SCRIPT" TOM_BUNDLE="$TOM_BUNDLE" SSH_BIN="$SSH_BIN" node <<'NODE'
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const mode = process.env.MODE || "status";
const rootDir = process.env.ROOT_DIR || process.cwd();
const discoveryConfig = process.env.DISCOVERY_CONFIG;
const intakeScript = process.env.INTAKE_SCRIPT;
const tomBundle = process.env.TOM_BUNDLE || "runtime/remote-onboarding/remote-oracle";
const sshBin = process.env.SSH_BIN || "ssh";

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

function extractJson(text) {
  const content = String(text || "");
  const first = content.indexOf("{");
  const last = content.lastIndexOf("}");
  if (first < 0 || last < first) return undefined;
  return content.slice(first, last + 1);
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || rootDir,
    env: options.env || process.env,
    encoding: "utf8",
    maxBuffer: 20 * 1024 * 1024,
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

function gitSummary() {
  const branch = run("git", ["branch", "--show-current"]);
  const head = run("git", ["rev-parse", "--short", "HEAD"]);
  const status = run("git", ["status", "--porcelain"]);
  const upstream = run("git", ["status", "-sb"]);
  return {
    branch: branch.exitCode === 0 ? branch.stdout.trim() : "unknown",
    head: head.exitCode === 0 ? head.stdout.trim() : "unknown",
    dirty: status.exitCode === 0 ? status.stdout.trim().length > 0 : true,
    statusLines: compactLines(upstream.stdout, 20),
  };
}

function runLocalDoctor() {
  const env = {
    ...process.env,
    DISCOVERY_CONFIG: discoveryConfig,
  };
  const result = run(intakeScript, ["doctor"], { env });
  return {
    status: result.exitCode === 0 ? "completed" : "failed",
    exitCode: result.exitCode,
    report: result.exitCode === 0 ? parseJson(result.stdout, "remote Oracle doctor") : undefined,
    stdoutLines: result.exitCode === 0 ? [] : compactLines(result.stdout, 40),
    stderrLines: compactLines(result.stderr, 40),
    command: `${path.relative(rootDir, intakeScript)} doctor`,
  };
}

function runTomGate(config) {
  const tom = config && typeof config === "object" ? config.tom || {} : {};
  const host = readString(tom.host);
  const user = readString(tom.user, "ubuntu");
  const port = readNumber(tom.port, 22);
  const deployDir = readString(tom.deployDir, "/srv/openclaw-control-center-readonly");
  const sshKey = expandHome(readString(tom.sshKey));
  const strictHostKeyChecking = readString(tom.strictHostKeyChecking, "accept-new");
  const knownHostsFile = expandHome(readString(tom.knownHostsFile, "/dev/null"));
  const connectTimeoutSeconds = readNumber(tom.connectTimeoutSeconds, 15);

  if (!host) {
    return {
      status: "failed",
      exitCode: 2,
      error: "discovery 配置缺少 tom.host",
      report: undefined,
      stdoutLines: [],
      stderrLines: [],
    };
  }

  const remoteCommand = [
    `cd ${shellQuote(deployDir)}`,
    `printf '__OPENCLAW_TOM_HEAD__%s\\n' "$(git -C repo rev-parse --short HEAD 2>/dev/null || true)"`,
    `repo/ops/tom-readonly/go-live-gate.sh ${mode} ${shellQuote(tomBundle)}`,
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
    "-o",
    `UserKnownHostsFile=${knownHostsFile}`,
  ];
  if (sshKey) args.push("-i", sshKey);
  args.push(`${user}@${host}`, remoteCommand);

  const result = run(sshBin, args, { cwd: rootDir });
  const headMatch = String(result.stdout || "").match(/__OPENCLAW_TOM_HEAD__(\S*)/);
  const jsonText = extractJson(result.stdout);
  const parsed = jsonText ? parseJson(jsonText, "Tom go-live gate") : undefined;
  return {
    status: result.exitCode === 0 && parsed && parsed.status !== "invalid_output" ? "completed" : "failed",
    exitCode: result.exitCode,
    tom: {
      host,
      user,
      port,
      deployDir,
      bundle: tomBundle,
      head: headMatch ? headMatch[1] : "unknown",
    },
    report: parsed,
    stdoutLines: parsed ? [] : compactLines(result.stdout, 60),
    stderrLines: compactLines(result.stderr, 60),
    error: result.error,
    commandPreview: `ssh ${user}@${host} repo/ops/tom-readonly/go-live-gate.sh ${mode} ${tomBundle}`,
  };
}

function doctorBlocker(report) {
  const status = report?.status || "unknown";
  if (status === "ready_for_apply") return undefined;
  if (status === "needs_remote_host") return "缺少第二台 Oracle host。";
  if (status === "needs_remote_key") return "缺少第二台 Oracle 只读 SSH key。";
  if (status === "needs_remote_host_and_key") return "缺少第二台 Oracle host 和只读 SSH key。";
  if (status === "reachable_candidate_found") return "已有可达候选，但仍需要显式选择 REMOTE_ORACLE_HOST 和 REMOTE_ORACLE_KEY_PATH。";
  if (status === "candidates_found") return "已有候选 host/key，但还没有完成只读探测和显式选择。";
  return `本机远端凭据 doctor 未就绪：${status}`;
}

function collectGateBlockers(gate, decision) {
  if (!gate || typeof gate !== "object") return [];
  const blockers = [];
  if (typeof gate.status === "string" && gate.status.startsWith("blocked")) {
    blockers.push(`Tom 总闸门阻塞：${gate.status}`);
  }
  const stages = gate.stages || {};
  const cross = stages.crossServerReadonlyMonitoring || {};
  const remoteAccessIssues = cross.remoteAccess && Array.isArray(cross.remoteAccess.issues) ? cross.remoteAccess.issues : [];
  if (decision.startsWith("blocked_remote_oracle") || decision === "blocked_cross_server_readonly") {
    blockers.push(...remoteAccessIssues.map((item) => `跨服务器只读接入：${item}`));
    return blockers;
  }
  const dryRunIssues = stages.managedActionDryRunEvidence && Array.isArray(stages.managedActionDryRunEvidence.issues)
    ? stages.managedActionDryRunEvidence.issues
    : [];
  if (decision === "blocked_managed_action_dry_run") {
    blockers.push(...dryRunIssues.map((item) => `dry-run 证据：${item}`));
    return blockers;
  }
  const liveIssues = stages.managedActions && Array.isArray(stages.managedActions.issues)
    ? stages.managedActions.issues
    : [];
  if (decision === "blocked_managed_actions") {
    blockers.push(...liveIssues.map((item) => `管理动作：${item}`));
  }
  return blockers;
}

function localNextCommands(doctor) {
  const report = doctor.report || {};
  if (Array.isArray(report.nextCommands) && report.nextCommands.length > 0) return report.nextCommands;
  return [
    "ops/local/remote-oracle-intake.sh doctor",
    "ops/local/discover-remote-oracle-credentials.sh scan ops/local/discover-remote-oracle-credentials.example.json",
    "CONFIRM_REMOTE_ORACLE_DISCOVERY=I_UNDERSTAND_THIS_ONLY_PROBES_SSH_READONLY ops/local/discover-remote-oracle-credentials.sh probe ops/local/discover-remote-oracle-credentials.example.json",
  ];
}

function unique(values) {
  return [...new Set(values.filter((value) => typeof value === "string" && value.trim() !== ""))];
}

function decide(doctor, tomGate) {
  if (doctor.status !== "completed") return "blocked_local_doctor";
  if (tomGate.status !== "completed") return "blocked_tom_go_live_gate";

  const doctorStatus = doctor.report?.status || "unknown";
  if (doctorStatus === "needs_remote_host") return "blocked_remote_oracle_host";
  if (doctorStatus === "needs_remote_key") return "blocked_remote_oracle_key";
  if (doctorStatus === "needs_remote_host_and_key") return "blocked_remote_oracle_credentials";
  if (doctorStatus === "reachable_candidate_found" || doctorStatus === "candidates_found") return "blocked_remote_oracle_selection";
  if (doctorStatus !== "ready_for_apply") return "blocked_remote_oracle_credentials";

  return tomGate.report?.status || "unknown";
}

const config = readConfig(discoveryConfig);
const localDoctor = runLocalDoctor();
const tomGate = runTomGate(config);
const decision = decide(localDoctor, tomGate);
const doctorIssue = localDoctor.status === "completed" ? doctorBlocker(localDoctor.report) : "本机 remote-oracle-intake doctor 执行失败。";
const gateBlockers = tomGate.status === "completed" ? collectGateBlockers(tomGate.report, decision) : ["Tom go-live gate 无法执行或输出无效。"];
const blockers = unique([
  doctorIssue,
  ...gateBlockers,
]);
const gateNextCommands = Array.isArray(tomGate.report?.nextCommands) ? tomGate.report.nextCommands : [];
const nextCommands = unique([
  ...(doctorIssue ? localNextCommands(localDoctor) : []),
  ...gateNextCommands,
]);

console.log(JSON.stringify({
  schemaVersion: 1,
  status: decision,
  mode,
  generatedAt: new Date().toISOString(),
  local: {
    git: gitSummary(),
    remoteOracleDoctor: localDoctor,
  },
  tom: {
    goLiveGate: tomGate,
  },
  blockers,
  nextCommands,
  safety: {
    readsLocalSshConfigOnly: true,
    writesLocalFiles: false,
    writesTomRuntime: false,
    connectsTomSsh: true,
    connectsSecondOracle: false,
    writesRemoteFiles: false,
    writesOpenClawInstanceDirs: false,
    restartsOpenClawInstances: false,
    callsManagedActionsLiveApi: false,
    checkRunsHealthcheckOnly: mode === "check",
    outputsPrivateKeyContent: false,
  },
}, null, 2));
NODE
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
