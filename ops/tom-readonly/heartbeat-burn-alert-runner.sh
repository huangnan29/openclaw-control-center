#!/usr/bin/env bash
set -euo pipefail
set +x

# heartbeat/token 异常用量告警 runner。
# 本脚本只调用只读检查器，并把告警报告写入 control-center runtime。
# 不修改任何 OpenClaw 实例目录，不清空 HEARTBEAT.md，不调用模型，不重启实例。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
if [ "$(basename "$DEFAULT_DEPLOY_DIR")" = "repo" ] && [ -d "${DEFAULT_DEPLOY_DIR}/../runtime" ]; then
  DEFAULT_DEPLOY_DIR="$(cd "${DEFAULT_DEPLOY_DIR}/.." && pwd)"
fi

export DEPLOY_DIR="${DEPLOY_DIR:-$DEFAULT_DEPLOY_DIR}"
export MODE_NAME="${1:-status}"
export HEARTBEAT_BURN_INSPECTOR="${HEARTBEAT_BURN_INSPECTOR:-${DEPLOY_DIR}/repo/ops/tom-readonly/heartbeat-burn-inspector.sh}"
export HEARTBEAT_BURN_ALERT_DIR="${HEARTBEAT_BURN_ALERT_DIR:-${DEPLOY_DIR}/runtime/heartbeat-burn-alerts}"
export HEARTBEAT_BURN_ALERT_INSTANCE_IDS="${HEARTBEAT_BURN_ALERT_INSTANCE_IDS:-}"

