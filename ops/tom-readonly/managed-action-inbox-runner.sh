#!/usr/bin/env bash
set -euo pipefail
set +x

# OpenClaw/Discord 文本请求 inbox runner。
# 它只读取 OpenClaw workspace 中的请求文本，把执行结果写入 control-center runtime，
# 再交给 managed-action-text-bridge.sh 执行 parse/plan/dry-run；live 只能复用已完成 dry-run 审计。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
if [ "$(basename "$DEFAULT_DEPLOY_DIR")" = "repo" ] && [ -d "${DEFAULT_DEPLOY_DIR}/../runtime" ]; then
  DEFAULT_DEPLOY_DIR="$(cd "${DEFAULT_DEPLOY_DIR}/.." && pwd)"
fi
export DEPLOY_DIR="${DEPLOY_DIR:-$DEFAULT_DEPLOY_DIR}"
export RUNTIME_DIR="${RUNTIME_DIR:-${DEPLOY_DIR}/runtime}"
export MANAGED_ACTION_INBOX_DIR="${MANAGED_ACTION_INBOX_DIR:-${RUNTIME_DIR}/managed-action-inbox}"
export MANAGED_ACTION_INBOX_SOURCE="${MANAGED_ACTION_INBOX_SOURCE:-local}"
export MANAGED_ACTION_TEXT_BRIDGE="${MANAGED_ACTION_TEXT_BRIDGE:-${SCRIPT_DIR}/managed-action-text-bridge.sh}"
export MANAGED_ACTION_COMMAND_RUNNER="${MANAGED_ACTION_COMMAND_RUNNER:-${SCRIPT_DIR}/managed-action-command-runner.sh}"
export CONFIRM_MANAGED_ACTION_INBOX_RUNNER="${CONFIRM_MANAGED_ACTION_INBOX_RUNNER:-}"
export CONFIRM_MANAGED_ACTION_INBOX_LIVE_RUNNER="${CONFIRM_MANAGED_ACTION_INBOX_LIVE_RUNNER:-}"
export MODE_NAME="${1:-status}"

usage() {
  cat <<'TEXT'
用法：
  managed-action-inbox-runner.sh status
  managed-action-inbox-runner.sh plan-next
  managed-action-inbox-runner.sh run-next
  managed-action-inbox-runner.sh run-pending
  managed-action-inbox-runner.sh run-live-next

常用环境变量：
  MANAGED_ACTION_INBOX_DIR=<inbox 目录>
  MANAGED_ACTION_INBOX_SOURCE=local|control-center-container
  MANAGED_ACTION_TEXT_BRIDGE=<managed-action-text-bridge.sh 路径>
  MANAGED_ACTION_INBOX_MAX_PER_RUN=10

run-next/run-pending 必须设置：
  CONFIRM_MANAGED_ACTION_INBOX_RUNNER=I_UNDERSTAND_THIS_READS_OPENCLAW_INBOX_AND_RUNS_DRY_RUN_TEXT

run-live-next 必须设置：
  CONFIRM_MANAGED_ACTION_INBOX_LIVE_RUNNER=I_UNDERSTAND_THIS_PROMOTES_LATEST_INBOX_DRY_RUN_TO_SKILL_RUN_LIVE

安全边界：
  - 只读取 inbox 中的 .txt 请求。
  - 结果和处理状态只写 control-center runtime。
  - run-next/run-pending 只调用 managed-action-text-bridge.sh dry-run。
  - run-live-next 只会读取最近一次成功 dry-run 结果，并显式调用 managed-action-command-runner.sh live。
  - 不修改 OpenClaw 实例目录，不重启实例，不打开 live gate。
TEXT
}

case "$MODE_NAME" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

