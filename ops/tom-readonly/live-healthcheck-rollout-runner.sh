#!/usr/bin/env bash
set -euo pipefail
set +x

# live healthcheck 演练预备 runner。
# status 只读取 readiness；prepare 只准备 approval 模板、生成/校验证据包并刷新 readiness。
# run-approved 只在 approval 已批准、证据包通过且显式确认后执行一次性演练窗口。
# verify-completed 只读验收演练结果：approval 已消费、报告通过、只读状态恢复。
# 本脚本不会批准 approval，不会修改任何 OpenClaw 实例目录。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
OPENCLAW_TOPOLOGY_MODE="${OPENCLAW_TOPOLOGY_MODE:-local-only}"
INSTANCE_ID="${INSTANCE_ID:-tom}"
OPERATOR="${OPERATOR:-Anan}"

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
  live-healthcheck-rollout-runner.sh status
  live-healthcheck-rollout-runner.sh prepare
  live-healthcheck-rollout-runner.sh run-approved
  live-healthcheck-rollout-runner.sh verify-completed

说明：
  status 只调用 live-healthcheck-readiness.sh status，不写文件。
  prepare 会自动执行到人工批准前：
    1. 检查 managed-action dry-run 证据。
    2. 准备 approval 模板，已存在则不覆盖。
    3. 生成并校验批准前证据包。
    4. 运行 live-healthcheck-readiness.sh check 汇总下一步。
  run-approved 只在 readiness 为 approved_ready_for_live_window 后，调用一次性演练窗口。
  verify-completed 只读复核演练后状态和最新报告，不调用 live API。

安全边界：
  - 不批准 approval。
  - status/prepare 不打开 live gate，不调用 managed-actions live API。
  - run-approved 必须显式确认，并只允许执行已批准的 healthcheck live 演练。
  - 不修改任何 OpenClaw 实例目录。

run-approved 必须设置：
  CONFIRM_LIVE_HEALTHCHECK_RUNNER=I_UNDERSTAND_THIS_RUNS_APPROVED_LIVE_HEALTHCHECK
  LOCAL_API_TOKEN=<本地令牌>
TEXT
}

