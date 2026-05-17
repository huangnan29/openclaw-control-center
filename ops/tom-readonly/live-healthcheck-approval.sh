#!/usr/bin/env bash
set -euo pipefail
set +x

# live healthcheck 人工批准记录工具。
# 只生成或校验批准文件，不调用 live API，不修改 OpenClaw 实例目录。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
APPROVAL_FILE="${APPROVAL_FILE:-${DEPLOY_DIR}/runtime/live-healthcheck-approval.json}"
INSTANCE_ID="${INSTANCE_ID:-tom}"
OPERATOR="${OPERATOR:-Anan}"
APPROVAL_MAX_AGE_HOURS="${APPROVAL_MAX_AGE_HOURS:-24}"

timestamp() {
  date +"%Y-%m-%dT%H:%M:%S%z"
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

write_template() {
  local output="${1:-$APPROVAL_FILE}"
  mkdir -p "$(dirname "$output")"
  INSTANCE_ID="$INSTANCE_ID" \
    OPERATOR="$OPERATOR" \
    node - "$output" <<'NODE'
const fs = require("node:fs");

const outputPath = process.argv[2];
const approval = {
  schemaVersion: 1,
  approved: false,
  approvedAt: "",
  approvedBy: "",
  instanceId: process.env.INSTANCE_ID || "tom",
  action: "healthcheck",
  operator: process.env.OPERATOR || "Anan",
  risk: "low",
  confirmationText: "I_UNDERSTAND_THIS_TEMPORARILY_ENABLES_LIVE_GATE",
  liveConfirmationText: "I_UNDERSTAND_THIS_CALLS_LIVE_API",
  scope: {
    service: "openclaw-control-center",
    mutatesOpenClawInstance: false,
    allowedAction: "healthcheck"
  },
  checklist: {
    understandsTemporaryLiveGate: false,
    understandsLocalTokenRequired: false,
    understandsAutoRollback: false,
    understandsImpactSnapshot: false
  },
  notes: "人工确认后，将 approved 改为 true，填写 approvedAt 与 approvedBy，并将 checklist 全部改为 true。"
};

fs.writeFileSync(outputPath, `${JSON.stringify(approval, null, 2)}\n`, "utf8");
process.stdout.write(`${outputPath}\n`);
NODE
  log "已生成批准模板：${output}"
}

check_approval() {
  local input="${1:-$APPROVAL_FILE}"
  [ -f "$input" ] || fail "批准文件不存在：${input}。请先运行：$0 template ${input}"

  APPROVAL_FILE="$input" \
    INSTANCE_ID="$INSTANCE_ID" \
    OPERATOR="$OPERATOR" \
    APPROVAL_MAX_AGE_HOURS="$APPROVAL_MAX_AGE_HOURS" \
    node <<'NODE'
const fs = require("node:fs");

const file = process.env.APPROVAL_FILE;
const expectedInstanceId = process.env.INSTANCE_ID || "tom";
const expectedOperator = process.env.OPERATOR || "Anan";
const maxAgeHours = Number(process.env.APPROVAL_MAX_AGE_HOURS || "24");
const failures = [];

function fail(message) {
  failures.push(message);
}

function readJson(path) {
  try {
    return JSON.parse(fs.readFileSync(path, "utf8"));
  } catch (error) {
    fail(`批准文件无法解析：${error instanceof Error ? error.message : String(error)}`);
    return {};
  }
}

const approval = readJson(file);
if (approval.schemaVersion !== 1) fail("schemaVersion 必须为 1");
if (approval.approved !== true) fail("approved 必须为 true");
if (typeof approval.approvedBy !== "string" || approval.approvedBy.trim() === "") fail("approvedBy 必须填写");

const approvedAt = Date.parse(String(approval.approvedAt || ""));
if (!Number.isFinite(approvedAt)) {
  fail("approvedAt 必须是可解析时间");
} else if (Number.isFinite(maxAgeHours) && maxAgeHours > 0) {
  const ageMs = Date.now() - approvedAt;
  if (ageMs < -5 * 60 * 1000) fail("approvedAt 不能明显晚于当前时间");
  if (ageMs > maxAgeHours * 60 * 60 * 1000) fail(`批准已过期：maxAgeHours=${maxAgeHours}`);
}

if (approval.instanceId !== expectedInstanceId) fail(`instanceId 必须为 ${expectedInstanceId}`);
if (approval.action !== "healthcheck") fail("action 必须为 healthcheck");
if (approval.operator !== expectedOperator) fail(`operator 必须为 ${expectedOperator}`);
if (approval.risk !== "low") fail("risk 必须为 low");
if (approval.confirmationText !== "I_UNDERSTAND_THIS_TEMPORARILY_ENABLES_LIVE_GATE") {
  fail("confirmationText 不匹配");
}
if (approval.liveConfirmationText !== "I_UNDERSTAND_THIS_CALLS_LIVE_API") {
  fail("liveConfirmationText 不匹配");
}
if (approval.scope?.mutatesOpenClawInstance !== false) fail("scope.mutatesOpenClawInstance 必须为 false");
if (approval.scope?.allowedAction !== "healthcheck") fail("scope.allowedAction 必须为 healthcheck");

const checklist = approval.checklist || {};
for (const key of [
  "understandsTemporaryLiveGate",
  "understandsLocalTokenRequired",
  "understandsAutoRollback",
  "understandsImpactSnapshot",
]) {
  if (checklist[key] !== true) fail(`checklist.${key} 必须为 true`);
}

if (failures.length > 0) {
  for (const message of failures) console.error(`[失败] ${message}`);
  process.exit(2);
}

console.log(JSON.stringify({
  status: "approved",
  file,
  approvedBy: approval.approvedBy,
  approvedAt: approval.approvedAt,
  instanceId: approval.instanceId,
  action: approval.action,
  operator: approval.operator,
  risk: approval.risk,
  mutatesOpenClawInstance: approval.scope?.mutatesOpenClawInstance === true
}, null, 2));
NODE
}

usage() {
  cat <<'TEXT'
用法：
  live-healthcheck-approval.sh template [approval.json]
  live-healthcheck-approval.sh check [approval.json]

说明：
  template 只生成批准文件模板，不会启用 live gate。
  check 只校验批准文件，不会调用 live API。
TEXT
}

main() {
  require_command node
  case "${1:-check}" in
    template)
      write_template "${2:-$APPROVAL_FILE}"
      ;;
    check)
      check_approval "${2:-$APPROVAL_FILE}"
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