node <<'NODE'
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const mode = process.env.MODE_NAME || "status";
const deployDir = process.env.DEPLOY_DIR || process.cwd();
const runtimeDir = process.env.RUNTIME_DIR || path.join(deployDir, "runtime");
const inboxDir = process.env.MANAGED_ACTION_INBOX_DIR || path.join(runtimeDir, "managed-action-inbox");
const inboxSource = process.env.MANAGED_ACTION_INBOX_SOURCE || "local";
const bridgeScript = process.env.MANAGED_ACTION_TEXT_BRIDGE || path.join(deployDir, "repo", "ops", "tom-readonly", "managed-action-text-bridge.sh");
const commandRunnerScript = process.env.MANAGED_ACTION_COMMAND_RUNNER || path.join(deployDir, "repo", "ops", "tom-readonly", "managed-action-command-runner.sh");
const confirmRunner = process.env.CONFIRM_MANAGED_ACTION_INBOX_RUNNER || "";
const confirmLiveRunner = process.env.CONFIRM_MANAGED_ACTION_INBOX_LIVE_RUNNER || "";
const maxPerRun = Math.max(1, Number.parseInt(process.env.MANAGED_ACTION_INBOX_MAX_PER_RUN || "10", 10) || 10);
const runnerConfirmation = "I_UNDERSTAND_THIS_READS_OPENCLAW_INBOX_AND_RUNS_DRY_RUN_TEXT";
const liveRunnerConfirmation = "I_UNDERSTAND_THIS_PROMOTES_LATEST_INBOX_DRY_RUN_TO_SKILL_RUN_LIVE";
const bridgeConfirmation = "I_UNDERSTAND_THIS_ONLY_RUNS_MANAGED_ACTION_DRY_RUN_TEXT";
const stateDir = path.join(runtimeDir, "managed-action-inbox-runner");
const statePath = path.join(stateDir, "state.json");
const resultsDir = path.join(stateDir, "results");
const liveResultsDir = path.join(stateDir, "live-results");

function compactLines(text, limit = 40) {
  return String(text || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, limit);
}

function baseSafety(extra = {}) {
  return {
    readsOpenClawInboxOnly: true,
    writesControlCenterRuntimeOnly: false,
    invokesTextBridge: false,
    callsManagedActionsDryRunApi: false,
    callsManagedActionsLiveApi: false,
    writesOpenClawInstanceDirs: false,
    restartsOpenClawInstances: false,
    mutatesOpenClawInstance: false,
    opensLiveGate: false,
    ...extra,
  };
}

function emit(report, exitCode = 0) {
  console.log(JSON.stringify(report, null, 2));
  process.exit(exitCode);
}

function blocked(status, issue, extra = {}, exitCode = 2) {
  emit({
    schemaVersion: 1,
    status,
    mode,
    generatedAt: new Date().toISOString(),
    issues: [issue],
    nextCommands: [
      "repo/ops/tom-readonly/managed-action-inbox-runner.sh status",
      "repo/ops/tom-readonly/managed-action-inbox-runner.sh plan-next",
      `CONFIRM_MANAGED_ACTION_INBOX_RUNNER=${runnerConfirmation} MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container repo/ops/tom-readonly/managed-action-inbox-runner.sh run-next`,
      `CONFIRM_MANAGED_ACTION_INBOX_RUNNER=${runnerConfirmation} MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container repo/ops/tom-readonly/managed-action-inbox-runner.sh run-pending`,
      `CONFIRM_MANAGED_ACTION_INBOX_LIVE_RUNNER=${liveRunnerConfirmation} CONFIRM_MANAGED_ACTION_COMMAND_LIVE=I_UNDERSTAND_THIS_CALLS_MANAGED_ACTION_LIVE_API CONFIRM_MANAGED_ACTION_COMMAND_SKILL_RUN_LIVE=I_UNDERSTAND_THIS_MAY_RUN_OPENCLAW_SKILL_ON_ALLOWED_INSTANCE MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container repo/ops/tom-readonly/managed-action-inbox-runner.sh run-live-next`,
    ],
    safety: baseSafety({
      blockedBeforeBridge: true,
      ...extra,
    }),
  }, exitCode);
}

function ensureMode() {
  if (!["status", "plan-next", "run-next", "run-pending", "run-live-next"].includes(mode)) {
    blocked("blocked_invalid_mode", `未知模式：${mode}。支持 status、plan-next、run-next、run-pending、run-live-next。`);
  }
}