run_node() {
  local mode="$1"
  MODE="$mode" \
    DEPLOY_DIR="$DEPLOY_DIR" \
    SCRIPT_DIR="$SCRIPT_DIR" \
    OPENCLAW_TOPOLOGY_MODE="$OPENCLAW_TOPOLOGY_MODE" \
    INSTANCE_ID="$INSTANCE_ID" \
    OPERATOR="$OPERATOR" \
    node <<'NODE'
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const mode = process.env.MODE || "status";
const deployDir = path.resolve(process.env.DEPLOY_DIR || "/srv/openclaw-control-center-readonly");
const scriptDir = path.resolve(process.env.SCRIPT_DIR || path.join(deployDir, "repo", "ops", "tom-readonly"));
const topologyMode = process.env.OPENCLAW_TOPOLOGY_MODE || "local-only";
const instanceId = process.env.INSTANCE_ID || "tom";
const operator = process.env.OPERATOR || "Anan";
const approvalFile = path.join(deployDir, "runtime", "live-healthcheck-approval.json");
const reportDir = process.env.LIVE_HEALTHCHECK_REPORT_DIR || path.join(deployDir, "runtime", "live-healthcheck-reports");
const runnerConfirm = process.env.CONFIRM_LIVE_HEALTHCHECK_RUNNER || "";
const localApiToken = process.env.LOCAL_API_TOKEN || "";

const scripts = {
  readiness: process.env.LIVE_HEALTHCHECK_RUNNER_READINESS_SCRIPT || path.join(scriptDir, "live-healthcheck-readiness.sh"),
  dryRunGate: process.env.LIVE_HEALTHCHECK_RUNNER_DRY_RUN_GATE_SCRIPT || path.join(scriptDir, "managed-action-dry-run-gate.sh"),
  approval: process.env.LIVE_HEALTHCHECK_RUNNER_APPROVAL_SCRIPT || path.join(scriptDir, "live-healthcheck-approval.sh"),
  approvalPacket: process.env.LIVE_HEALTHCHECK_RUNNER_APPROVAL_PACKET_SCRIPT || path.join(scriptDir, "live-healthcheck-approval-packet.sh"),
  liveWindow: process.env.LIVE_HEALTHCHECK_RUNNER_WINDOW_SCRIPT || path.join(scriptDir, "live-healthcheck-window.sh"),
};

function run(command, args, extraEnv = {}) {
  const result = spawnSync(command, args, {
    cwd: deployDir,
    env: {
      ...process.env,
      DEPLOY_DIR: deployDir,
      OPENCLAW_TOPOLOGY_MODE: topologyMode,
      INSTANCE_ID: instanceId,
      OPERATOR: operator,
      ...extraEnv,
    },
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
    timeout: 240_000,
  });
  return {
    command: [command, ...args].join(" "),
    exitCode: typeof result.status === "number" ? result.status : 1,
    stdout: result.stdout || "",
    stderr: result.stderr || "",
    error: result.error ? formatError(result.error) : undefined,
  };
}

function parseJson(text, label) {
  try {
    return JSON.parse(text);
  } catch (error) {
    return {
      status: "invalid_output",
      label,
      error: formatError(error),
      raw: String(text || "").slice(0, 4000),
    };
  }
}

function compactLines(text, limit = 80) {
  return String(text || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, limit);
}

function lastNonEmptyLine(text) {
  return compactLines(text, 200).at(-1) || "";
}

function stage(result, label) {
  return {
    exitCode: result.exitCode,
    report: parseJson(result.stdout, label),
    stdoutLines: compactLines(result.stdout, 40),
    stderrLines: compactLines(result.stderr, 40),
  };
}

function readLatestReport() {
  try {
    if (!fs.existsSync(reportDir)) {
      return {
        status: "missing_report_dir",
        dir: reportDir,
        issues: [`报告目录不存在：${reportDir}`],
      };
    }
    const candidates = fs.readdirSync(reportDir)
      .filter((name) => /^live-healthcheck-report-.+\.json$/.test(name))
      .map((name) => {
        const file = path.join(reportDir, name);
        const stat = fs.statSync(file);
        return { file, mtimeMs: stat.mtimeMs };
      })
      .sort((a, b) => b.mtimeMs - a.mtimeMs);
    if (candidates.length === 0) {
      return {
        status: "missing_report",
        dir: reportDir,
        issues: ["未找到 live healthcheck JSON 报告"],
      };
    }
    const latest = candidates[0];
    return {
      status: "read",
      file: latest.file,
      report: JSON.parse(fs.readFileSync(latest.file, "utf8")),
    };
  } catch (error) {
    return {
      status: "invalid_report",
      dir: reportDir,
      error: formatError(error),
      issues: [`最新报告无法读取或解析：${formatError(error)}`],
    };
  }
}

function formatError(error) {
  return error instanceof Error ? error.message : String(error);
}

function safety(extra = {}) {
  return {
    writesControlCenterRuntimeOnly: mode === "prepare" || mode === "run-approved",
    writesApprovalTemplateOnly: mode === "prepare",
    generatesApprovalPacket: mode === "prepare",
    approvesLiveHealthcheck: false,
    opensLiveGate: mode === "run-approved",
    callsManagedActionsLiveApi: mode === "run-approved",
    writesOpenClawInstanceDirs: false,
    restartsOpenClawInstances: false,
    ...extra,
  };
}

function statusOnly() {
  const readinessResult = run(scripts.readiness, ["status"]);
  const readiness = stage(readinessResult, "live healthcheck readiness");
  const readinessStatus = readiness.report?.status || "unknown";
  return {
    schemaVersion: 1,
    status: readinessStatus,
    mode,
    generatedAt: new Date().toISOString(),
    target: { instanceId, action: "healthcheck", operator },
    stages: { readiness },
    nextCommands: Array.isArray(readiness.report?.nextCommands) ? readiness.report.nextCommands : [],
    safety: safety({
      writesControlCenterRuntimeOnly: false,
      writesApprovalTemplateOnly: false,
      generatesApprovalPacket: false,
      readsStatusOnly: true,
    }),
  };
}

function prepare() {
  const dryRunResult = run(scripts.dryRunGate, ["status"]);
  const dryRun = stage(dryRunResult, "managed action dry-run gate");
  const dryRunStatus = dryRun.report?.status || "unknown";
  if (dryRunResult.exitCode !== 0 || dryRunStatus !== "ready") {
    return {
      schemaVersion: 1,
      status: "blocked_dry_run",
      mode,
      generatedAt: new Date().toISOString(),
      target: { instanceId, action: "healthcheck", operator },
      stages: { dryRun },
      issues: [`dry-run 证据未 ready：${dryRunStatus}`],
      nextCommands: Array.isArray(dryRun.report?.nextCommands) && dryRun.report.nextCommands.length > 0
        ? dryRun.report.nextCommands
        : ["CONFIRM_MANAGED_ACTION_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CREATES_DRY_RUN_AUDIT_RECORD LOCAL_API_TOKEN=<本地令牌> repo/ops/tom-readonly/managed-action-dry-run-gate.sh run"],
      safety: safety(),
    };
  }

  const approvalPrepareResult = run(scripts.approval, ["prepare", approvalFile]);
  const approvalPrepare = stage(approvalPrepareResult, "approval prepare");
  const packetGenerateResult = run(scripts.approvalPacket, ["generate"]);
  const packetFile = lastNonEmptyLine(packetGenerateResult.stdout);
  const packetGenerate = {
    exitCode: packetGenerateResult.exitCode,
    packetFile,
    stdoutLines: compactLines(packetGenerateResult.stdout, 40),
    stderrLines: compactLines(packetGenerateResult.stderr, 60),
  };
  const packetCheckResult = packetFile
    ? run(scripts.approvalPacket, ["check", packetFile])
    : {
      command: `${scripts.approvalPacket} check <missing-packet>`,
      exitCode: 2,
      stdout: JSON.stringify({ status: "blocked", issues: ["packet file missing after generate"] }),
      stderr: "",
    };
  const packetCheck = stage(packetCheckResult, "approval packet check");
  const readinessResult = run(scripts.readiness, ["check"]);
  const readiness = stage(readinessResult, "live healthcheck readiness");
  const readinessStatus = readiness.report?.status || "unknown";
  const normalizedStatus = readinessStatus === "waiting_human_approval"
    ? "prepared_waiting_human_approval"
    : readinessStatus === "approved_ready_for_live_window"
      ? "prepared_approved_ready_for_live_window"
      : `prepared_${readinessStatus}`;

  return {
    schemaVersion: 1,
    status: normalizedStatus,
    mode,
    generatedAt: new Date().toISOString(),
    target: { instanceId, action: "healthcheck", operator },
    stages: {
      dryRun,
      approvalPrepare,
      packetGenerate,
      packetCheck,
      readiness,
    },
    issues: Array.isArray(readiness.report?.issues) ? readiness.report.issues : [],
    nextCommands: Array.isArray(readiness.report?.nextCommands) ? readiness.report.nextCommands : [],
    safety: safety({
      readsStatusOnly: false,
      checkRunsHealthcheckOnly: true,
    }),
  };
}

function runApproved() {
  const readinessResult = run(scripts.readiness, ["check"]);
  const readiness = stage(readinessResult, "live healthcheck readiness");
  const readinessStatus = readiness.report?.status || "unknown";
  if (readinessResult.exitCode !== 0 || readinessStatus !== "approved_ready_for_live_window") {
    return {
      schemaVersion: 1,
      status: "blocked_not_approved",
      mode,
      generatedAt: new Date().toISOString(),
      target: { instanceId, action: "healthcheck", operator },
      stages: { readiness },
      issues: [`readiness 不是 approved_ready_for_live_window：${readinessStatus}`],
      nextCommands: Array.isArray(readiness.report?.nextCommands) ? readiness.report.nextCommands : [],
      safety: safety({
        writesControlCenterRuntimeOnly: false,
        opensLiveGate: false,
        callsManagedActionsLiveApi: false,
        blockedBeforeLive: true,
      }),
    };
  }

  if (runnerConfirm !== "I_UNDERSTAND_THIS_RUNS_APPROVED_LIVE_HEALTHCHECK") {
    return {
      schemaVersion: 1,
      status: "blocked_confirmation_required",
      mode,
      generatedAt: new Date().toISOString(),
      target: { instanceId, action: "healthcheck", operator },
      stages: { readiness },
      issues: ["必须设置 CONFIRM_LIVE_HEALTHCHECK_RUNNER=I_UNDERSTAND_THIS_RUNS_APPROVED_LIVE_HEALTHCHECK"],
      nextCommands: [
        "CONFIRM_LIVE_HEALTHCHECK_RUNNER=I_UNDERSTAND_THIS_RUNS_APPROVED_LIVE_HEALTHCHECK LOCAL_API_TOKEN=<本地令牌> repo/ops/tom-readonly/live-healthcheck-rollout-runner.sh run-approved",
      ],
      safety: safety({
        writesControlCenterRuntimeOnly: false,
        opensLiveGate: false,
        callsManagedActionsLiveApi: false,
        blockedBeforeLive: true,
      }),
    };
  }

  if (!localApiToken) {
    return {
      schemaVersion: 1,
      status: "blocked_local_token_required",
      mode,
      generatedAt: new Date().toISOString(),
      target: { instanceId, action: "healthcheck", operator },
      stages: { readiness },
      issues: ["必须通过 LOCAL_API_TOKEN 提供本地令牌"],
      nextCommands: [
        "CONFIRM_LIVE_HEALTHCHECK_RUNNER=I_UNDERSTAND_THIS_RUNS_APPROVED_LIVE_HEALTHCHECK LOCAL_API_TOKEN=<本地令牌> repo/ops/tom-readonly/live-healthcheck-rollout-runner.sh run-approved",
      ],
      safety: safety({
        writesControlCenterRuntimeOnly: false,
        opensLiveGate: false,
        callsManagedActionsLiveApi: false,
        blockedBeforeLive: true,
      }),
    };
  }

  const liveWindowResult = run(scripts.liveWindow, ["run"], {
    CONFIRM_LIVE_HEALTHCHECK_WINDOW: "I_UNDERSTAND_THIS_TEMPORARILY_ENABLES_LIVE_GATE",
    CONFIRM_LIVE_HEALTHCHECK: "I_UNDERSTAND_THIS_CALLS_LIVE_API",
    LOCAL_API_TOKEN: localApiToken,
  });
  const liveWindow = {
    command: liveWindowResult.command,
    exitCode: liveWindowResult.exitCode,
    stdoutLines: compactLines(liveWindowResult.stdout, 120),
    stderrLines: compactLines(liveWindowResult.stderr, 120),
    error: liveWindowResult.error,
  };
  const postLiveVerify = liveWindowResult.exitCode === 0 ? verifyCompleted() : undefined;
  const verified = postLiveVerify?.status === "verified_live_healthcheck_completed";
  const postLiveIssues = Array.isArray(postLiveVerify?.issues) ? postLiveVerify.issues : [];

  return {
    schemaVersion: 1,
    status: liveWindowResult.exitCode === 0
      ? (verified ? "completed_live_healthcheck" : "failed_post_live_verification")
      : "failed_live_healthcheck",
    mode,
    generatedAt: new Date().toISOString(),
    target: { instanceId, action: "healthcheck", operator },
    stages: { readiness, liveWindow, postLiveVerify },
    issues: liveWindowResult.exitCode === 0 ? postLiveIssues : [`live healthcheck window 失败：exit=${liveWindowResult.exitCode}`],
    nextCommands: liveWindowResult.exitCode === 0 && verified
      ? [
        "repo/ops/tom-readonly/live-healthcheck-rollout-runner.sh verify-completed",
      ]
      : [
        "repo/ops/tom-readonly/live-healthcheck-rollout-runner.sh verify-completed",
        "repo/ops/tom-readonly/live-healthcheck-window.sh status",
        "repo/ops/tom-readonly/live-healthcheck-window.sh disable",
      ],
    safety: safety({
      readsStatusOnly: false,
      checkRunsHealthcheckOnly: true,
      requiresApprovedReadiness: true,
      requiresRunnerConfirmation: true,
    }),
  };
}

function verifyCompleted() {
  const readinessResult = run(scripts.readiness, ["check"]);
  const readiness = stage(readinessResult, "live healthcheck readiness");
  const latestReport = readLatestReport();
  const report = latestReport.report || {};
  const issues = [];
  const readinessStatus = readiness.report?.status || "unknown";
  if (readinessResult.exitCode !== 0 || readinessStatus !== "approval_consumed") {
    issues.push(`readiness 不是 approval_consumed：${readinessStatus}`);
  }
  if (latestReport.status !== "read") {
    issues.push(...(Array.isArray(latestReport.issues) ? latestReport.issues : [`报告状态异常：${latestReport.status}`]));
  }
  if (latestReport.status === "read") {
    if (report.status !== "passed") issues.push(`最新演练报告未 passed：${report.status || "unknown"}`);
    if (report.approval?.consumed !== true) issues.push("最新演练报告未证明 approval.consumed=true");
    if (report.audit?.liveResultFound !== true) issues.push("最新演练报告未找到 live result 审计");
    if (report.audit?.liveExecution !== true) issues.push("最新演练报告未证明 liveExecution=true");
    if (report.audit?.mutatesOpenClawInstance !== false) issues.push("最新演练报告未证明 mutatesOpenClawInstance=false");
    if (report.impact?.ok !== true) issues.push("最新演练报告 impact.ok 不是 true");
  }
  const verified = issues.length === 0;
  return {
    schemaVersion: 1,
    status: verified ? "verified_live_healthcheck_completed" : "blocked_post_live_verification",
    mode: "verify-completed",
    generatedAt: new Date().toISOString(),
    target: { instanceId, action: "healthcheck", operator },
    stages: { readiness, latestReport },
    issues,
    nextCommands: verified
      ? [
        "repo/ops/tom-readonly/live-healthcheck-readiness.sh check",
      ]
      : [
        "repo/ops/tom-readonly/live-healthcheck-rollout-runner.sh prepare",
        "repo/ops/tom-readonly/live-healthcheck-window.sh status",
      ],
    safety: safety({
      writesControlCenterRuntimeOnly: false,
      writesApprovalTemplateOnly: false,
      generatesApprovalPacket: false,
      opensLiveGate: false,
      callsManagedActionsLiveApi: false,
      readsStatusOnly: true,
      checkRunsHealthcheckOnly: true,
      verifiesReportOnly: true,
    }),
  };
}

function emit(report) {
  console.log(JSON.stringify(report, null, 2));
  if (mode === "prepare" && report.status === "blocked_dry_run") process.exit(2);
  if (mode === "run-approved" && String(report.status || "").startsWith("blocked_")) process.exit(2);
  if (mode === "run-approved" && (report.status === "failed_live_healthcheck" || report.status === "failed_post_live_verification")) process.exit(1);
  if (mode === "verify-completed" && report.status !== "verified_live_healthcheck_completed") process.exit(2);
}

if (mode === "status") {
  emit(statusOnly());
} else if (mode === "prepare") {
  emit(prepare());
} else if (mode === "run-approved") {
  emit(runApproved());
} else if (mode === "verify-completed") {
  emit(verifyCompleted());
} else {
  console.error(`[失败] 未知模式：${mode}`);
  process.exit(2);
}
NODE
}

main() {
  require_command node
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
    verify-completed)
      run_node "verify-completed"
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