usage() {
  cat <<'TEXT'
用法：
  heartbeat-burn-alert-runner.sh status
  heartbeat-burn-alert-runner.sh run

常用环境变量：
  HEARTBEAT_BURN_ALERT_INSTANCE_IDS="deepseek spark"  # 留空表示检查全部实例
  HEARTBEAT_BURN_ALERT_DIR=/srv/openclaw-control-center-readonly/runtime/heartbeat-burn-alerts
  HEARTBEAT_BURN_INSPECTOR=/srv/openclaw-control-center-readonly/repo/ops/tom-readonly/heartbeat-burn-inspector.sh

安全边界：
  - run 只写 control-center runtime 下的 latest.json 与 events.ndjson。
  - 不写 OpenClaw 实例目录。
  - 不清空 HEARTBEAT.md。
  - 不调用模型。
  - 不重启实例。
  - 不调用 managed action live API。
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
const inspector = process.env.HEARTBEAT_BURN_INSPECTOR || path.join(deployDir, "repo", "ops", "tom-readonly", "heartbeat-burn-inspector.sh");
const alertDir = process.env.HEARTBEAT_BURN_ALERT_DIR || path.join(deployDir, "runtime", "heartbeat-burn-alerts");
const instanceIds = String(process.env.HEARTBEAT_BURN_ALERT_INSTANCE_IDS || "")
  .split(/[,\s]+/)
  .map((item) => item.trim())
  .filter(Boolean);
const latestPath = path.join(alertDir, "latest.json");
const eventsPath = path.join(alertDir, "events.ndjson");

function safety(extra = {}) {
  return {
    readsCollectorHistoryOnly: true,
    readsHeartbeatMetadataOnly: true,
    writesControlCenterRuntimeOnly: false,
    writesOpenClawInstanceDirs: false,
    clearsHeartbeatFiles: false,
    callsModelApis: false,
    restartsOpenClawInstances: false,
    callsManagedActionsLiveApi: false,
    opensLiveGate: false,
    ...extra,
  };
}

function emit(report, code = 0) {
  console.log(JSON.stringify(report, null, 2));
  process.exit(code);
}

function compactLines(text, limit = 8) {
  return String(text || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, limit);
}

function invalidMode() {
  emit({
    schemaVersion: 1,
    status: "blocked_invalid_mode",
    mode,
    generatedAt: new Date().toISOString(),
    issues: [`未知模式：${mode}。支持 status、run。`],
    safety: safety({ blockedBeforeWrite: true }),
  }, 2);
}

function readLatest() {
  try {
    return JSON.parse(fs.readFileSync(latestPath, "utf8"));
  } catch {
    return undefined;
  }
}

function status() {
  const latest = readLatest();
  emit({
    schemaVersion: 1,
    status: latest ? "heartbeat_burn_alert_status_ready" : "heartbeat_burn_alert_not_run",
    mode,
    generatedAt: new Date().toISOString(),
    alertDir,
    latestPath,
    eventsPath,
    instanceIds,
    latest: latest
      ? {
          status: latest.status,
          generatedAt: latest.generatedAt,
          suspiciousRows: latest.summary?.suspiciousRows ?? 0,
          suspiciousInstances: Array.isArray(latest.suspiciousRows)
            ? latest.suspiciousRows.map(summarizeRow)
            : [],
        }
      : undefined,
    nextCommands: [
      "repo/ops/tom-readonly/heartbeat-burn-alert-runner.sh run",
      "repo/ops/tom-readonly/install-heartbeat-burn-alert-cron.sh status",
    ],
    safety: safety(),
  });
}

function runInspector(instanceId) {
  const args = ["status"];
  if (instanceId) args.push(instanceId);
  const result = spawnSync(inspector, args, {
    cwd: deployDir,
    env: process.env,
    encoding: "utf8",
    timeout: 60_000,
    maxBuffer: 4 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    return {
      ok: false,
      status: "blocked_inspector_failed",
      instanceId,
      exitCode: typeof result.status === "number" ? result.status : 1,
      detail: result.error ? String(result.error.message || result.error) : compactLines(result.stderr || result.stdout).join("；"),
      rows: [],
      issues: compactLines(result.stderr || result.stdout),
    };
  }
  try {
    const report = JSON.parse(result.stdout);
    return {
      ok: true,
      status: report.status,
      instanceId,
      report,
      rows: Array.isArray(report.rows) ? report.rows : [],
      issues: Array.isArray(report.issues) ? report.issues : [],
    };
  } catch (error) {
    return {
      ok: false,
      status: "blocked_inspector_invalid_json",
      instanceId,
      exitCode: 1,
      detail: error instanceof Error ? error.message : String(error),
      rows: [],
      issues: compactLines(result.stdout),
    };
  }
}

function summarizeRow(row) {
  return {
    instanceId: row.instanceId,
    instanceName: row.instanceName,
    signal: row.signal || row.status,
    totalDelta: row.totalDelta,
    recentDelta: row.recentDelta,
    medianDelta: row.medianDelta,
    medianIntervalMinutes: row.medianIntervalMinutes,
    heartbeat: row.heartbeat
      ? {
          status: row.heartbeat.status,
          path: row.heartbeat.path,
          sizeBytes: row.heartbeat.sizeBytes,
          nonEmpty: row.heartbeat.nonEmpty,
          updatedAt: row.heartbeat.updatedAt,
        }
      : undefined,
    nextCommands: row.nextCommands || [],
  };
}

function run() {
  if (!fs.existsSync(inspector)) {
    emit({
      schemaVersion: 1,
      status: "blocked_inspector_missing",
      mode,
      generatedAt: new Date().toISOString(),
      issues: [`heartbeat-burn-inspector.sh 不存在：${inspector}`],
      safety: safety({ blockedBeforeWrite: true }),
    }, 2);
  }

  const targets = instanceIds.length > 0 ? instanceIds : [""];
  const runs = targets.map((target) => runInspector(target));
  const failures = runs.filter((item) => !item.ok);
  const rows = runs.flatMap((item) => item.rows);
  const suspiciousRows = rows.filter((row) => row.suspicious);
  const generatedAt = new Date().toISOString();
  const report = {
    schemaVersion: 1,
    status: failures.length > 0
      ? "blocked_inspector_failed"
      : suspiciousRows.length > 0
        ? "heartbeat_burn_alert_triggered"
        : "heartbeat_burn_alert_clear",
    mode,
    generatedAt,
    alertDir,
    latestPath,
    eventsPath,
    instanceIds,
    summary: {
      checkedInstances: rows.length,
      suspiciousRows: suspiciousRows.length,
      failures: failures.length,
    },
    suspiciousRows: suspiciousRows.map(summarizeRow),
    issues: failures.flatMap((item) => item.issues?.length ? item.issues : [item.detail || item.status]),
    safety: safety({ writesControlCenterRuntimeOnly: true }),
  };

  fs.mkdirSync(alertDir, { recursive: true });
  fs.writeFileSync(latestPath, JSON.stringify(report, null, 2), "utf8");
  if (suspiciousRows.length > 0) {
    fs.appendFileSync(eventsPath, `${JSON.stringify({
      generatedAt,
      status: report.status,
      suspiciousRows: report.suspiciousRows,
    })}\n`, "utf8");
  }

  emit(report, failures.length > 0 ? 2 : suspiciousRows.length > 0 ? 2 : 0);
}

if (mode === "status") status();
else if (mode === "run") run();
else invalidMode();
NODE