function listInboxFiles() {
  if (inboxSource === "local") {
    if (!fs.existsSync(inboxDir)) return [];
    return fs.readdirSync(inboxDir)
      .filter((name) => name.endsWith(".txt"))
      .map((name) => path.join(inboxDir, name))
      .filter((filePath) => fs.statSync(filePath).isFile())
      .sort();
  }
  if (inboxSource === "control-center-container") {
    const result = spawnSync("docker", [
      "compose",
      "exec",
      "-T",
      "-e",
      `MANAGED_ACTION_INBOX_DIR=${inboxDir}`,
      "control-center",
      "sh",
      "-lc",
      'if [ -d "$MANAGED_ACTION_INBOX_DIR" ]; then find "$MANAGED_ACTION_INBOX_DIR" -maxdepth 1 -type f -name "*.txt" -print | sort; fi',
    ], {
      cwd: deployDir,
      encoding: "utf8",
      env: process.env,
    });
    if (result.status !== 0) {
      blocked("blocked_inbox_source_unavailable", `无法从 control-center 容器读取 inbox：${compactLines(result.stderr || result.stdout, 5).join("；")}`);
    }
    return result.stdout.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  }
  blocked("blocked_invalid_inbox_source", `未知 MANAGED_ACTION_INBOX_SOURCE：${inboxSource}`);
}

function readInboxFile(filePath) {
  if (inboxSource === "local") {
    return fs.readFileSync(filePath, "utf8");
  }
  if (inboxSource === "control-center-container") {
    if (!filePath.startsWith(`${inboxDir.replace(/\/+$/, "")}/`)) {
      blocked("blocked_invalid_inbox_path", "容器 inbox 文件路径不在 MANAGED_ACTION_INBOX_DIR 内。");
    }
    const result = spawnSync("docker", [
      "compose",
      "exec",
      "-T",
      "-e",
      `MANAGED_ACTION_SOURCE_PATH=${filePath}`,
      "control-center",
      "sh",
      "-lc",
      'cat -- "$MANAGED_ACTION_SOURCE_PATH"',
    ], {
      cwd: deployDir,
      encoding: "utf8",
      env: process.env,
      maxBuffer: 1024 * 1024,
    });
    if (result.status !== 0) {
      blocked("blocked_inbox_read_failed", `无法读取 inbox 文件：${compactLines(result.stderr || result.stdout, 5).join("；")}`);
    }
    return result.stdout;
  }
  blocked("blocked_invalid_inbox_source", `未知 MANAGED_ACTION_INBOX_SOURCE：${inboxSource}`);
}

function sourceKey(sourcePath, text) {
  return crypto.createHash("sha256").update(sourcePath).update("\0").update(text).digest("hex");
}

function loadState() {
  if (!fs.existsSync(statePath)) return { schemaVersion: 1, processed: [] };
  try {
    const parsed = JSON.parse(fs.readFileSync(statePath, "utf8"));
    return {
      schemaVersion: 1,
      processed: Array.isArray(parsed.processed) ? parsed.processed : [],
    };
  } catch {
    return { schemaVersion: 1, processed: [] };
  }
}

function saveState(state) {
  fs.mkdirSync(stateDir, { recursive: true });
  fs.writeFileSync(statePath, JSON.stringify({
    schemaVersion: 1,
    updatedAt: new Date().toISOString(),
    processed: state.processed.slice(-200),
  }, null, 2));
}

function findNext() {
  const state = loadState();
  const processedKeys = new Set(state.processed.map((item) => item.key).filter(Boolean));
  const candidates = listInboxFiles();
  const pending = [];
  for (const sourcePath of candidates) {
    const text = readInboxFile(sourcePath);
    const key = sourceKey(sourcePath, text);
    if (!processedKeys.has(key)) {
      pending.push({
        sourcePath,
        key,
        size: Buffer.byteLength(text, "utf8"),
        text,
      });
    }
  }
  return { state, candidates, pending, next: pending[0] };
}

function writeBridgeInput(next) {
  fs.mkdirSync(stateDir, { recursive: true });
  const inputPath = path.join(stateDir, "current-command.txt");
  fs.writeFileSync(inputPath, next.text.endsWith("\n") ? next.text : `${next.text}\n`, "utf8");
  return inputPath;
}

