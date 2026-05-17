#!/usr/bin/env bash
set -euo pipefail
set +x

# 安装 control-center managed action inbox dry-run 定时器。
# status/plan 不写 crontab；apply/remove 必须显式确认，只更新当前用户 crontab 中的受控标记块。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
if [ "$(basename "$DEFAULT_DEPLOY_DIR")" = "repo" ] && [ -d "${DEFAULT_DEPLOY_DIR}/../runtime" ]; then
  DEFAULT_DEPLOY_DIR="$(cd "${DEFAULT_DEPLOY_DIR}/.." && pwd)"
fi

export DEPLOY_DIR="${DEPLOY_DIR:-$DEFAULT_DEPLOY_DIR}"
export MODE_NAME="${1:-status}"
export CRONTAB_BIN="${CRONTAB_BIN:-crontab}"
export MANAGED_ACTION_INBOX_CRON_SCHEDULE="${MANAGED_ACTION_INBOX_CRON_SCHEDULE:-* * * * *}"
export MANAGED_ACTION_INBOX_CRON_LOG="${MANAGED_ACTION_INBOX_CRON_LOG:-${DEPLOY_DIR}/runtime/managed-action-inbox-cron.log}"
export MANAGED_ACTION_INBOX_DIR="${MANAGED_ACTION_INBOX_DIR:-/instances/tom/workspace/control-center-commands/inbox}"
export MANAGED_ACTION_INBOX_MAX_PER_RUN="${MANAGED_ACTION_INBOX_MAX_PER_RUN:-10}"
export CONFIRM_MANAGED_ACTION_INBOX_CRON="${CONFIRM_MANAGED_ACTION_INBOX_CRON:-}"

usage() {
  cat <<'TEXT'
用法：
  install-managed-action-inbox-cron.sh status
  install-managed-action-inbox-cron.sh plan
  install-managed-action-inbox-cron.sh apply
  install-managed-action-inbox-cron.sh remove

常用环境变量：
  MANAGED_ACTION_INBOX_CRON_SCHEDULE="* * * * *"
  MANAGED_ACTION_INBOX_CRON_LOG=/srv/openclaw-control-center-readonly/runtime/managed-action-inbox-cron.log
  MANAGED_ACTION_INBOX_DIR=/instances/tom/workspace/control-center-commands/inbox
  MANAGED_ACTION_INBOX_MAX_PER_RUN=10

apply/remove 必须设置：
  CONFIRM_MANAGED_ACTION_INBOX_CRON=I_UNDERSTAND_THIS_ONLY_INSTALLS_DRY_RUN_INBOX_CRON

安全边界：
  - 只更新当前用户 crontab 的 OPENCLAW_MANAGED_ACTION_INBOX_CRON 受控块。
  - cron 只调用 managed-action-inbox-runner.sh run-pending。
  - run-pending 只创建 dry-run 审计，不调用 live API，不修改 OpenClaw 实例目录，不重启实例。
TEXT
}

case "$MODE_NAME" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const mode = process.env.MODE_NAME || "status";
const deployDir = process.env.DEPLOY_DIR || process.cwd();
const crontabBin = process.env.CRONTAB_BIN || "crontab";
const schedule = process.env.MANAGED_ACTION_INBOX_CRON_SCHEDULE || "* * * * *";
const logPath = process.env.MANAGED_ACTION_INBOX_CRON_LOG || path.join(deployDir, "runtime", "managed-action-inbox-cron.log");
const inboxDir = process.env.MANAGED_ACTION_INBOX_DIR || "/instances/tom/workspace/control-center-commands/inbox";
const maxPerRun = process.env.MANAGED_ACTION_INBOX_MAX_PER_RUN || "10";
const confirm = process.env.CONFIRM_MANAGED_ACTION_INBOX_CRON || "";
const confirmation = "I_UNDERSTAND_THIS_ONLY_INSTALLS_DRY_RUN_INBOX_CRON";
const markerBegin = "# OPENCLAW_MANAGED_ACTION_INBOX_CRON_BEGIN";
const markerEnd = "# OPENCLAW_MANAGED_ACTION_INBOX_CRON_END";

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

function safety(extra = {}) {
  return {
    writesCrontabOnly: false,
    installsDryRunInboxCron: false,
    removesDryRunInboxCron: false,
    callsManagedActionsDryRunApi: false,
    callsManagedActionsLiveApi: false,
    writesOpenClawInstanceDirs: false,
    restartsOpenClawInstances: false,
    mutatesOpenClawInstance: false,
    opensLiveGate: false,
    ...extra,
  };
}

function emit(report, code = 0) {
  console.log(JSON.stringify(report, null, 2));
  process.exit(code);
}

function blocked(status, issue, extra = {}, code = 2) {
  emit({
    schemaVersion: 1,
    status,
    mode,
    generatedAt: new Date().toISOString(),
    issues: [issue],
    nextCommands: [
      "repo/ops/tom-readonly/install-managed-action-inbox-cron.sh status",
      "repo/ops/tom-readonly/install-managed-action-inbox-cron.sh plan",
      `CONFIRM_MANAGED_ACTION_INBOX_CRON=${confirmation} repo/ops/tom-readonly/install-managed-action-inbox-cron.sh apply`,
    ],
    safety: safety({
      blockedBeforeWrite: true,
      ...extra,
    }),
  }, code);
}

function requireMode() {
  if (!["status", "plan", "apply", "remove"].includes(mode)) {
    blocked("blocked_invalid_mode", `未知模式：${mode}。支持 status、plan、apply、remove。`);
  }
}

