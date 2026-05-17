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
CONFIRM_APPROVAL_RECORD="${CONFIRM_APPROVAL_RECORD:-}"
APPROVED_BY="${APPROVED_BY:-}"
APPROVAL_PACKET_SCRIPT="${APPROVAL_PACKET_SCRIPT:-${DEPLOY_DIR}/repo/ops/tom-readonly/live-healthcheck-approval-packet.sh}"
APPROVAL_PACKET_FILE="${APPROVAL_PACKET_FILE:-}"

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
  approvalId: "",
  approved: false,
  approvedAt: "",
  approvedBy: "",
  consumed: false,
  consumedAt: "",
  consumedBy: "",
  consumedReason: "",
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
  approvalPacket: {
    status: "",
    packetFile: "",
    generatedAt: "",
    checkedAt: "",
    topologyMode: "",
    target: {
      instanceId: "",
      action: "",
      operator: ""
    },
    commit: {
      packet: "",
      current: ""
    },
    maxAgeSeconds: null
  },
  notes: "人工确认后，将 approved 改为 true，填写 approvedAt 与 approvedBy，并将 checklist 全部改为 true。"
};

fs.writeFileSync(outputPath, `${JSON.stringify(approval, null, 2)}\n`, "utf8");
process.stdout.write(`${outputPath}\n`);
NODE
  log "已生成批准模板：${output}"
}

prepare_template() {
  local output="${1:-$APPROVAL_FILE}"
  if [ -f "$output" ]; then
    log "批准文件已存在，不覆盖：${output}"
  else
    write_template "$output" >/dev/null
  fi
  show_status "$output"
}

run_approval_packet_check() {
  [ -x "$APPROVAL_PACKET_SCRIPT" ] || fail "批准前证据包校验脚本不可执行：${APPROVAL_PACKET_SCRIPT}"

  local packet_output
  log "校验 live healthcheck 批准前证据包"
  if [ -n "$APPROVAL_PACKET_FILE" ]; then
    if ! packet_output="$(INSTANCE_ID="$INSTANCE_ID" ACTION="healthcheck" OPERATOR="$OPERATOR" "$APPROVAL_PACKET_SCRIPT" check "$APPROVAL_PACKET_FILE" 2>&1)"; then
      printf '%s\n' "$packet_output" >&2
      fail "批准前证据包校验未通过"
    fi
  else
    if ! packet_output="$(INSTANCE_ID="$INSTANCE_ID" ACTION="healthcheck" OPERATOR="$OPERATOR" "$APPROVAL_PACKET_SCRIPT" check 2>&1)"; then
      printf '%s\n' "$packet_output" >&2
      fail "批准前证据包校验未通过"
    fi
  fi
  printf '%s\n' "$packet_output" >&2
  printf '%s\n' "$packet_output"
}

check_approval_packet() {
  run_approval_packet_check >/dev/null
}

read_packet_status_for_report() {
  if [ ! -x "$APPROVAL_PACKET_SCRIPT" ]; then
    printf '{"schemaVersion":1,"status":"missing_packet_script","issues":["approval packet script is not executable"]}\n'
    return 0
  fi

  local packet_output
  if [ -n "$APPROVAL_PACKET_FILE" ]; then
    packet_output="$(INSTANCE_ID="$INSTANCE_ID" ACTION="healthcheck" OPERATOR="$OPERATOR" "$APPROVAL_PACKET_SCRIPT" check "$APPROVAL_PACKET_FILE" 2>&1)" || true
  else
    packet_output="$(INSTANCE_ID="$INSTANCE_ID" ACTION="healthcheck" OPERATOR="$OPERATOR" "$APPROVAL_PACKET_SCRIPT" check 2>&1)" || true
  fi
  printf '%s\n' "$packet_output"
}