function runBridge(bridgeMode, inputPath) {
  const env = {
    ...process.env,
    DEPLOY_DIR: deployDir,
    RUNTIME_DIR: runtimeDir,
  };
  if (bridgeMode === "dry-run") {
    env.CONFIRM_MANAGED_ACTION_TEXT_BRIDGE = env.CONFIRM_MANAGED_ACTION_TEXT_BRIDGE || bridgeConfirmation;
  }
  const result = spawnSync(bridgeScript, [bridgeMode, inputPath], {
    cwd: deployDir,
    env,
    encoding: "utf8",
    maxBuffer: 1024 * 1024,
  });
  let report;
  try {
    report = result.stdout.trim() ? JSON.parse(result.stdout) : { status: "missing_bridge_output" };
  } catch (error) {
    report = {
      status: "invalid_bridge_output",
      issues: [error instanceof Error ? error.message : String(error)],
      rawLines: compactLines(result.stdout, 40),
    };
  }
  return { exitCode: typeof result.status === "number" ? result.status : 1, stdout: result.stdout, stderr: result.stderr, report };
}

function runCommandRunnerLive(commandPath) {
  const env = {
    ...process.env,
    DEPLOY_DIR: deployDir,
    RUNTIME_DIR: runtimeDir,
    CONFIRM_MANAGED_ACTION_COMMAND_LIVE: process.env.CONFIRM_MANAGED_ACTION_COMMAND_LIVE || "I_UNDERSTAND_THIS_CALLS_MANAGED_ACTION_LIVE_API",
    CONFIRM_MANAGED_ACTION_COMMAND_SKILL_RUN_LIVE: process.env.CONFIRM_MANAGED_ACTION_COMMAND_SKILL_RUN_LIVE || "I_UNDERSTAND_THIS_MAY_RUN_OPENCLAW_SKILL_ON_ALLOWED_INSTANCE",
  };
  const result = spawnSync(commandRunnerScript, ["live", commandPath], {
    cwd: deployDir,
    env,
    encoding: "utf8",
    maxBuffer: 1024 * 1024,
  });
  let report;
  try {
    report = result.stdout.trim() ? JSON.parse(result.stdout) : { status: "missing_live_runner_output" };
  } catch (error) {
    report = {
      status: "invalid_live_runner_output",
      issues: [error instanceof Error ? error.message : String(error)],
      rawLines: compactLines(result.stdout, 40),
    };
  }
  return { exitCode: typeof result.status === "number" ? result.status : 1, stdout: result.stdout, stderr: result.stderr, report };
}

function resultName(next) {
  const safeBase = path.basename(next.sourcePath).replace(/[^A-Za-z0-9_.-]+/g, "_").slice(0, 80) || "command.txt";
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  return `${timestamp}-${safeBase}.json`;
}

function saveResult(next, bridge, status) {
  fs.mkdirSync(resultsDir, { recursive: true });
  const resultPath = path.join(resultsDir, resultName(next));
  fs.writeFileSync(resultPath, JSON.stringify({
    schemaVersion: 1,
    status,
    generatedAt: new Date().toISOString(),
    sourcePath: next.sourcePath,
    sourceKey: next.key,
    bridgeExitCode: bridge.exitCode,
    bridgeReport: bridge.report,
  }, null, 2));
  return resultPath;
}

function saveLiveResult(dryRunResult, live, status, commandPath) {
  fs.mkdirSync(liveResultsDir, { recursive: true });
  const sourceBase = path.basename(dryRunResult.sourcePath || "inbox-dry-run").replace(/[^A-Za-z0-9_.-]+/g, "_").slice(0, 80);
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const resultPath = path.join(liveResultsDir, `${timestamp}-${sourceBase}.json`);
  fs.writeFileSync(resultPath, JSON.stringify({
    schemaVersion: 1,
    status,
    generatedAt: new Date().toISOString(),
    sourcePath: dryRunResult.sourcePath,
    sourceKey: dryRunResult.sourceKey,
    dryRunResultPath: dryRunResult.resultPath,
    liveCommandPath: commandPath,
    liveExitCode: live.exitCode,
    liveReport: live.report,
  }, null, 2));
  return resultPath;
}

function markProcessed(state, next, bridge, status, resultPath) {
  state.processed.push({
    key: next.key,
    sourcePath: next.sourcePath,
    processedAt: new Date().toISOString(),
    status,
    bridgeStatus: bridge.report?.status || "unknown",
    runnerStatus: bridge.report?.runnerStatus || "unknown",
    resultPath,
  });
  saveState(state);
}

