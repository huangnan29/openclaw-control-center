#!/usr/bin/env bash
set -euo pipefail
set +x

# 本机侧最终上线人工审查摘要。
# 只读聚合 Tom readiness、cron 状态和 heartbeat 告警状态，不批准、不打开 live gate、不修改实例。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DISCOVERY_CONFIG="${DISCOVERY_CONFIG:-${ROOT_DIR}/ops/local/discover-remote-oracle-credentials.example.json}"
SSH_BIN="${FINAL_GO_LIVE_REVIEW_SSH_BIN:-${FINAL_GO_LIVE_STATUS_SSH_BIN:-ssh}}"
OPENCLAW_TOPOLOGY_MODE="${OPENCLAW_TOPOLOGY_MODE:-local-only}"
FINAL_GO_LIVE_OUTPUT="${FINAL_GO_LIVE_OUTPUT:-json}"

fail() {
  printf '[失败] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'TEXT'
用法：
  final-go-live-review.sh status

说明：
  status：只读连接 Tom，汇总最终上线人工批准前需要看的 readiness、approval packet、approval、dry-run inbox cron、heartbeat 告警 cron 与最新异常用量告警。
  可设置 FINAL_GO_LIVE_OUTPUT=summary 输出短摘要。

安全边界：
  - 不批准 approval。
  - 不打开 live gate。
  - 不调用 managed action live API。
  - 不写 Tom runtime。
  - 不修改任何 OpenClaw 实例目录。
  - 不重启任何 OpenClaw 实例。
TEXT
}

case "${1:-status}" in
  -h|--help|help)
    usage
    exit 0
    ;;
  status)
    ;;
  *)
    usage
    fail "未知模式：${1:-}"
    ;;
esac

[ -r "$DISCOVERY_CONFIG" ] || fail "找不到 discovery 配置：${DISCOVERY_CONFIG}"

MODE="status" \
ROOT_DIR="$ROOT_DIR" \
DISCOVERY_CONFIG="$DISCOVERY_CONFIG" \
SSH_BIN="$SSH_BIN" \
OPENCLAW_TOPOLOGY_MODE="$OPENCLAW_TOPOLOGY_MODE" \
FINAL_GO_LIVE_OUTPUT="$FINAL_GO_LIVE_OUTPUT" \
node <<'NODE'
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const rootDir = process.env.ROOT_DIR || process.cwd();
const discoveryConfig = process.env.DISCOVERY_CONFIG;
const sshBin = process.env.SSH_BIN || "ssh";
const topologyMode = String(process.env.OPENCLAW_TOPOLOGY_MODE || "local-only").trim() || "local-only";
const outputMode = String(process.env.FINAL_GO_LIVE_OUTPUT || "json").trim().toLowerCase() === "summary" ? "summary" : "json";

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

function compactLines(text, limit = 40) {
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
      rawLines: compactLines(text, 20),
    };
  }
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

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || rootDir,
    env: options.env || process.env,
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
    timeout: options.timeout || 300_000,
  });
  return {
    exitCode: typeof result.status === "number" ? result.status : 1,
    stdout: result.stdout || "",
    stderr: result.stderr || "",
    error: result.error ? (result.error instanceof Error ? result.error.message : String(result.error)) : undefined,
  };
}

