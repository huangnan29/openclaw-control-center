#!/usr/bin/env bash
set -euo pipefail
set +x

# 本机侧最终上线批准包装器。
# status 只读检查 Tom 容器 token 是否存在和 approval review 是否 ready。
# approve-and-run 只在显式确认后，从 Tom control-center 容器环境读取 LOCAL_API_TOKEN，
# 不打印令牌、不落盘，然后交给既有 final-go-live-runner.sh approve-and-run。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DISCOVERY_CONFIG="${DISCOVERY_CONFIG:-${ROOT_DIR}/ops/local/discover-remote-oracle-credentials.example.json}"
FINAL_GO_LIVE_RUNNER_SCRIPT="${FINAL_GO_LIVE_RUNNER_SCRIPT:-${SCRIPT_DIR}/final-go-live-runner.sh}"
FINAL_GO_LIVE_REVIEW_SCRIPT="${FINAL_GO_LIVE_REVIEW_SCRIPT:-${SCRIPT_DIR}/final-go-live-review.sh}"
SSH_BIN="${FINAL_GO_LIVE_APPROVE_TOKEN_SSH_BIN:-${FINAL_GO_LIVE_RUNNER_SSH_BIN:-ssh}}"
CONTROL_CENTER_CONTAINER="${CONTROL_CENTER_CONTAINER:-openclaw-control-center-readonly}"
OPENCLAW_TOPOLOGY_MODE="${OPENCLAW_TOPOLOGY_MODE:-local-only}"
FINAL_GO_LIVE_OUTPUT="${FINAL_GO_LIVE_OUTPUT:-json}"
CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN="${CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN:-}"
APPROVED_BY="${APPROVED_BY:-}"

fail() {
  printf '[失败] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'TEXT'
用法：
  final-go-live-approve-and-run-from-tom-token.sh status
  final-go-live-approve-and-run-from-tom-token.sh approve-and-run

approve-and-run 必须设置：
  CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN=I_APPROVE_AND_RUN_FINAL_LIVE_HEALTHCHECK
  APPROVED_BY=<批准人>

说明：
  本脚本用于减少手工读取 LOCAL_API_TOKEN 的出错概率。
  status 只读检查 Tom 容器 token 长度和 approval review 状态，不打印 token，不写文件。
  approve-and-run 只在确认短语和批准人齐全后 SSH 到 Tom，从 control-center 容器环境读取 LOCAL_API_TOKEN，
  然后把令牌放入当前子进程环境，调用 final-go-live-runner.sh approve-and-run。

安全边界：
  - status 不要求确认短语，不读取真实 token 内容，只读取 token 长度。
  - 缺确认短语或批准人时，不连接 Tom。
  - 不打印 LOCAL_API_TOKEN。
  - 不把 LOCAL_API_TOKEN 写入文件。
  - 最终是否批准和执行仍由 final-go-live-runner.sh approve-and-run 的既有闸门决定。
  - 不修改 OpenClaw 实例目录，不清空 HEARTBEAT.md，不重启实例。
TEXT
}

MODE_NAME="${1:-approve-and-run}"
case "$MODE_NAME" in
  -h|--help|help)
    usage
    exit 0
    ;;
  status|check|approve-and-run)
    ;;
  *)
    usage
    fail "未知参数：$MODE_NAME"
    ;;
esac

[ -r "$DISCOVERY_CONFIG" ] || fail "找不到 discovery 配置：${DISCOVERY_CONFIG}"
[ -x "$FINAL_GO_LIVE_RUNNER_SCRIPT" ] || fail "runner 不存在或不可执行：${FINAL_GO_LIVE_RUNNER_SCRIPT}"
[ -x "$FINAL_GO_LIVE_REVIEW_SCRIPT" ] || fail "review 脚本不存在或不可执行：${FINAL_GO_LIVE_REVIEW_SCRIPT}"