function summary(status, next, bridge, resultPath, extraSafety = {}) {
  const bridgeReport = bridge?.report || {};
  const bridgeSafety = bridgeReport.safety || {};
  return {
    schemaVersion: 1,
    status,
    mode,
    generatedAt: new Date().toISOString(),
    sourcePath: next.sourcePath,
    sourceKey: next.key,
    bridgeStatus: bridgeReport.status || "unknown",
    runnerStatus: bridgeReport.runnerStatus || "unknown",
    bridgeExitCode: bridge.exitCode,
    ...(bridgeReport.target ? { target: bridgeReport.target } : {}),
    ...(bridgeReport.operationRequestId ? { operationRequestId: bridgeReport.operationRequestId } : {}),
    ...(Array.isArray(bridgeReport.commandPreview) ? { commandPreview: bridgeReport.commandPreview } : {}),
    ...(Array.isArray(bridgeReport.issues) ? { issues: bridgeReport.issues } : {}),
    ...(resultPath ? { resultPath } : {}),
    safety: baseSafety({
      invokesTextBridge: true,
      writesControlCenterRuntimeOnly: Boolean(resultPath),
      callsManagedActionsDryRunApi: bridgeSafety.callsManagedActionsDryRunApi === true,
      callsManagedActionsLiveApi: false,
      writesOpenClawInstanceDirs: false,
      restartsOpenClawInstances: false,
      mutatesOpenClawInstance: false,
      opensLiveGate: false,
      ...extraSafety,
    }),
  };
}

function reportStatus() {
  const { candidates, pending, next } = findNext();
  const latestDryRun = findLatestSuccessfulDryRunResult();
  emit({
    schemaVersion: 1,
    status: pending.length > 0 ? "inbox_status_ready" : "inbox_empty",
    mode,
    generatedAt: new Date().toISOString(),
    inbox: {
      source: inboxSource,
      dir: inboxDir,
      candidateCount: candidates.length,
    },
    pendingCount: pending.length,
    ...(next ? { next: { sourcePath: next.sourcePath, sourceKey: next.key, size: next.size } } : {}),
    ...(latestDryRun ? {
      latestDryRun: {
        sourcePath: latestDryRun.sourcePath,
        operationRequestId: latestDryRun.operationRequestId,
        resultPath: latestDryRun.resultPath,
      },
    } : {}),
    nextCommands: pending.length > 0
      ? [
        "repo/ops/tom-readonly/managed-action-inbox-runner.sh plan-next",
        `CONFIRM_MANAGED_ACTION_INBOX_RUNNER=${runnerConfirmation} MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container repo/ops/tom-readonly/managed-action-inbox-runner.sh run-next`,
        `CONFIRM_MANAGED_ACTION_INBOX_RUNNER=${runnerConfirmation} MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container repo/ops/tom-readonly/managed-action-inbox-runner.sh run-pending`,
      ]
      : (latestDryRun ? [`CONFIRM_MANAGED_ACTION_INBOX_LIVE_RUNNER=${liveRunnerConfirmation} CONFIRM_MANAGED_ACTION_COMMAND_LIVE=I_UNDERSTAND_THIS_CALLS_MANAGED_ACTION_LIVE_API CONFIRM_MANAGED_ACTION_COMMAND_SKILL_RUN_LIVE=I_UNDERSTAND_THIS_MAY_RUN_OPENCLAW_SKILL_ON_ALLOWED_INSTANCE MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container repo/ops/tom-readonly/managed-action-inbox-runner.sh run-live-next`] : []),
    safety: baseSafety({
      callsManagedActionsDryRunApi: false,
      writesControlCenterRuntimeOnly: false,
    }),
  });
}

function findLatestSuccessfulDryRunResult() {
  if (!fs.existsSync(resultsDir)) return undefined;
  const files = fs.readdirSync(resultsDir)
    .filter((name) => name.endsWith(".json"))
    .map((name) => path.join(resultsDir, name))
    .sort()
    .reverse();
  for (const file of files) {
    try {
      const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
      const bridge = parsed.bridgeReport || {};
      const payload = bridge.payload || bridge.command || {};
      const operationRequestId = bridge.operationRequestId;
      if (parsed.status !== "inbox_dry_run_completed") continue;
      if (bridge.runnerStatus !== "dry_run_completed") continue;
      if (!operationRequestId || !payload || payload.action !== "skill_run") continue;
      return {
        resultPath: file,
        sourcePath: parsed.sourcePath,
        sourceKey: parsed.sourceKey,
        operationRequestId,
        payload,
      };
    } catch {
      continue;
    }
  }
  return undefined;
}