function gitSummary() {
  const head = run("git", ["rev-parse", "--short", "HEAD"]);
  const status = run("git", ["status", "--porcelain"]);
  return {
    head: head.exitCode === 0 ? head.stdout.trim() : "unknown",
    dirty: status.exitCode === 0 ? status.stdout.trim().length > 0 : true,
  };
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

function sshArgs(tom, remoteCommand) {
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
  args.push(`${tom.user}@${tom.host}`, remoteCommand);
  return args;
}

function runTomJson(tom, label, command) {
  const remote = `cd ${shellQuote(tom.deployDir)} && ${command}`;
  const result = run(sshBin, sshArgs(tom, remote), { timeout: 300_000 });
  return {
    label,
    exitCode: result.exitCode,
    report: parseJson(result.stdout, label),
    stderrLines: compactLines(result.stderr, 30),
  };
}

function runTomText(tom, label, command) {
  const remote = `cd ${shellQuote(tom.deployDir)} && ${command}`;
  const result = run(sshBin, sshArgs(tom, remote), { timeout: 300_000 });
  return {
    label,
    exitCode: result.exitCode,
    text: result.stdout.trim(),
    stderrLines: compactLines(result.stderr, 30),
  };
}

function readinessSummary(report) {
  return {
    status: report.status,
    approvalPacket: report.stages?.approvalPacket?.report?.status,
    approval: report.stages?.approval?.report?.status,
    issues: Array.isArray(report.issues) ? report.issues : [],
    safety: report.safety || {},
  };
}

function cronSummary(report) {
  return {
    status: report.status,
    installed: report.installed,
    needsUpdate: report.needsUpdate,
  };
}

function alertSummary(report) {
  return {
    status: report.status,
    latest: report.latest,
  };
}

function decide(parts) {
  const issues = [];
  const warnings = [];
  if (parts.tomHead.exitCode !== 0) issues.push("Tom HEAD 无法读取");
  if (parts.readiness.exitCode !== 0) issues.push("readiness 命令失败");
  const ready = readinessSummary(parts.readiness.report);
  if (ready.status !== "waiting_human_approval") issues.push(`readiness=${ready.status}`);
  if (ready.approvalPacket !== "ready") issues.push(`approvalPacket=${ready.approvalPacket}`);
  if (ready.approval !== "needs_manual_approval") issues.push(`approval=${ready.approval}`);
  for (const issue of ready.issues || []) issues.push(String(issue));

  const inbox = cronSummary(parts.inboxCron.report);
  if (inbox.status !== "inbox_cron_installed" || inbox.needsUpdate !== false) issues.push(`dry-run inbox cron 未就绪：${inbox.status}`);
  const heartbeatCron = cronSummary(parts.heartbeatCron.report);
  if (heartbeatCron.status !== "heartbeat_burn_alert_cron_installed" || heartbeatCron.needsUpdate !== false) {
    issues.push(`heartbeat 告警 cron 未就绪：${heartbeatCron.status}`);
  }
  const heartbeatAlert = alertSummary(parts.heartbeatAlert.report);
  if (heartbeatAlert.latest?.suspiciousRows > 0 || heartbeatAlert.latest?.status === "heartbeat_burn_alert_triggered") {
    warnings.push(`heartbeat/token 告警当前存在 ${heartbeatAlert.latest?.suspiciousRows ?? "若干"} 个可疑实例`);
  }

  return {
    status: issues.length > 0
      ? "blocked_preconditions"
      : warnings.length > 0
        ? "ready_for_human_approval_with_usage_alerts"
        : "ready_for_human_approval",
    issues,
    warnings,
  };
}

function emit(report, code = 0) {
  if (outputMode === "summary") {
    console.log(`status: ${report.status}`);
    console.log(`tomHead: ${report.tom.head}`);
    console.log(`readiness: ${report.summary.readiness.status}`);
    console.log(`approvalPacket: ${report.summary.readiness.approvalPacket}`);
    console.log(`approval: ${report.summary.readiness.approval}`);
    console.log(`dryRunInboxCron: ${report.summary.dryRunInboxCron.status} needsUpdate=${report.summary.dryRunInboxCron.needsUpdate}`);
    console.log(`heartbeatBurnAlertCron: ${report.summary.heartbeatBurnAlertCron.status} needsUpdate=${report.summary.heartbeatBurnAlertCron.needsUpdate}`);
    console.log(`heartbeatBurnAlert: ${report.summary.heartbeatBurnAlert.latest?.status || report.summary.heartbeatBurnAlert.status}`);
    if (report.warnings.length > 0) {
      console.log("warnings:");
      for (const warning of report.warnings) console.log(`- ${warning}`);
    }
    if (report.issues.length > 0) {
      console.log("issues:");
      for (const issue of report.issues) console.log(`- ${issue}`);
    }
    console.log("nextCommands:");
    for (const command of report.nextCommands) console.log(`- ${command}`);
    console.log("safety:");
    for (const [key, value] of Object.entries(report.safety)) console.log(`- ${key}: ${value}`);
  } else {
    console.log(JSON.stringify(report, null, 2));
  }
  process.exit(code);
}

const git = gitSummary();
const tom = tomConfig();
if (tom.error || !tom.host) {
  emit({
    schemaVersion: 1,
    status: "blocked_tom_config",
    mode: "status",
    topologyMode,
    generatedAt: new Date().toISOString(),
    issues: [tom.error || "discovery 配置缺少 tom.host"],
    warnings: [],
    safety: {
      readsStatusOnly: true,
      writesTomRuntime: false,
      writesOpenClawInstanceDirs: false,
      restartsOpenClawInstances: false,
      opensLiveGate: false,
      callsManagedActionsLiveApi: false,
    },
  }, 2);
}

const parts = {
  tomHead: runTomText(tom, "tom head", "git -C repo rev-parse --short HEAD"),
  readiness: runTomJson(tom, "live readiness", "repo/ops/tom-readonly/live-healthcheck-readiness.sh status"),
  inboxCron: runTomJson(tom, "dry-run inbox cron", "repo/ops/tom-readonly/install-managed-action-inbox-cron.sh status"),
  heartbeatCron: runTomJson(tom, "heartbeat burn alert cron", "repo/ops/tom-readonly/install-heartbeat-burn-alert-cron.sh status"),
  heartbeatAlert: runTomJson(tom, "heartbeat burn alert status", "repo/ops/tom-readonly/heartbeat-burn-alert-runner.sh status"),
};
const decision = decide(parts);
const review = {
  schemaVersion: 1,
  status: decision.status,
  mode: "status",
  topologyMode,
  generatedAt: new Date().toISOString(),
  local: git,
  tom: {
    host: tom.host,
    head: parts.tomHead.text,
  },
  summary: {
    readiness: readinessSummary(parts.readiness.report),
    dryRunInboxCron: cronSummary(parts.inboxCron.report),
    heartbeatBurnAlertCron: cronSummary(parts.heartbeatCron.report),
    heartbeatBurnAlert: alertSummary(parts.heartbeatAlert.report),
  },
  issues: decision.issues,
  warnings: decision.warnings,
  nextCommands: decision.issues.length > 0
    ? [
        "ops/local/final-go-live-runner.sh prepare",
        "repo/ops/tom-readonly/live-healthcheck-approval-review.sh status",
      ]
    : [
        "CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN=I_APPROVE_AND_RUN_FINAL_LIVE_HEALTHCHECK APPROVED_BY=Anan LOCAL_API_TOKEN=<本地令牌> ops/local/final-go-live-runner.sh approve-and-run",
        "repo/ops/tom-readonly/heartbeat-burn-alert-runner.sh status",
      ],
  safety: {
    readsStatusOnly: true,
    writesTomRuntime: false,
    writesApprovalFile: false,
    writesOpenClawInstanceDirs: false,
    clearsHeartbeatFiles: false,
    restartsOpenClawInstances: false,
    opensLiveGate: false,
    callsManagedActionsLiveApi: false,
    callsModelApis: false,
  },
  evidence: {
    tomHeadExitCode: parts.tomHead.exitCode,
    readinessExitCode: parts.readiness.exitCode,
    inboxCronExitCode: parts.inboxCron.exitCode,
    heartbeatCronExitCode: parts.heartbeatCron.exitCode,
    heartbeatAlertExitCode: parts.heartbeatAlert.exitCode,
  },
};

emit(review, decision.issues.length > 0 ? 2 : 0);
NODE