approve_record() {
  local output="${1:-$APPROVAL_FILE}"
  [ "$CONFIRM_APPROVAL_RECORD" = "I_APPROVE_LIVE_HEALTHCHECK_RECORD" ] || \
    fail "必须设置 CONFIRM_APPROVAL_RECORD=I_APPROVE_LIVE_HEALTHCHECK_RECORD"
  [ -n "$APPROVED_BY" ] || fail "必须设置 APPROVED_BY=<批准人>"
  # check_approval_packet 的实际校验由 run_approval_packet_check 执行，并返回绑定 JSON。
  local packet_report
  packet_report="$(run_approval_packet_check)"

  mkdir -p "$(dirname "$output")"
  APPROVAL_FILE="$output" \
    INSTANCE_ID="$INSTANCE_ID" \
    OPERATOR="$OPERATOR" \
    APPROVED_BY="$APPROVED_BY" \
    APPROVAL_PACKET_CHECK_JSON="$packet_report" \
    node <<'NODE'
const fs = require("node:fs");
const crypto = require("node:crypto");

const file = process.env.APPROVAL_FILE;
const expectedInstanceId = process.env.INSTANCE_ID || "tom";
const expectedOperator = process.env.OPERATOR || "Anan";
const approvedBy = String(process.env.APPROVED_BY || "").trim();
const packetReport = parsePacketReport(process.env.APPROVAL_PACKET_CHECK_JSON || "");

function parsePacketReport(raw) {
  try {
    const parsed = JSON.parse(raw);
    if (parsed.status !== "ready") {
      console.error(`[失败] 批准前证据包状态不是 ready：${parsed.status || "unknown"}`);
      process.exit(2);
    }
    return parsed;
  } catch (error) {
    console.error(`[失败] 批准前证据包校验输出无法解析：${error instanceof Error ? error.message : String(error)}`);
    process.exit(2);
  }
}

let approval = {};
if (fs.existsSync(file)) {
  try {
    approval = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    approval = {};
  }
}

const next = {
  ...approval,
  schemaVersion: 1,
  approvalId: crypto.randomUUID(),
  approved: true,
  approvedAt: new Date().toISOString(),
  approvedBy,
  consumed: false,
  consumedAt: "",
  consumedBy: "",
  consumedReason: "",
  instanceId: expectedInstanceId,
  action: "healthcheck",
  operator: expectedOperator,
  risk: "low",
  confirmationText: "I_UNDERSTAND_THIS_TEMPORARILY_ENABLES_LIVE_GATE",
  liveConfirmationText: "I_UNDERSTAND_THIS_CALLS_LIVE_API",
  scope: {
    ...(approval.scope && typeof approval.scope === "object" && !Array.isArray(approval.scope) ? approval.scope : {}),
    service: "openclaw-control-center",
    mutatesOpenClawInstance: false,
    allowedAction: "healthcheck",
  },
  checklist: {
    understandsTemporaryLiveGate: true,
    understandsLocalTokenRequired: true,
    understandsAutoRollback: true,
    understandsImpactSnapshot: true,
  },
  approvalPacket: {
    status: packetReport.status || "",
    packetFile: packetReport.packetFile || "",
    generatedAt: packetReport.generatedAt || "",
    checkedAt: packetReport.checkedAt || "",
    topologyMode: packetReport.topologyMode || "",
    target: {
      instanceId: packetReport.target?.instanceId || "",
      action: packetReport.target?.action || "",
      operator: packetReport.target?.operator || "",
    },
    commit: {
      packet: packetReport.commit?.packet || "",
      current: packetReport.commit?.current || "",
    },
    maxAgeSeconds: Number.isFinite(Number(packetReport.maxAgeSeconds)) ? Number(packetReport.maxAgeSeconds) : null,
  },
  notes: "已通过 live-healthcheck-approval.sh approve 记录人工批准；该动作只写批准文件，不会启用 live gate。",
};

fs.writeFileSync(file, `${JSON.stringify(next, null, 2)}\n`, "utf8");
NODE
  log "已写入人工批准记录：${output}"
  check_approval "$output"
}

