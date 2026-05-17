#!/usr/bin/env bash
set -euo pipefail
set +x

# live healthcheck 演练报告工具。
# 只读取 approval、impact snapshots 和 operation-audit.log，不调用 live API。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
APPROVAL_FILE="${APPROVAL_FILE:-${DEPLOY_DIR}/runtime/live-healthcheck-approval.json}"
AUDIT_LOG="${AUDIT_LOG:-${DEPLOY_DIR}/runtime/operation-audit.log}"
REPORT_DIR="${REPORT_DIR:-${DEPLOY_DIR}/runtime/live-healthcheck-reports}"

timestamp() {
  date +"%Y-%m-%dT%H:%M:%S%z"
}

safe_timestamp() {
  date +"%Y%m%dT%H%M%S%z"
}

log() {
  printf '[%s] %s\n' "$(timestamp)" "$*" >&2
}

fail() {
  printf '[失败] %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"
}

write_report() {
  local before_path="${1:-}"
  local after_path="${2:-}"
  local approval_path="${3:-$APPROVAL_FILE}"

  [ -f "$before_path" ] || fail "before 快照不存在：${before_path}"
  [ -f "$after_path" ] || fail "after 快照不存在：${after_path}"
  [ -f "$approval_path" ] || fail "批准文件不存在：${approval_path}"
  [ -f "$AUDIT_LOG" ] || fail "审计日志不存在：${AUDIT_LOG}"

  mkdir -p "$REPORT_DIR"
  local json_report="${REPORT_DIR}/live-healthcheck-report-$(safe_timestamp).json"
  local md_report="${json_report%.json}.md"

  BEFORE_PATH="$before_path" \
    AFTER_PATH="$after_path" \
    APPROVAL_FILE="$approval_path" \
    AUDIT_LOG="$AUDIT_LOG" \
    JSON_REPORT="$json_report" \
    MD_REPORT="$md_report" \
    node <<'NODE'
const fs = require("node:fs");

const beforePath = process.env.BEFORE_PATH;
const afterPath = process.env.AFTER_PATH;
const approvalPath = process.env.APPROVAL_FILE;
const auditLog = process.env.AUDIT_LOG;
const jsonReport = process.env.JSON_REPORT;
const mdReport = process.env.MD_REPORT;

function readJson(path) {
  return JSON.parse(fs.readFileSync(path, "utf8"));
}

function readAuditEntries(path) {
  return fs.readFileSync(path, "utf8")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return undefined;
      }
    })
    .filter(Boolean);
}