function runLiveNext() {
  if (confirmLiveRunner !== liveRunnerConfirmation) {
    blocked("blocked_live_confirmation_required", `run-live-next 必须设置 CONFIRM_MANAGED_ACTION_INBOX_LIVE_RUNNER=${liveRunnerConfirmation}。`);
  }
  const dryRunResult = findLatestSuccessfulDryRunResult();
  if (!dryRunResult) {
    emit({
      schemaVersion: 1,
      status: "blocked_no_successful_inbox_dry_run",
      mode,
      generatedAt: new Date().toISOString(),
      issues: ["没有可晋升为 live 的成功 inbox dry-run 结果。"],
      nextCommands: [
        "repo/ops/tom-readonly/managed-action-inbox-runner.sh status",
        `CONFIRM_MANAGED_ACTION_INBOX_RUNNER=${runnerConfirmation} MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container repo/ops/tom-readonly/managed-action-inbox-runner.sh run-next`,
      ],
      safety: baseSafety({
        blockedBeforeLiveApi: true,
        callsManagedActionsLiveApi: false,
      }),
    }, 2);
  }
  fs.mkdirSync(stateDir, { recursive: true });
  const commandPath = path.join(stateDir, "current-live-command.json");
  fs.writeFileSync(commandPath, JSON.stringify({
    ...dryRunResult.payload,
    operationRequestId: dryRunResult.operationRequestId,
  }, null, 2));
  const live = runCommandRunnerLive(commandPath);
  const ok = live.exitCode === 0 && live.report?.status === "live_completed";
  const status = ok ? "inbox_live_completed" : "blocked_inbox_live";
  const resultPath = saveLiveResult(dryRunResult, live, status, commandPath);
  const liveSafety = live.report?.safety || {};
  emit({
    schemaVersion: 1,
    status,
    mode,
    generatedAt: new Date().toISOString(),
    sourcePath: dryRunResult.sourcePath,
    sourceKey: dryRunResult.sourceKey,
    dryRunResultPath: dryRunResult.resultPath,
    operationRequestId: dryRunResult.operationRequestId,
    liveStatus: live.report?.status || "unknown",
    liveExitCode: live.exitCode,
    ...(live.report?.target ? { target: live.report.target } : {}),
    ...(live.report?.liveApi?.body?.message ? { message: live.report.liveApi.body.message } : {}),
    ...(Array.isArray(live.report?.issues) ? { issues: live.report.issues } : {}),
    resultPath,
    safety: baseSafety({
      writesControlCenterRuntimeOnly: true,
      callsManagedActionsLiveApi: liveSafety.callsManagedActionsLiveApi === true,
      writesOpenClawInstanceDirs: liveSafety.writesOpenClawInstanceDirs === true,
      restartsOpenClawInstances: liveSafety.restartsOpenClawInstances === true,
      mutatesOpenClawInstance: liveSafety.mutatesOpenClawInstance === true,
      opensLiveGate: false,
      requiresLiveConfirmation: true,
    }),
  }, ok ? 0 : 2);
}

function planNext() {
  const { pending, next } = findNext();
  if (!next) {
    emit({
      schemaVersion: 1,
      status: "inbox_empty",
      mode,
      generatedAt: new Date().toISOString(),
      pendingCount: 0,
      safety: baseSafety(),
    });
  }
  const inputPath = writeBridgeInput(next);
  const bridge = runBridge("plan", inputPath);
  const report = summary(bridge.exitCode === 0 ? "inbox_plan_completed" : "blocked_inbox_bridge", next, bridge, undefined, {
    writesControlCenterRuntimeOnly: false,
    callsManagedActionsDryRunApi: false,
  });
  report.pendingCount = pending.length;
  emit(report, bridge.exitCode === 0 ? 0 : 2);
}

