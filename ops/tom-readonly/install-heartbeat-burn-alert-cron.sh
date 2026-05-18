#!/usr/bin/env bash
set -euo pipefail
set +x

# 安装 heartbeat/token 异常用量告警 cron。
# status/plan 不写 crontab；apply/remove 必须显式确认，只更新当前用户 crontab 中的受控标记块。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
if [ "$(basename "$DEFAULT_DEPLOY_DIR")" = "repo" ] && [ -d "${DEFAULT_DEPLOY_DIR}/../runtime" ]; then
  DEFAULT_DEPLOY_DIR="$(cd "${DEFAULT_DEPLOY_DIR}/.." && pwd)"
fi

export DEPLOY_DIR="${DEPLOY_DIR:-$DEFAULT_DEPLOY_DIR}"
export MODE_NAME="${1:-status}"
export CRONTAB_BIN="${CRONTAB_BIN:-crontab}"
export HEARTBEAT_BURN_ALERT_CRON_SCHEDULE="${HEARTBEAT_BURN_ALERT_CRON_SCHEDULE:-*/15 * * * *}"
export HEARTBEAT_BURN_ALERT_CRON_LOG="${HEARTBEAT_BURN_ALERT_CRON_LOG:-${DEPLOY_DIR}/runtime/heartbeat-burn-alert-cron.log}"
export HEARTBEAT_BURN_ALERT_INSTANCE_IDS="${HEARTBEAT_BURN_ALERT_INSTANCE_IDS:-}"
export CONFIRM_HEARTBEAT_BURN_ALERT_CRON="${CONFIRM_HEARTBEAT_BURN_ALERT_CRON:-}"