MODE_NAME="$MODE_NAME" \
ROOT_DIR="$ROOT_DIR" \
DISCOVERY_CONFIG="$DISCOVERY_CONFIG" \
FINAL_GO_LIVE_RUNNER_SCRIPT="$FINAL_GO_LIVE_RUNNER_SCRIPT" \
FINAL_GO_LIVE_REVIEW_SCRIPT="$FINAL_GO_LIVE_REVIEW_SCRIPT" \
SSH_BIN="$SSH_BIN" \
CONTROL_CENTER_CONTAINER="$CONTROL_CENTER_CONTAINER" \
OPENCLAW_TOPOLOGY_MODE="$OPENCLAW_TOPOLOGY_MODE" \
FINAL_GO_LIVE_OUTPUT="$FINAL_GO_LIVE_OUTPUT" \
CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN="$CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN" \
APPROVED_BY="$APPROVED_BY" \
node <<'NODE'
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const rootDir = process.env.ROOT_DIR || process.cwd();
const discoveryConfig = process.env.DISCOVERY_CONFIG;
const runnerScript = process.env.FINAL_GO_LIVE_RUNNER_SCRIPT;
const reviewScript = process.env.FINAL_GO_LIVE_REVIEW_SCRIPT;
const sshBin = process.env.SSH_BIN || "ssh";
const modeName = process.env.MODE_NAME === "check" ? "status" : (process.env.MODE_NAME || "approve-and-run");
const containerName = String(process.env.CONTROL_CENTER_CONTAINER || "openclaw-control-center-readonly").trim();
const topologyMode = process.env.OPENCLAW_TOPOLOGY_MODE || "local-only";
const outputMode = process.env.FINAL_GO_LIVE_OUTPUT || "json";
const confirm = process.env.CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN || "";
const approvedBy = String(process.env.APPROVED_BY || "").trim();
const requiredConfirm = "I_APPROVE_AND_RUN_FINAL_LIVE_HEALTHCHECK";

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

function compactLines(text, limit = 20) {
  return String(text || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, limit);
}

function emit(report, code = 0) {
  console.log(JSON.stringify(report, null, 2));
  process.exit(code);
}

