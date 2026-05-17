#!/usr/bin/env bash
set -euo pipefail
set +x

# OpenClaw/Discord 文本请求 inbox runner。
# 它只读取 OpenClaw workspace 中的请求文本，把执行结果写入 control-center runtime，
# 再交给 managed-action-text-bridge.sh 执行 parse/plan/dry-run。

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
export CONFIRM_MANAGED_ACTION_INBOX_RUNNER="${CONFIRM_MANAGED_ACTION_INBOX_RUNNER:-}"
export MODE_NAME="${1:-status}"

usage() {
  cat <<'TEXT'
用法：
  managed-action-inbox-runner.sh status
  managed-action-inbox-runner.sh plan-next
  managed-action-inbox-runner.sh run-next

常用环境变量：
  MANAGED_ACTION_INBOX_DIR=<inbox 目录>
  MANAGED_ACTION_INBOX_SOURCE=local|control-center-container
  MANAGED_ACTION_TEXT_BRIDGE=<managed-action-text-bridge.sh 路径>

run-next 必须设置：
  CONFIRM_MANAGED_ACTION_INBOX_RUNNER=I_UNDERSTAND_THIS_READS_OPENCLAW_INBOX_AND_RUNS_DRY_RUN_TEXT

安全边界：
  - 只读取 inbox 中的 .txt 请求。
  - 结果和处理状态只写 control-center runtime。
  - run-next 只调用 managed-action-text-bridge.sh dry-run。
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
const confirmRunner = process.env.CONFIRM_MANAGED_ACTION_INBOX_RUNNER || "";
const runnerConfirmation = "I_UNDERSTAND_THIS_READS_OPENCLAW_INBOX_AND_RUNS_DRY_RUN_TEXT";
const bridgeConfirmation = "I_UNDERSTAND_THIS_ONLY_RUNS_MANAGED_ACTION_DRY_RUN_TEXT";
const stateDir = path.join(runtimeDir, "managed-action-inbox-runner");
const statePath = path.join(stateDir, "state.json");
const resultsDir = path.join(stateDir, "results");

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
    ],
    safety: baseSafety({
      blockedBeforeBridge: true,
      ...extra,
    }),
  }, exitCode);
}

function ensureMode() {
  if (!["status", "plan-next", "run-next"].includes(mode)) {
    blocked("blocked_invalid_mode", `未知模式：${mode}。支持 status、plan-next、run-next。`);
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
    nextCommands: pending.length > 0
      ? [
        "repo/ops/tom-readonly/managed-action-inbox-runner.sh plan-next",
        `CONFIRM_MANAGED_ACTION_INBOX_RUNNER=${runnerConfirmation} MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container repo/ops/tom-readonly/managed-action-inbox-runner.sh run-next`,
      ]
      : [],
    safety: baseSafety({
      callsManagedActionsDryRunApi: false,
      writesControlCenterRuntimeOnly: false,
    }),
  });
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

ensureMode();
if (mode === "status") reportStatus();
if (mode === "plan-next") planNext();
if (mode === "run-next") runNext();
NODE