consume_record() {
  local input="${1:-$APPROVAL_FILE}"
  [ -f "$input" ] || fail "批准文件不存在：${input}"

  APPROVAL_FILE="$input" \
    INSTANCE_ID="$INSTANCE_ID" \
    OPERATOR="$OPERATOR" \
    node <<'NODE'
const fs = require("node:fs");
const crypto = require("node:crypto");

const file = process.env.APPROVAL_FILE;
const expectedInstanceId = process.env.INSTANCE_ID || "tom";
const expectedOperator = process.env.OPERATOR || "Anan";

let approval;
try {
  approval = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (error) {
  console.error(`[失败] 批准文件无法解析：${error instanceof Error ? error.message : String(error)}`);
  process.exit(2);
}

if (approval.approved !== true) {
  console.error("[失败] 批准文件尚未 approved=true，不能标记为已使用");
  process.exit(2);
}
if (approval.instanceId !== expectedInstanceId) {
  console.error(`[失败] instanceId 必须为 ${expectedInstanceId}`);
  process.exit(2);
}
if (approval.action !== "healthcheck") {
  console.error("[失败] action 必须为 healthcheck");
  process.exit(2);
}
if (approval.operator !== expectedOperator) {
  console.error(`[失败] operator 必须为 ${expectedOperator}`);
  process.exit(2);
}

const next = {
  ...approval,
  approvalId: approval.approvalId || crypto.randomUUID(),
  consumed: true,
  consumedAt: approval.consumed === true && approval.consumedAt ? approval.consumedAt : new Date().toISOString(),
  consumedBy: approval.consumed === true && approval.consumedBy ? approval.consumedBy : expectedOperator,
  consumedReason: approval.consumed === true && approval.consumedReason
    ? approval.consumedReason
    : "live-healthcheck-window.sh run 已完成 live healthcheck 调用，批准记录自动标记为已使用。",
};

fs.writeFileSync(file, `${JSON.stringify(next, null, 2)}\n`, "utf8");
console.log(JSON.stringify({
  status: "consumed",
  file,
  approvalId: next.approvalId,
  approvedBy: next.approvedBy,
  approvedAt: next.approvedAt,
  consumed: next.consumed,
  consumedAt: next.consumedAt,
  consumedBy: next.consumedBy,
  instanceId: next.instanceId,
  action: next.action,
  operator: next.operator,
}, null, 2));
NODE
}

check_approval() {
  local input="${1:-$APPROVAL_FILE}"
  [ -f "$input" ] || fail "批准文件不存在：${input}。请先运行：$0 template ${input}"

  local packet_status
  packet_status="$(read_packet_status_for_report)"
  APPROVAL_FILE="$input" \
    INSTANCE_ID="$INSTANCE_ID" \
    OPERATOR="$OPERATOR" \
    APPROVAL_MAX_AGE_HOURS="$APPROVAL_MAX_AGE_HOURS" \
    DEPLOY_DIR="$DEPLOY_DIR" \
    APPROVAL_PACKET_STATUS_JSON="$packet_status" \
    node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const file = process.env.APPROVAL_FILE;
const expectedInstanceId = process.env.INSTANCE_ID || "tom";
const expectedOperator = process.env.OPERATOR || "Anan";
const maxAgeHours = Number(process.env.APPROVAL_MAX_AGE_HOURS || "24");
const deployDir = process.env.DEPLOY_DIR || "/srv/openclaw-control-center-readonly";
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

function parseJsonText(raw, label) {
  try {
    return JSON.parse(raw);
  } catch (error) {
    fail(`${label} 无法解析：${error instanceof Error ? error.message : String(error)}`);
    return {};
  }
}

function currentCommit() {
  const result = spawnSync("git", ["-C", path.join(deployDir, "repo"), "rev-parse", "HEAD"], {
    encoding: "utf8",
  });
  return result.status === 0 ? result.stdout.trim() : "";
}

function validateApprovalPacketBinding(approval) {
  const binding = approval.approvalPacket;
  const packetStatus = parseJsonText(process.env.APPROVAL_PACKET_STATUS_JSON || "{}", "当前批准前证据包状态");
  if (!binding || typeof binding !== "object" || Array.isArray(binding)) {
    fail("approvalPacket 必须记录本次批准绑定的证据包");
    return;
  }
  if (binding.status !== "ready") fail("approvalPacket.status 必须为 ready");
  if (typeof binding.packetFile !== "string" || binding.packetFile.trim() === "") {
    fail("approvalPacket.packetFile 必须填写");
  }
  if (binding.target?.instanceId !== expectedInstanceId) fail(`approvalPacket.target.instanceId 必须为 ${expectedInstanceId}`);
  if (binding.target?.action !== "healthcheck") fail("approvalPacket.target.action 必须为 healthcheck");
  if (binding.target?.operator !== expectedOperator) fail(`approvalPacket.target.operator 必须为 ${expectedOperator}`);

  const approvedPacketCommit = binding.commit?.packet || "";
  const approvedCurrentCommit = binding.commit?.current || "";
  const head = currentCommit();
  if (!approvedPacketCommit || !approvedCurrentCommit) {
    fail("approvalPacket.commit.packet/current 必须填写");
  }
  if (approvedPacketCommit && approvedCurrentCommit && approvedPacketCommit !== approvedCurrentCommit) {
    fail("approvalPacket.commit.packet 必须等于 approvalPacket.commit.current");
  }
  if (head && approvedCurrentCommit && approvedCurrentCommit !== head) {
    fail(`approvalPacket.commit.current 与当前部署提交不一致：approval=${approvedCurrentCommit.slice(0, 12)} current=${head.slice(0, 12)}`);
  }

  if (packetStatus.status !== "ready") {
    fail(`当前批准前证据包未 ready：${packetStatus.status || "unknown"}`);
  }
  if (packetStatus.packetFile && binding.packetFile && packetStatus.packetFile !== binding.packetFile) {
    fail("approvalPacket.packetFile 与当前通过校验的证据包不一致");
  }
  if (packetStatus.commit?.current && approvedCurrentCommit && packetStatus.commit.current !== approvedCurrentCommit) {
    fail("approvalPacket.commit.current 与当前通过校验的证据包提交不一致");
  }
  if (packetStatus.target?.instanceId && packetStatus.target.instanceId !== expectedInstanceId) {
    fail(`当前批准前证据包 instanceId 必须为 ${expectedInstanceId}`);
  }
}

const approval = readJson(file);
if (approval.schemaVersion !== 1) fail("schemaVersion 必须为 1");
if (approval.approved !== true) fail("approved 必须为 true");
if (approval.consumed === true) fail("批准记录已被使用，请重新运行 approve 生成新的批准记录");
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

validateApprovalPacketBinding(approval);

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

show_status() {
  local input="${1:-$APPROVAL_FILE}"
  local packet_status
  packet_status="$(read_packet_status_for_report)"
  APPROVAL_FILE="$input" \
    INSTANCE_ID="$INSTANCE_ID" \
    OPERATOR="$OPERATOR" \
    APPROVAL_MAX_AGE_HOURS="$APPROVAL_MAX_AGE_HOURS" \
    DEPLOY_DIR="$DEPLOY_DIR" \
    APPROVAL_PACKET_STATUS_JSON="$packet_status" \
    node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const file = process.env.APPROVAL_FILE;
const expectedInstanceId = process.env.INSTANCE_ID || "tom";
const expectedOperator = process.env.OPERATOR || "Anan";
const maxAgeHours = Number(process.env.APPROVAL_MAX_AGE_HOURS || "24");
const deployDir = process.env.DEPLOY_DIR || "/srv/openclaw-control-center-readonly";

function print(status, extra = {}) {
  console.log(JSON.stringify({ status, file, ...extra }, null, 2));
}

if (!fs.existsSync(file)) {
  print("missing", {
    nextAction: `run live-healthcheck-approval.sh prepare ${file}`,
  });
  process.exit(0);
}

let approval;
try {
  approval = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (error) {
  print("invalid_json", {
    message: error instanceof Error ? error.message : String(error),
  });
  process.exit(0);
}

const issues = [];
if (approval.approved !== true) issues.push("approved is not true");
const consumed = approval.consumed === true;
if (consumed) issues.push("approval has been consumed; run approve again");
if (typeof approval.approvedBy !== "string" || approval.approvedBy.trim() === "") issues.push("approvedBy is empty");
const approvedAtMs = Date.parse(String(approval.approvedAt || ""));
if (!Number.isFinite(approvedAtMs)) {
  issues.push("approvedAt is invalid");
} else if (Number.isFinite(maxAgeHours) && maxAgeHours > 0) {
  const ageMs = Date.now() - approvedAtMs;
  if (ageMs < -5 * 60 * 1000) issues.push("approvedAt is too far in the future");
  if (ageMs > maxAgeHours * 60 * 60 * 1000) issues.push(`approval is older than ${maxAgeHours}h`);
}
if (approval.instanceId !== expectedInstanceId) issues.push(`instanceId is not ${expectedInstanceId}`);
if (approval.action !== "healthcheck") issues.push("action is not healthcheck");
if (approval.operator !== expectedOperator) issues.push(`operator is not ${expectedOperator}`);
if (approval.risk !== "low") issues.push("risk is not low");
if (approval.scope?.mutatesOpenClawInstance !== false) issues.push("scope.mutatesOpenClawInstance is not false");
const packetStatus = parsePacketStatus();
if (approval.approved === true && !consumed) validateApprovalPacketBinding(approval, packetStatus, issues);
const checklist = approval.checklist || {};
for (const key of [
  "understandsTemporaryLiveGate",
  "understandsLocalTokenRequired",
  "understandsAutoRollback",
  "understandsImpactSnapshot",
]) {
  if (checklist[key] !== true) issues.push(`checklist.${key} is not true`);
}

print(consumed ? "consumed" : issues.length === 0 ? "approved" : "needs_manual_approval", {
  approvalId: typeof approval.approvalId === "string" ? approval.approvalId : "",
  approved: approval.approved === true,
  approvedBy: typeof approval.approvedBy === "string" ? approval.approvedBy : "",
  approvedAt: typeof approval.approvedAt === "string" ? approval.approvedAt : "",
  consumed,
  consumedAt: typeof approval.consumedAt === "string" ? approval.consumedAt : "",
  consumedBy: typeof approval.consumedBy === "string" ? approval.consumedBy : "",
  instanceId: approval.instanceId,
  action: approval.action,
  operator: approval.operator,
  approvalPacket: approval.approvalPacket && typeof approval.approvalPacket === "object" ? {
    packetFile: approval.approvalPacket.packetFile || "",
    generatedAt: approval.approvalPacket.generatedAt || "",
    checkedAt: approval.approvalPacket.checkedAt || "",
    commit: approval.approvalPacket.commit || {},
  } : undefined,
  issues,
});

function parsePacketStatus() {
  try {
    return JSON.parse(process.env.APPROVAL_PACKET_STATUS_JSON || "{}");
  } catch {
    return { status: "invalid_packet_status" };
  }
}

function currentCommit() {
  const result = spawnSync("git", ["-C", path.join(deployDir, "repo"), "rev-parse", "HEAD"], {
    encoding: "utf8",
  });
  return result.status === 0 ? result.stdout.trim() : "";
}

function validateApprovalPacketBinding(approval, packetStatus, issues) {
  const binding = approval.approvalPacket;
  if (!binding || typeof binding !== "object" || Array.isArray(binding)) {
    issues.push("approvalPacket is missing; re-approve against the current packet");
    return;
  }
  if (binding.status !== "ready") issues.push("approvalPacket.status is not ready");
  if (typeof binding.packetFile !== "string" || binding.packetFile.trim() === "") {
    issues.push("approvalPacket.packetFile is empty");
  }
  if (binding.target?.instanceId !== expectedInstanceId) issues.push(`approvalPacket.target.instanceId is not ${expectedInstanceId}`);
  if (binding.target?.action !== "healthcheck") issues.push("approvalPacket.target.action is not healthcheck");
  if (binding.target?.operator !== expectedOperator) issues.push(`approvalPacket.target.operator is not ${expectedOperator}`);
  const approvedPacketCommit = binding.commit?.packet || "";
  const approvedCurrentCommit = binding.commit?.current || "";
  const head = currentCommit();
  if (!approvedPacketCommit || !approvedCurrentCommit) {
    issues.push("approvalPacket.commit.packet/current is empty");
  }
  if (approvedPacketCommit && approvedCurrentCommit && approvedPacketCommit !== approvedCurrentCommit) {
    issues.push("approvalPacket.commit.packet does not match approvalPacket.commit.current");
  }
  if (head && approvedCurrentCommit && approvedCurrentCommit !== head) {
    issues.push(`approvalPacket commit is not current deploy commit: approval=${approvedCurrentCommit.slice(0, 12)} current=${head.slice(0, 12)}`);
  }
  if (packetStatus.status !== "ready") {
    issues.push(`current approval packet is not ready: ${packetStatus.status || "unknown"}`);
  }
  if (packetStatus.packetFile && binding.packetFile && packetStatus.packetFile !== binding.packetFile) {
    issues.push("approvalPacket.packetFile does not match current checked packet");
  }
  if (packetStatus.commit?.current && approvedCurrentCommit && packetStatus.commit.current !== approvedCurrentCommit) {
    issues.push("approvalPacket commit does not match current checked packet");
  }
}
NODE
}

usage() {
  cat <<'TEXT'
用法：
  live-healthcheck-approval.sh prepare [approval.json]
  live-healthcheck-approval.sh approve [approval.json]
  live-healthcheck-approval.sh consume [approval.json]
  live-healthcheck-approval.sh template [approval.json]
  live-healthcheck-approval.sh check [approval.json]
  live-healthcheck-approval.sh status [approval.json]

说明：
  prepare 只在文件不存在时生成模板，并输出当前状态。
  approve 需要 CONFIRM_APPROVAL_RECORD、APPROVED_BY 和已通过校验的批准前证据包；只写批准文件，不会启用 live gate。
  consume 将已批准记录标记为已使用，后续 check 会要求重新 approve。
  template 只生成批准文件模板，不会启用 live gate。
  check 只校验批准文件，不会调用 live API。
  status 只读取批准文件状态，不会失败，也不会调用 live API。
TEXT
}

main() {
  require_command node
  case "${1:-check}" in
    prepare)
      prepare_template "${2:-$APPROVAL_FILE}"
      ;;
    approve)
      approve_record "${2:-$APPROVAL_FILE}"
      ;;
    consume)
      consume_record "${2:-$APPROVAL_FILE}"
      ;;
    template)
      write_template "${2:-$APPROVAL_FILE}"
      ;;
    check)
      check_approval "${2:-$APPROVAL_FILE}"
      ;;
    status)
      show_status "${2:-$APPROVAL_FILE}"
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