function safety(extra = {}) {
  return {
    readsTomContainerEnv: false,
    readsTomContainerTokenLengthOnly: false,
    printsLocalApiToken: false,
    writesLocalApiToken: false,
    writesOpenClawInstanceDirs: false,
    clearsHeartbeatFiles: false,
    restartsOpenClawInstances: false,
    opensLiveGateDirectly: false,
    delegatesToFinalRunner: false,
    blockedBeforeSsh: false,
    ...extra,
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

function runReview() {
  const result = run(reviewScript, ["status"], {
    env: {
      ...process.env,
      DISCOVERY_CONFIG: discoveryConfig,
      OPENCLAW_TOPOLOGY_MODE: topologyMode,
      FINAL_GO_LIVE_OUTPUT: "json",
    },
    timeout: 300_000,
  });
  return {
    exitCode: result.exitCode,
    report: parseJson(result.stdout, "final-go-live-review status"),
    stderrLines: compactLines(result.stderr, 20),
  };
}

function block(status, issues, nextCommands = []) {
  emit({
    schemaVersion: 1,
    status,
    generatedAt: new Date().toISOString(),
    issues,
    nextCommands,
    safety: safety({ blockedBeforeSsh: true }),
  }, 2);
}

const tom = tomConfig();
if (tom.error || !tom.host) {
  emit({
    schemaVersion: 1,
    status: "blocked_tom_config",
    generatedAt: new Date().toISOString(),
    issues: [tom.error || "discovery 配置缺少 tom.host"],
    safety: safety({ blockedBeforeSsh: true }),
  }, 2);
}

function fetchTokenLength(tomConfigValue) {
  const remote = [
    `docker inspect ${shellQuote(containerName)} --format '{{range .Config.Env}}{{println .}}{{end}}'`,
    "sed -n 's/^LOCAL_API_TOKEN=//p'",
    "tail -n 1",
    "awk '{ print length($0) }'",
  ].join(" | ");
  const result = run(sshBin, sshArgs(tomConfigValue, remote), { timeout: 60_000 });
  const length = Number.parseInt(result.stdout.trim(), 10);
  return {
    exitCode: result.exitCode,
    length: Number.isFinite(length) ? length : 0,
    issues: result.exitCode === 0 ? [] : compactLines(result.stderr || result.stdout || result.error),
  };
}

function emitStatus(tomConfigValue) {
  const token = fetchTokenLength(tomConfigValue);
  const review = runReview();
  const reviewStatus = review.report?.status || "unknown";
  const readyReviewStatuses = new Set(["ready_for_human_approval", "ready_for_human_approval_with_usage_alerts"]);
  const tokenAvailable = token.exitCode === 0 && token.length > 0;
  const reviewReady = review.exitCode === 0 && readyReviewStatuses.has(reviewStatus);
  const issues = [
    ...token.issues,
    ...(tokenAvailable ? [] : ["Tom control-center 容器中未检测到 LOCAL_API_TOKEN"]),
    ...(reviewReady ? [] : [`approval review 当前未 ready：${reviewStatus}`]),
    ...(review.stderrLines || []),
  ];
  const summary = review.report?.summary || {};
  const status = tokenAvailable && reviewReady
    ? "preflight_ready_for_human_approval"
    : "blocked_preflight_not_ready";
  emit({
    schemaVersion: 1,
    status,
    mode: "status",
    generatedAt: new Date().toISOString(),
    token: {
      source: `tom-container:${containerName}`,
      available: tokenAvailable,
      length: token.length,
      printed: false,
      writtenToDisk: false,
    },
    review: {
      status: reviewStatus,
      tomHead: review.report?.tom?.head || "",
      readiness: summary.readiness?.status || "",
      approvalPacket: summary.readiness?.approvalPacket || "",
      approval: summary.readiness?.approval || "",
      dryRunInboxCron: summary.dryRunInboxCron?.status || "",
      dryRunInboxCronNeedsUpdate: summary.dryRunInboxCron?.needsUpdate,
      heartbeatBurnAlertCron: summary.heartbeatBurnAlertCron?.status || "",
      heartbeatBurnAlertCronNeedsUpdate: summary.heartbeatBurnAlertCron?.needsUpdate,
      heartbeatBurnAlert: summary.heartbeatBurnAlert?.latest?.status || "",
      warnings: Array.isArray(review.report?.warnings) ? review.report.warnings : [],
    },
    issues,
    nextCommands: status === "preflight_ready_for_human_approval"
      ? [
          `CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN=${requiredConfirm} APPROVED_BY=Anan FINAL_GO_LIVE_OUTPUT=summary ops/local/final-go-live-approve-and-run-from-tom-token.sh approve-and-run`,
        ]
      : [
          "FINAL_GO_LIVE_OUTPUT=summary OPENCLAW_TOPOLOGY_MODE=local-only ops/local/final-go-live-review.sh status",
        ],
    safety: safety({
      readsTomContainerTokenLengthOnly: true,
      readsTomContainerEnv: false,
      delegatesToFinalRunner: false,
    }),
  }, status === "preflight_ready_for_human_approval" ? 0 : 2);
}

if (modeName === "status") {
  emitStatus(tom);
}

if (confirm !== requiredConfirm) {
  block(
    "blocked_confirmation_required",
    [`必须设置 CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN=${requiredConfirm}`],
    [`CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN=${requiredConfirm} APPROVED_BY=Anan ops/local/final-go-live-approve-and-run-from-tom-token.sh approve-and-run`],
  );
}

if (!approvedBy) {
  block(
    "blocked_approved_by_required",
    ["必须设置 APPROVED_BY"],
    [`CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN=${requiredConfirm} APPROVED_BY=Anan ops/local/final-go-live-approve-and-run-from-tom-token.sh approve-and-run`],
  );
}

const remote = [
  `docker inspect ${shellQuote(containerName)} --format '{{range .Config.Env}}{{println .}}{{end}}'`,
  "sed -n 's/^LOCAL_API_TOKEN=//p'",
  "tail -n 1",
].join(" | ");
const tokenResult = run(sshBin, sshArgs(tom, remote), { timeout: 60_000 });
if (tokenResult.exitCode !== 0) {
  emit({
    schemaVersion: 1,
    status: "blocked_token_fetch_failed",
    generatedAt: new Date().toISOString(),
    issues: compactLines(tokenResult.stderr || tokenResult.stdout || tokenResult.error),
    safety: safety({ readsTomContainerEnv: true }),
  }, 2);
}

const token = tokenResult.stdout.trim();
if (!token) {
  emit({
    schemaVersion: 1,
    status: "blocked_local_token_missing_in_tom_container",
    generatedAt: new Date().toISOString(),
    issues: [`Tom 容器 ${containerName} 环境中没有 LOCAL_API_TOKEN`],
    safety: safety({ readsTomContainerEnv: true }),
  }, 2);
}

const runner = run(runnerScript, ["approve-and-run"], {
  env: {
    ...process.env,
    DISCOVERY_CONFIG: discoveryConfig,
    OPENCLAW_TOPOLOGY_MODE: topologyMode,
    FINAL_GO_LIVE_OUTPUT: outputMode,
    CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN: requiredConfirm,
    APPROVED_BY: approvedBy,
    LOCAL_API_TOKEN: token,
  },
  timeout: 600_000,
});

process.stdout.write(runner.stdout);
process.stderr.write(runner.stderr);
process.exit(runner.exitCode);
NODE
