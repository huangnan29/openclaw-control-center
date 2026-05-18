#!/usr/bin/env bash
set -euo pipefail
set +x

# 本机侧最终上线完成度审计。
# 只读汇总 review、Tom healthcheck 与文档/cron状态，明确哪些需求已完成、哪些仍需人工批准。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DISCOVERY_CONFIG="${DISCOVERY_CONFIG:-${ROOT_DIR}/ops/local/discover-remote-oracle-credentials.example.json}"
REVIEW_SCRIPT="${FINAL_GO_LIVE_REVIEW_SCRIPT:-${SCRIPT_DIR}/final-go-live-review.sh}"
SSH_BIN="${FINAL_GO_LIVE_AUDIT_SSH_BIN:-${FINAL_GO_LIVE_REVIEW_SSH_BIN:-${FINAL_GO_LIVE_STATUS_SSH_BIN:-ssh}}}"
OPENCLAW_TOPOLOGY_MODE="${OPENCLAW_TOPOLOGY_MODE:-local-only}"
FINAL_GO_LIVE_OUTPUT="${FINAL_GO_LIVE_OUTPUT:-json}"

fail() {
  printf '[失败] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'TEXT'
用法：
  final-go-live-completion-audit.sh status

说明：
  status：只读汇总当前最终上线完成度。它会运行 final-go-live-review.sh status，并只读执行 Tom healthcheck。
  可设置 FINAL_GO_LIVE_OUTPUT=summary 输出短摘要。

安全边界：
  - 不批准 approval。
  - 不打开 live gate。
  - 不调用 managed action live API。
  - 不写 Tom runtime。
  - 不修改 OpenClaw 实例目录。
  - 不清空 HEARTBEAT.md。
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
[ -x "$REVIEW_SCRIPT" ] || fail "review 脚本不存在或不可执行：${REVIEW_SCRIPT}"

MODE="status" \
ROOT_DIR="$ROOT_DIR" \
DISCOVERY_CONFIG="$DISCOVERY_CONFIG" \
REVIEW_SCRIPT="$REVIEW_SCRIPT" \
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
const reviewScript = process.env.REVIEW_SCRIPT;
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

function runReview() {
  const result = run(reviewScript, ["status"], {
    env: {
      ...process.env,
      DISCOVERY_CONFIG: discoveryConfig,
      FINAL_GO_LIVE_REVIEW_SSH_BIN: sshBin,
      OPENCLAW_TOPOLOGY_MODE: topologyMode,
      FINAL_GO_LIVE_OUTPUT: "json",
    },
  });
  return {
    exitCode: result.exitCode,
    report: parseJson(result.stdout, "final go-live review"),
    stderrLines: compactLines(result.stderr, 30),
  };
}

function runTomHealthcheck(tom) {
  if (tom.error || !tom.host) {
    return {
      exitCode: 2,
      status: "blocked_tom_config",
      issues: [tom.error || "discovery 配置缺少 tom.host"],
      outputLines: [],
    };
  }
  const remote = `cd ${shellQuote(tom.deployDir)} && ./healthcheck.sh`;
  const result = run(sshBin, sshArgs(tom, remote), { timeout: 300_000 });
  return {
    exitCode: result.exitCode,
    status: result.exitCode === 0 ? "passed" : "failed",
    issues: result.exitCode === 0 ? [] : compactLines(result.stderr || result.stdout, 10),
    outputLines: compactLines(result.stdout, 12),
  };
}

function docsReady() {
  const files = [
    "docs/MULTI_INSTANCE_READONLY.md",
    "docs/FAQ.md",
    "ops/tom-readonly/README.md",
    "implementation_plan.md",
    "task.md",
  ];
  const missing = files.filter((file) => !fs.existsSync(path.join(rootDir, file)));
  return {
    status: missing.length === 0 ? "pass" : "fail",
    files,
    missing,
  };
}

function req(id, label, status, evidence, detail = "") {
  return { id, label, status, evidence, detail };
}

function buildAudit() {
  const git = gitSummary();
  const tom = tomConfig();
  const review = runReview();
  const healthcheck = runTomHealthcheck(tom);
  const docs = docsReady();
  const summary = review.report?.summary || {};
  const readiness = summary.readiness || {};
  const dryRunInboxCron = summary.dryRunInboxCron || {};
  const heartbeatBurnAlertCron = summary.heartbeatBurnAlertCron || {};
  const heartbeatBurnAlert = summary.heartbeatBurnAlert || {};
  const usageWarnings = Array.isArray(review.report?.warnings) ? review.report.warnings : [];

  const requirements = [
    req(
      "tom_readonly_health",
      "Tom 单 Oracle 多实例只读健康检查",
      healthcheck.exitCode === 0 ? "pass" : "fail",
      "Tom ./healthcheck.sh",
      healthcheck.status,
    ),
    req(
      "dry_run_management_chain",
      "dry-run 管理链路与 inbox cron",
      dryRunInboxCron.status === "inbox_cron_installed" && dryRunInboxCron.needsUpdate === false ? "pass" : "fail",
      "final-go-live-review dryRunInboxCron",
      `${dryRunInboxCron.status || "unknown"} needsUpdate=${String(dryRunInboxCron.needsUpdate)}`,
    ),
    req(
      "monitoring_alerting",
      "监控与 heartbeat/token 告警链路",
      heartbeatBurnAlertCron.status === "heartbeat_burn_alert_cron_installed" && heartbeatBurnAlertCron.needsUpdate === false ? "pass" : "fail",
      "final-go-live-review heartbeatBurnAlertCron",
      `${heartbeatBurnAlertCron.status || "unknown"} needsUpdate=${String(heartbeatBurnAlertCron.needsUpdate)}`,
    ),
    req(
      "approval_packet_ready",
      "最终 live healthcheck 批准前证据包",
      readiness.status === "waiting_human_approval" && readiness.approvalPacket === "ready" && readiness.approval === "needs_manual_approval" ? "pass" : "fail",
      "final-go-live-review readiness",
      `readiness=${readiness.status || "unknown"} approvalPacket=${readiness.approvalPacket || "unknown"} approval=${readiness.approval || "unknown"}`,
    ),
    req(
      "ops_docs",
      "运维文档与任务记录",
      docs.status,
      "required docs exist",
      docs.missing.length > 0 ? `missing=${docs.missing.join(",")}` : "docs present",
    ),
    req(
      "usage_alerts_review",
      "heartbeat/token 告警人工复核",
      usageWarnings.length > 0 || heartbeatBurnAlert.latest?.suspiciousRows > 0 ? "warning" : "pass",
      "heartbeat-burn-alert latest",
      usageWarnings.join("；") || "no active usage warning",
    ),
    req(
      "final_live_healthcheck",
      "最终 live healthcheck 一次性验收",
      readiness.status === "approval_consumed" || readiness.approval === "consumed" ? "pass" : "pending",
      "live-healthcheck readiness/approval",
      readiness.approval === "needs_manual_approval" ? "需要 Anan 显式 approve-and-run" : `approval=${readiness.approval || "unknown"}`,
    ),
  ];

  const failed = requirements.filter((item) => item.status === "fail");
  const pending = requirements.filter((item) => item.status === "pending");
  const warnings = requirements.filter((item) => item.status === "warning");
  const passed = requirements.filter((item) => item.status === "pass");
  const hardBlockers = [
    ...failed.map((item) => `${item.label}: ${item.detail}`),
    ...pending
      .filter((item) => item.id === "final_live_healthcheck")
      .map((item) => `${item.label}: ${item.detail}`),
  ];

  const status = failed.length > 0
    ? "blocked_preconditions"
    : pending.length > 0
      ? "blocked_human_approval_required"
      : warnings.length > 0
        ? "completed_with_warnings"
        : "completed";

  return {
    schemaVersion: 1,
    status,
    mode: "status",
    topologyMode,
    generatedAt: new Date().toISOString(),
    local: git,
    tom: {
      host: tom.host || "",
      head: review.report?.tom?.head || "",
    },
    progress: {
      total: requirements.length,
      passed: passed.length,
      warnings: warnings.length,
      pending: pending.length,
      failed: failed.length,
      percentExcludingHumanPending: Math.round((passed.length / requirements.length) * 100),
    },
    requirements,
    hardBlockers,
    warnings: [
      ...(Array.isArray(review.report?.warnings) ? review.report.warnings : []),
      ...(healthcheck.issues || []),
    ],
    nextCommands: status === "completed"
      ? ["ops/local/final-go-live-runner.sh verify-completed"]
      : status === "completed_with_warnings"
        ? [
            "FINAL_GO_LIVE_OUTPUT=summary OPENCLAW_TOPOLOGY_MODE=local-only ops/local/final-go-live-review.sh status",
            "repo/ops/tom-readonly/heartbeat-burn-alert-runner.sh status",
          ]
      : [
          "FINAL_GO_LIVE_OUTPUT=summary OPENCLAW_TOPOLOGY_MODE=local-only ops/local/final-go-live-review.sh status",
          "CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN=I_APPROVE_AND_RUN_FINAL_LIVE_HEALTHCHECK APPROVED_BY=Anan LOCAL_API_TOKEN=<本地令牌> ops/local/final-go-live-runner.sh approve-and-run",
          "repo/ops/tom-readonly/heartbeat-burn-alert-runner.sh status",
        ],
    evidence: {
      reviewExitCode: review.exitCode,
      healthcheckExitCode: healthcheck.exitCode,
      healthcheckOutputLines: healthcheck.outputLines,
      docs,
    },
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
  };
}

function emit(report, code = 0) {
  if (outputMode === "summary") {
    console.log(`status: ${report.status}`);
    console.log(`tomHead: ${report.tom.head}`);
    console.log(`progress: ${report.progress.passed}/${report.progress.total} pass, ${report.progress.warnings} warning, ${report.progress.pending} pending, ${report.progress.failed} failed`);
    for (const item of report.requirements) {
      console.log(`- ${item.status}: ${item.id} — ${item.detail}`);
    }
    if (report.hardBlockers.length > 0) {
      console.log("hardBlockers:");
      for (const blocker of report.hardBlockers) console.log(`- ${blocker}`);
    }
    if (report.warnings.length > 0) {
      console.log("warnings:");
      for (const warning of report.warnings) console.log(`- ${warning}`);
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

const audit = buildAudit();
emit(audit, audit.status === "blocked_preconditions" ? 2 : 0);
NODE