usage() {
  cat <<'TEXT'
用法：
  install-heartbeat-burn-alert-cron.sh status
  install-heartbeat-burn-alert-cron.sh plan
  install-heartbeat-burn-alert-cron.sh apply
  install-heartbeat-burn-alert-cron.sh remove

常用环境变量：
  HEARTBEAT_BURN_ALERT_CRON_SCHEDULE="*/15 * * * *"
  HEARTBEAT_BURN_ALERT_INSTANCE_IDS="deepseek"  # 留空表示检查全部实例
  HEARTBEAT_BURN_ALERT_CRON_LOG=/srv/openclaw-control-center-readonly/runtime/heartbeat-burn-alert-cron.log

apply/remove 必须设置：
  CONFIRM_HEARTBEAT_BURN_ALERT_CRON=I_UNDERSTAND_THIS_ONLY_INSTALLS_READONLY_HEARTBEAT_BURN_ALERT_CRON

安全边界：
  - 只更新当前用户 crontab 的 OPENCLAW_HEARTBEAT_BURN_ALERT_CRON 受控块。
  - cron 只调用 heartbeat-burn-alert-runner.sh run。
  - runner 只写 control-center runtime 告警报告。
  - 不写 OpenClaw 实例目录，不清空 HEARTBEAT.md，不调用模型，不重启实例，不打开 live gate。
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
const schedule = process.env.HEARTBEAT_BURN_ALERT_CRON_SCHEDULE || "*/15 * * * *";
const logPath = process.env.HEARTBEAT_BURN_ALERT_CRON_LOG || path.join(deployDir, "runtime", "heartbeat-burn-alert-cron.log");
const instanceIds = process.env.HEARTBEAT_BURN_ALERT_INSTANCE_IDS || "";
const confirm = process.env.CONFIRM_HEARTBEAT_BURN_ALERT_CRON || "";
const confirmation = "I_UNDERSTAND_THIS_ONLY_INSTALLS_READONLY_HEARTBEAT_BURN_ALERT_CRON";
const markerBegin = "# OPENCLAW_HEARTBEAT_BURN_ALERT_CRON_BEGIN";
const markerEnd = "# OPENCLAW_HEARTBEAT_BURN_ALERT_CRON_END";

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function safety(extra = {}) {
  return {
    writesCrontabOnly: false,
    installsReadonlyHeartbeatBurnAlertCron: false,
    removesReadonlyHeartbeatBurnAlertCron: false,
    writesControlCenterRuntimeOnly: false,
    callsManagedActionsDryRunApi: false,
    callsManagedActionsLiveApi: false,
    writesOpenClawInstanceDirs: false,
    clearsHeartbeatFiles: false,
    callsModelApis: false,
    restartsOpenClawInstances: false,
    opensLiveGate: false,
    ...extra,
  };
}

function compactLines(text, limit = 8) {
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

function blocked(status, issue, extra = {}, code = 2) {
  emit({
    schemaVersion: 1,
    status,
    mode,
    generatedAt: new Date().toISOString(),
    issues: [issue],
    nextCommands: [
      "repo/ops/tom-readonly/install-heartbeat-burn-alert-cron.sh status",
      "repo/ops/tom-readonly/install-heartbeat-burn-alert-cron.sh plan",
      `CONFIRM_HEARTBEAT_BURN_ALERT_CRON=${confirmation} repo/ops/tom-readonly/install-heartbeat-burn-alert-cron.sh apply`,
    ],
    safety: safety({ blockedBeforeWrite: true, ...extra }),
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
  blocked("blocked_crontab_read_failed", `无法读取 crontab：${compactLines(result.stderr || result.stdout).join("；")}`);
}

function writeCrontab(content) {
  const result = spawnSync(crontabBin, ["-"], {
    cwd: deployDir,
    input: content,
    encoding: "utf8",
    env: process.env,
  });
  if (result.status !== 0) {
    blocked("blocked_crontab_write_failed", `无法写入 crontab：${compactLines(result.stderr || result.stdout).join("；")}`);
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
    `HEARTBEAT_BURN_ALERT_INSTANCE_IDS=${shellQuote(instanceIds)}`,
    "repo/ops/tom-readonly/heartbeat-burn-alert-runner.sh run",
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
    status: isInstalled ? (existing === next ? "heartbeat_burn_alert_cron_installed" : "heartbeat_burn_alert_cron_needs_update") : "heartbeat_burn_alert_cron_not_installed",
    mode,
    generatedAt: new Date().toISOString(),
    installed: isInstalled,
    needsUpdate: existing !== next,
    schedule,
    logPath,
    instanceIds,
    safety: safety(),
  });
}

function reportPlan() {
  const existing = readCrontab();
  const next = buildNext(existing);
  emit({
    schemaVersion: 1,
    status: "heartbeat_burn_alert_cron_plan_ready",
    mode,
    generatedAt: new Date().toISOString(),
    installed: installed(existing),
    needsUpdate: existing !== next,
    schedule,
    logPath,
    instanceIds,
    block: renderBlock(),
    nextCommands: existing !== next
      ? [`CONFIRM_HEARTBEAT_BURN_ALERT_CRON=${confirmation} repo/ops/tom-readonly/install-heartbeat-burn-alert-cron.sh apply`]
      : [],
    safety: safety(),
  });
}

function applyCron() {
  if (confirm !== confirmation) {
    blocked("blocked_confirmation_required", `apply 必须设置 CONFIRM_HEARTBEAT_BURN_ALERT_CRON=${confirmation}。`);
  }
  const runner = path.join(deployDir, "repo", "ops", "tom-readonly", "heartbeat-burn-alert-runner.sh");
  if (!fs.existsSync(runner)) {
    blocked("blocked_runner_missing", `heartbeat-burn-alert-runner.sh 不存在：${runner}`);
  }
  fs.mkdirSync(path.dirname(logPath), { recursive: true });
  const existing = readCrontab();
  const next = buildNext(existing);
  writeCrontab(next);
  emit({
    schemaVersion: 1,
    status: "heartbeat_burn_alert_cron_installed",
    mode,
    generatedAt: new Date().toISOString(),
    schedule,
    logPath,
    instanceIds,
    safety: safety({
      writesCrontabOnly: true,
      installsReadonlyHeartbeatBurnAlertCron: true,
      writesControlCenterRuntimeOnly: true,
    }),
  });
}

function removeCron() {
  if (confirm !== confirmation) {
    blocked("blocked_confirmation_required", `remove 必须设置 CONFIRM_HEARTBEAT_BURN_ALERT_CRON=${confirmation}。`);
  }
  const existing = readCrontab();
  const cleaned = `${removeBlock(existing)}\n`.replace(/^\n$/, "");
  writeCrontab(cleaned);
  emit({
    schemaVersion: 1,
    status: "heartbeat_burn_alert_cron_removed",
    mode,
    generatedAt: new Date().toISOString(),
    safety: safety({
      writesCrontabOnly: true,
      removesReadonlyHeartbeatBurnAlertCron: true,
    }),
  });
}

requireMode();
if (mode === "status") reportStatus();
if (mode === "plan") reportPlan();
if (mode === "apply") applyCron();
if (mode === "remove") removeCron();
NODE