function asRecord(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

function gatewayKey(item) {
  return String(item.port);
}

function summarizeImpact(before, after) {
  const checks = [];
  const beforeGateways = new Map((before.gateways || []).map((item) => [gatewayKey(item), item]));
  const afterGateways = new Map((after.gateways || []).map((item) => [gatewayKey(item), item]));
  for (const [port, item] of beforeGateways) {
    const next = afterGateways.get(port);
    checks.push({
      id: `gateway-${port}`,
      ok: Boolean(next && item.healthOk === true && next.healthOk === true && item.listenerOk === true && next.listenerOk === true && String(item.listener || "") === String(next.listener || "")),
      detail: `gateway ${port} health/listener stable`,
    });
  }

  checks.push({
    id: "container-privileged",
    ok: after.controlCenter?.privileged === false,
    detail: "control-center privileged=false",
  });
  checks.push({
    id: "container-docker-sock",
    ok: after.controlCenter?.dockerSockMounted !== true,
    detail: "control-center does not mount docker.sock",
  });
  for (const mount of after.controlCenter?.instanceMounts || []) {
    checks.push({
      id: `mount-${mount.destination}`,
      ok: mount.present === true && mount.rw === false,
      detail: `${mount.destination} mounted readonly`,
    });
  }
  checks.push({
    id: "readonly-restored",
    ok: after.controlCenter?.env?.READONLY_MODE === "true",
    detail: "READONLY_MODE restored to true",
  });
  checks.push({
    id: "live-gate-disabled",
    ok: after.controlCenter?.env?.MANAGED_ACTIONS_LIVE_ENABLED !== "true",
    detail: "MANAGED_ACTIONS_LIVE_ENABLED is not true after run",
  });
  checks.push({
    id: "live-executor-disabled",
    ok: after.controlCenter?.env?.MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED !== "true",
    detail: "MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED is not true after run",
  });
  checks.push({
    id: "readiness-blocked",
    ok: after.readiness?.liveExecutionAvailable === false && after.readiness?.executorProductionWired === false,
    detail: "readiness no longer allows live execution",
  });

  return {
    ok: checks.every((item) => item.ok),
    checks,
  };
}

function findLiveResult(entries, approval, before, after) {
  const beforeMs = Date.parse(before.generatedAt || "");
  const afterMs = Date.parse(after.generatedAt || "");
  return entries
    .filter((entry) => entry.action === "managed_action_live_result")
    .filter((entry) => {
      const metadata = asRecord(entry.metadata);
      const target = asRecord(metadata.target);
      const ts = Date.parse(entry.timestamp || "");
      return metadata.managedAction === approval.action &&
        metadata.operator === approval.operator &&
        target.instanceId === approval.instanceId &&
        Number.isFinite(ts) &&
        (!Number.isFinite(beforeMs) || ts >= beforeMs - 60_000) &&
        (!Number.isFinite(afterMs) || ts <= afterMs + 60_000);
    })
    .sort((a, b) => Date.parse(b.timestamp || "") - Date.parse(a.timestamp || ""))[0];
}

function findDryRun(entries, liveResult) {
  const operationRequestId = liveResult?.metadata?.operationRequestId;
  if (!operationRequestId) return undefined;
  return entries
    .filter((entry) => entry.action === "managed_action_dry_run")
    .filter((entry) => entry.metadata?.operationRequestId === operationRequestId)
    .sort((a, b) => Date.parse(b.timestamp || "") - Date.parse(a.timestamp || ""))[0];
}

function writeMarkdown(report) {
  const lines = [];
  lines.push("# Live Healthcheck 演练报告");
  lines.push("");
  lines.push(`- 状态：${report.status}`);
  lines.push(`- 生成时间：${report.generatedAt}`);
  lines.push(`- 实例：${report.approval.instanceId}`);
  lines.push(`- 动作：${report.approval.action}`);
  lines.push(`- 操作者：${report.approval.operator}`);
  lines.push(`- 批准人：${report.approval.approvedBy}`);
  lines.push(`- 批准时间：${report.approval.approvedAt}`);
  lines.push(`- 批准记录已使用：${String(report.approval.consumed)}`);
  lines.push(`- 使用时间：${report.approval.consumedAt || ""}`);
  lines.push(`- operationRequestId：${report.audit.operationRequestId || ""}`);
  lines.push(`- live outcome：${report.audit.liveOutcome || ""}`);
  lines.push(`- mutatesOpenClawInstance：${String(report.audit.mutatesOpenClawInstance)}`);
  lines.push("");
  lines.push("## 证据文件");
  lines.push("");
  lines.push(`- before：${report.artifacts.beforeImpactSnapshot}`);
  lines.push(`- after：${report.artifacts.afterImpactSnapshot}`);
  lines.push(`- approval：${report.artifacts.approvalFile}`);
  lines.push(`- audit：${report.artifacts.auditLog}`);
  lines.push("");
  lines.push("## 影响检查");
  lines.push("");
  for (const check of report.impact.checks) {
    lines.push(`- ${check.ok ? "PASS" : "FAIL"} ${check.id}：${check.detail}`);
  }
  lines.push("");
  lines.push("## 结论");
  lines.push("");
  lines.push(report.status === "passed"
    ? "只读 healthcheck live 演练完成，控制中心已恢复只读状态，未发现 OpenClaw 实例影响。"
    : "演练报告未通过，请先处理失败项，不要扩大灰度范围。");
  return `${lines.join("\n")}\n`;
}

const approval = readJson(approvalPath);
const before = readJson(beforePath);
const after = readJson(afterPath);
const entries = readAuditEntries(auditLog);
const impact = summarizeImpact(before, after);
const liveResult = findLiveResult(entries, approval, before, after);
const dryRun = findDryRun(entries, liveResult);
const liveMetadata = asRecord(liveResult?.metadata);
const resultMetadata = asRecord(liveMetadata.result);
const statusChecks = [
  approval.approved === true,
  approval.consumed === true,
  liveResult?.ok === true,
  liveMetadata.outcome === "executed",
  liveMetadata.liveExecution === true,
  liveMetadata.mutatesOpenClawInstance === false,
  Boolean(dryRun),
  impact.ok,
];
const status = statusChecks.every(Boolean) ? "passed" : "failed";

const report = {
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  status,
  approval: {
    approvedBy: approval.approvedBy,
    approvedAt: approval.approvedAt,
    approvalId: approval.approvalId,
    consumed: approval.consumed === true,
    consumedAt: approval.consumedAt,
    consumedBy: approval.consumedBy,
    instanceId: approval.instanceId,
    action: approval.action,
    operator: approval.operator,
    risk: approval.risk,
    mutatesOpenClawInstance: approval.scope?.mutatesOpenClawInstance === true,
  },
  audit: {
    operationRequestId: liveMetadata.operationRequestId,
    dryRunFound: Boolean(dryRun),
    liveResultFound: Boolean(liveResult),
    liveOutcome: liveMetadata.outcome,
    liveExecution: liveMetadata.liveExecution === true,
    mutatesOpenClawInstance: liveMetadata.mutatesOpenClawInstance === true,
    liveDetail: liveResult?.detail,
    resultMessage: resultMetadata.message,
  },
  impact,
  artifacts: {
    beforeImpactSnapshot: beforePath,
    afterImpactSnapshot: afterPath,
    approvalFile: approvalPath,
    auditLog,
    markdownReport: mdReport,
  },
};

fs.writeFileSync(jsonReport, `${JSON.stringify(report, null, 2)}\n`, "utf8");
fs.writeFileSync(mdReport, writeMarkdown(report), "utf8");
process.stdout.write(`${jsonReport}\n`);
if (status !== "passed") process.exit(2);
NODE
}

usage() {
  cat <<'TEXT'
用法：
  live-healthcheck-report.sh report <before.json> <after.json> [approval.json]

说明：
  只读取 approval、impact snapshots 和 operation-audit.log。
  报告通过条件包括 approval 已批准且已使用、live audit executed、dry-run 引用存在、mutatesOpenClawInstance=false，以及 after 快照恢复只读。
TEXT
}

main() {
  require_command node
  case "${1:-report}" in
    report)
      write_report "${2:-}" "${3:-}" "${4:-$APPROVAL_FILE}"
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