function runNext() {
  if (confirmRunner !== runnerConfirmation) {
    blocked("blocked_confirmation_required", `run-next 必须设置 CONFIRM_MANAGED_ACTION_INBOX_RUNNER=${runnerConfirmation}。`);
  }
  const { state, pending, next } = findNext();
  if (!next) {
    emit({
      schemaVersion: 1,
      status: "inbox_empty",
      mode,
      generatedAt: new Date().toISOString(),
      pendingCount: 0,
      safety: baseSafety(),
    });
  }
  const inputPath = writeBridgeInput(next);
  const bridge = runBridge("dry-run", inputPath);
  const ok = bridge.exitCode === 0 && bridge.report?.status === "bridge_dry_run_completed";
  const invalidCommandBlocked = bridge.report?.runnerStatus === "blocked_invalid_command";
  const status = ok ? "inbox_dry_run_completed" : "blocked_inbox_bridge";
  const resultPath = saveResult(next, bridge, status);
  if (ok || invalidCommandBlocked) {
    markProcessed(state, next, bridge, status, resultPath);
  }
  const report = summary(status, next, bridge, resultPath, {
    writesControlCenterRuntimeOnly: true,
  });
  report.pendingCount = pending.length;
  emit(report, ok ? 0 : 2);
}

function runPending() {
  if (confirmRunner !== runnerConfirmation) {
    blocked("blocked_confirmation_required", `run-pending 必须设置 CONFIRM_MANAGED_ACTION_INBOX_RUNNER=${runnerConfirmation}。`);
  }
  const initial = findNext();
  if (!initial.next) {
    emit({
      schemaVersion: 1,
      status: "inbox_empty",
      mode,
      generatedAt: new Date().toISOString(),
      pendingCountBefore: 0,
      pendingCountAfter: 0,
      processedCount: 0,
      safety: baseSafety(),
    });
  }

  const summaries = [];
  let processedCount = 0;
  let blockedReport = null;
  while (processedCount < maxPerRun) {
    const { state, next } = findNext();
    if (!next) break;
    const inputPath = writeBridgeInput(next);
    const bridge = runBridge("dry-run", inputPath);
    const ok = bridge.exitCode === 0 && bridge.report?.status === "bridge_dry_run_completed";
    const invalidCommandBlocked = bridge.report?.runnerStatus === "blocked_invalid_command";
    const status = ok ? "inbox_dry_run_completed" : "blocked_inbox_bridge";
    const resultPath = saveResult(next, bridge, status);
    if (ok || invalidCommandBlocked) {
      markProcessed(state, next, bridge, status, resultPath);
      processedCount += 1;
    }
    const item = summary(status, next, bridge, resultPath, {
      writesControlCenterRuntimeOnly: true,
    });
    summaries.push(item);
    if (!ok && !invalidCommandBlocked) {
      blockedReport = item;
      break;
    }
  }

  const after = findNext();
  const callsDryRun = summaries.some((item) => item.safety?.callsManagedActionsDryRunApi === true);
  emit({
    schemaVersion: 1,
    status: blockedReport ? "blocked_inbox_run_pending" : "inbox_run_pending_completed",
    mode,
    generatedAt: new Date().toISOString(),
    pendingCountBefore: initial.pending.length,
    pendingCountAfter: after.pending.length,
    processedCount,
    maxPerRun,
    results: summaries.map((item) => ({
      status: item.status,
      sourcePath: item.sourcePath,
      sourceKey: item.sourceKey,
      bridgeStatus: item.bridgeStatus,
      runnerStatus: item.runnerStatus,
      bridgeExitCode: item.bridgeExitCode,
      ...(item.target ? { target: item.target } : {}),
      ...(item.operationRequestId ? { operationRequestId: item.operationRequestId } : {}),
      ...(item.commandPreview ? { commandPreview: item.commandPreview } : {}),
      ...(item.issues ? { issues: item.issues } : {}),
      ...(item.resultPath ? { resultPath: item.resultPath } : {}),
    })),
    safety: baseSafety({
      invokesTextBridge: summaries.length > 0,
      writesControlCenterRuntimeOnly: summaries.length > 0,
      callsManagedActionsDryRunApi: callsDryRun,
      callsManagedActionsLiveApi: false,
      writesOpenClawInstanceDirs: false,
      restartsOpenClawInstances: false,
      mutatesOpenClawInstance: false,
      opensLiveGate: false,
    }),
  }, blockedReport ? 2 : 0);
}

ensureMode();
if (mode === "status") reportStatus();
if (mode === "plan-next") planNext();
if (mode === "run-next") runNext();
if (mode === "run-pending") runPending();
if (mode === "run-live-next") runLiveNext();
NODE