function readCrontab() {
  const result = spawnSync(crontabBin, ["-l"], {
    cwd: deployDir,
    encoding: "utf8",
    env: process.env,
  });
  if (result.status === 0) return result.stdout;
  if ((result.stderr || "").match(/no crontab/i) || result.status === 1) return "";
  blocked("blocked_crontab_read_failed", `无法读取 crontab：${compactLines(result.stderr || result.stdout, 5).join("；")}`);
}

function writeCrontab(content) {
  const result = spawnSync(crontabBin, ["-"], {
    cwd: deployDir,
    input: content,
    encoding: "utf8",
    env: process.env,
  });
  if (result.status !== 0) {
    blocked("blocked_crontab_write_failed", `无法写入 crontab：${compactLines(result.stderr || result.stdout, 5).join("；")}`);
  }
}

function removeBlock(existing) {
  const lines = existing.split(/\r?\n/);
  const out = [];
  let skip = false;
  for (const line of lines) {
    if (line === markerBegin) {
      skip = true;
      continue;
    }
    if (line === markerEnd) {
      skip = false;
      continue;
    }
    if (!skip) out.push(line);
  }
  return out.join("\n").replace(/\s+$/, "");
}

function cronCommand() {
  return [
    `cd ${shellQuote(deployDir)} &&`,
    `CONFIRM_MANAGED_ACTION_INBOX_RUNNER=${shellQuote("I_UNDERSTAND_THIS_READS_OPENCLAW_INBOX_AND_RUNS_DRY_RUN_TEXT")}`,
    "MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container",
    "MANAGED_ACTION_INBOX_SOURCE=control-center-container",
    `MANAGED_ACTION_INBOX_DIR=${shellQuote(inboxDir)}`,
    `MANAGED_ACTION_INBOX_MAX_PER_RUN=${shellQuote(maxPerRun)}`,
    "repo/ops/tom-readonly/managed-action-inbox-runner.sh run-pending",
    `>> ${shellQuote(logPath)} 2>&1`,
  ].join(" ");
}

function renderBlock() {
  return [
    markerBegin,
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    `${schedule} ${cronCommand()}`,
    markerEnd,
  ].join("\n");
}

function buildNext(existing) {
  const cleaned = removeBlock(existing);
  const block = renderBlock();
  return `${cleaned ? `${cleaned}\n` : ""}${block}\n`;
}

function installed(existing) {
  return existing.includes(markerBegin) && existing.includes(markerEnd);
}

function reportStatus() {
  const existing = readCrontab();
  const next = buildNext(existing);
  const isInstalled = installed(existing);
  emit({
    schemaVersion: 1,
    status: isInstalled ? (existing === next ? "inbox_cron_installed" : "inbox_cron_needs_update") : "inbox_cron_not_installed",
    mode,
    generatedAt: new Date().toISOString(),
    installed: isInstalled,
    needsUpdate: existing !== next,
    schedule,
    logPath,
    inboxDir,
    maxPerRun,
    safety: safety(),
  });
}

function reportPlan() {
  const existing = readCrontab();
  const next = buildNext(existing);
  emit({
    schemaVersion: 1,
    status: "inbox_cron_plan_ready",
    mode,
    generatedAt: new Date().toISOString(),
    installed: installed(existing),
    needsUpdate: existing !== next,
    schedule,
    logPath,
    inboxDir,
    maxPerRun,
    block: renderBlock(),
    nextCommands: existing !== next
      ? [`CONFIRM_MANAGED_ACTION_INBOX_CRON=${confirmation} repo/ops/tom-readonly/install-managed-action-inbox-cron.sh apply`]
      : [],
    safety: safety(),
  });
}

function applyCron() {
  if (confirm !== confirmation) {
    blocked("blocked_confirmation_required", `apply 必须设置 CONFIRM_MANAGED_ACTION_INBOX_CRON=${confirmation}。`);
  }
  const runner = path.join(deployDir, "repo", "ops", "tom-readonly", "managed-action-inbox-runner.sh");
  if (!fs.existsSync(runner)) {
    blocked("blocked_runner_missing", `managed-action-inbox-runner.sh 不存在：${runner}`);
  }
  fs.mkdirSync(path.dirname(logPath), { recursive: true });
  const existing = readCrontab();
  const next = buildNext(existing);
  writeCrontab(next);
  emit({
    schemaVersion: 1,
    status: "inbox_cron_installed",
    mode,
    generatedAt: new Date().toISOString(),
    schedule,
    logPath,
    inboxDir,
    maxPerRun,
    safety: safety({
      writesCrontabOnly: true,
      installsDryRunInboxCron: true,
      callsManagedActionsDryRunApi: false,
      callsManagedActionsLiveApi: false,
      writesOpenClawInstanceDirs: false,
      restartsOpenClawInstances: false,
      opensLiveGate: false,
    }),
  });
}

function removeCron() {
  if (confirm !== confirmation) {
    blocked("blocked_confirmation_required", `remove 必须设置 CONFIRM_MANAGED_ACTION_INBOX_CRON=${confirmation}。`);
  }
  const existing = readCrontab();
  const cleaned = `${removeBlock(existing)}\n`.replace(/^\n$/, "");
  writeCrontab(cleaned);
  emit({
    schemaVersion: 1,
    status: "inbox_cron_removed",
    mode,
    generatedAt: new Date().toISOString(),
    safety: safety({
      writesCrontabOnly: true,
      removesDryRunInboxCron: true,
      callsManagedActionsLiveApi: false,
      writesOpenClawInstanceDirs: false,
      restartsOpenClawInstances: false,
      opensLiveGate: false,
    }),
  });
}

requireMode();
if (mode === "status") reportStatus();
if (mode === "plan") reportPlan();
if (mode === "apply") applyCron();
if (mode === "remove") removeCron();
NODE
