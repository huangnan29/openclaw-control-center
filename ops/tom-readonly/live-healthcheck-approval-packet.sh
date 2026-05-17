#!/usr/bin/env bash
set -euo pipefail
set +x

# live healthcheck 批准前证据包。
# generate 会读取总闸门、dry-run、approval、live window 状态，并生成一次影响快照。
# 本脚本只写 control-center runtime 证据文件，不修改 OpenClaw 实例目录，不调用 managed-actions live API。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
BUNDLE_DIR="${BUNDLE_DIR:-${DEPLOY_DIR}/runtime/remote-onboarding/remote-oracle}"
APPROVAL_FILE="${APPROVAL_FILE:-${DEPLOY_DIR}/runtime/live-healthcheck-approval.json}"
PACKET_DIR="${PACKET_DIR:-${DEPLOY_DIR}/runtime/live-healthcheck-approval-packets}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
OPENCLAW_TOPOLOGY_MODE="${OPENCLAW_TOPOLOGY_MODE:-local-only}"
PACKET_MAX_AGE_SECONDS="${PACKET_MAX_AGE_SECONDS:-21600}"

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

generate_packet() {
  mkdir -p "$PACKET_DIR"
  local json_packet="${PACKET_DIR}/live-healthcheck-approval-packet-$(safe_timestamp).json"
  local md_packet="${json_packet%.json}.md"

  log "生成 live healthcheck 批准前证据包：${json_packet}"

  DEPLOY_DIR="$DEPLOY_DIR" \
    BUNDLE_DIR="$BUNDLE_DIR" \
    APPROVAL_FILE="$APPROVAL_FILE" \
    SCRIPT_DIR="$SCRIPT_DIR" \
    OPENCLAW_TOPOLOGY_MODE="$OPENCLAW_TOPOLOGY_MODE" \
    JSON_PACKET="$json_packet" \
    MD_PACKET="$md_packet" \
    node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const deployDir = path.resolve(process.env.DEPLOY_DIR || "/srv/openclaw-control-center-readonly");
const bundleDir = path.resolve(process.env.BUNDLE_DIR || path.join(deployDir, "runtime", "remote-onboarding", "remote-oracle"));
const approvalFile = path.resolve(process.env.APPROVAL_FILE || path.join(deployDir, "runtime", "live-healthcheck-approval.json"));
const scriptDir = path.resolve(process.env.SCRIPT_DIR || path.join(deployDir, "repo", "ops", "tom-readonly"));
const topologyMode = process.env.OPENCLAW_TOPOLOGY_MODE || "local-only";
const jsonPacket = path.resolve(process.env.JSON_PACKET);
const mdPacket = path.resolve(process.env.MD_PACKET);

const scripts = {
  goLiveGate: process.env.GO_LIVE_GATE_SCRIPT || path.join(scriptDir, "go-live-gate.sh"),
  dryRunGate: process.env.MANAGED_ACTION_DRY_RUN_GATE_SCRIPT || path.join(scriptDir, "managed-action-dry-run-gate.sh"),
  approval: process.env.LIVE_HEALTHCHECK_APPROVAL_SCRIPT || path.join(scriptDir, "live-healthcheck-approval.sh"),
  liveWindow: process.env.LIVE_HEALTHCHECK_WINDOW_SCRIPT || path.join(scriptDir, "live-healthcheck-window.sh"),
  impactSnapshot: process.env.INSTANCE_IMPACT_SNAPSHOT_SCRIPT || path.join(scriptDir, "instance-impact-snapshot.sh"),
};

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: deployDir,
    env: {
      ...process.env,
      DEPLOY_DIR: deployDir,
      OPENCLAW_TOPOLOGY_MODE: topologyMode,
    },
    encoding: "utf8",
    maxBuffer: 30 * 1024 * 1024,
    timeout: options.timeoutMs ?? 120_000,
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

function readJsonFile(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    return {
      status: "invalid_file",
      file,
      error: formatError(error),
    };
  }
}

function extractJsonObjects(text) {
  const objects = [];
  let depth = 0;
  let start = -1;
  let inString = false;
  let escaped = false;
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (char === "\\") {
        escaped = true;
      } else if (char === "\"") {
        inString = false;
      }
      continue;
    }
    if (char === "\"") {
      inString = true;
      continue;
    }
    if (char === "{") {
      if (depth === 0) start = index;
      depth += 1;
      continue;
    }
    if (char === "}") {
      depth -= 1;
      if (depth === 0 && start >= 0) {
        try {
          objects.push(JSON.parse(text.slice(start, index + 1)));
        } catch {
          // 忽略日志中的非 JSON 花括号片段。
        }
        start = -1;
      }
    }
  }
  return objects;
}

function compactLines(text, limit = 80) {
  return String(text || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, limit);
}

function lastNonEmptyLine(text) {
  return compactLines(text, 500).at(-1) || "";
}

function formatError(error) {
  return error instanceof Error ? error.message : String(error);
}

function deriveApprovalFromStatus(result) {
  const objects = extractJsonObjects(`${result.stdout}\n${result.stderr}`);
  return objects.find((item) => item && typeof item === "object" && "approved" in item && "consumed" in item) || parseJson(result.stdout, "approval status");
}

function deriveLiveWindowStatus(result) {
  const combined = `${result.stdout}\n${result.stderr}`;
  const approval = extractJsonObjects(combined).find((item) => item && typeof item === "object" && "approved" in item && "consumed" in item);
  return {
    exitCode: result.exitCode,
    approvalStatus: approval?.status || "unknown",
    readonlyMode: firstMatch(combined, /READONLY_MODE=([^\s]+)/) || "unknown",
    liveEnabled: firstMatch(combined, /MANAGED_ACTIONS_LIVE_ENABLED=([^\s]+)/) || "unknown",
    executorEnabled: firstMatch(combined, /MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED=([^\s]+)/) || "unknown",
    readinessStatus: firstMatch(combined, /readiness\.status=([^\s]+)/) || "unknown",
    liveExecutionAvailable: firstMatch(combined, /readiness\.liveExecutionAvailable=([^\s]+)/) || "unknown",
    executorProductionWired: firstMatch(combined, /readiness\.executor\.productionWired=([^\s]+)/) || "unknown",
    rawLines: compactLines(combined, 80),
  };
}

function firstMatch(text, pattern) {
  const match = String(text || "").match(pattern);
  return match ? match[1] : undefined;
}

function collectBlockers(gate, dryRun, approval, liveWindow, impactSnapshot) {
  const blockers = [];
  if (gate.status !== "blocked_managed_actions" && gate.status !== "ready_for_existing_instance_healthcheck") {
    blockers.push(`总闸门状态异常：${gate.status || "unknown"}`);
  }
  if (gate.mode === "check" && gate.stages?.existingInstances?.status !== "passed") {
    blockers.push("现有实例 healthcheck 未通过");
  }
  if (gate.stages?.crossServerReadonlyMonitoring?.status !== "skipped_local_only" && topologyMode === "local-only") {
    blockers.push("local-only 模式下跨服务器阶段未跳过");
  }
  if (dryRun.status !== "ready") blockers.push(`dry-run 证据未 ready：${dryRun.status || "unknown"}`);
  if (!impactSnapshot.path || !fs.existsSync(impactSnapshot.path)) blockers.push("影响快照未生成");
  if (liveWindow.readonlyMode !== "true") blockers.push(`READONLY_MODE 不是 true：${liveWindow.readonlyMode}`);
  if (liveWindow.liveEnabled === "true") blockers.push("live gate 已经开启，批准前证据包不应在 live 窗口内生成");
  if (liveWindow.executorEnabled === "true") blockers.push("live executor 已经开启，批准前证据包不应在 live 窗口内生成");
  if (approval.status !== "needs_manual_approval" && approval.status !== "approved" && approval.status !== "approved_ready") {
    blockers.push(`approval 状态异常：${approval.status || "unknown"}`);
  }
  return blockers;
}

function buildMarkdown(packet) {
  const lines = [];
  lines.push("# Live Healthcheck 批准前证据包");
  lines.push("");
  lines.push(`- 状态：${packet.status}`);
  lines.push(`- 生成时间：${packet.generatedAt}`);
  lines.push(`- 拓扑：${packet.topologyMode}`);
  lines.push(`- 提交：${packet.git.short || packet.git.head || ""}`);
  lines.push(`- 实例：${packet.target.instanceId}`);
  lines.push(`- 动作：${packet.target.action}`);
  lines.push(`- 操作者：${packet.target.operator}`);
  lines.push("");
  lines.push("## 当前闸门");
  lines.push("");
  lines.push(`- 总闸门：${packet.gates.goLive.status}`);
  lines.push(`- 现有实例 healthcheck：${packet.gates.goLive.existingInstancesStatus}`);
  lines.push(`- 跨服务器阶段：${packet.gates.goLive.crossServerStatus}`);
  lines.push(`- dry-run 证据：${packet.gates.dryRun.status}`);
  lines.push(`- approval：${packet.gates.approval.status}`);
  lines.push(`- live window readonly：${packet.gates.liveWindow.readonlyMode}`);
  lines.push(`- liveExecutionAvailable：${packet.gates.liveWindow.liveExecutionAvailable}`);
  lines.push("");
  lines.push("## 证据文件");
  lines.push("");
  lines.push(`- 影响快照：${packet.artifacts.impactSnapshot}`);
  lines.push(`- approval 文件：${packet.artifacts.approvalFile}`);
  lines.push(`- JSON 证据包：${packet.artifacts.jsonPacket}`);
  lines.push("");
  lines.push("## 阻塞项");
  lines.push("");
  if (packet.blockers.length === 0) {
    lines.push("- 无预检阻塞；等待人工批准。");
  } else {
    for (const blocker of packet.blockers) lines.push(`- ${blocker}`);
  }
  lines.push("");
  lines.push("## 下一步");
  lines.push("");
  for (const command of packet.nextCommands) lines.push(`- \`${command}\``);
  lines.push("");
  lines.push("## 安全边界");
  lines.push("");
  lines.push("- 未调用 managed-actions live API。");
  lines.push("- 未修改任何 OpenClaw 实例目录。");
  lines.push("- 未重启任何 OpenClaw 实例。");
  lines.push("- 只写 control-center runtime 下的审批前证据文件。");
  return `${lines.join("\n")}\n`;
}

const goLiveResult = run(scripts.goLiveGate, ["check", bundleDir], { timeoutMs: 180_000 });
const dryRunResult = run(scripts.dryRunGate, ["status"]);
const approvalResult = run(scripts.approval, ["status", approvalFile]);
const liveWindowResult = run(scripts.liveWindow, ["status"]);
const impactResult = run(scripts.impactSnapshot, ["snapshot", "pre-live-approval-packet"], { timeoutMs: 180_000 });

const goLive = parseJson(goLiveResult.stdout, "go-live gate");
const dryRun = parseJson(dryRunResult.stdout, "managed action dry-run gate");
const approval = deriveApprovalFromStatus(approvalResult);
const liveWindow = deriveLiveWindowStatus(liveWindowResult);
const impactPath = lastNonEmptyLine(impactResult.stdout);
const impactSnapshot = {
  path: impactPath,
  exitCode: impactResult.exitCode,
  report: impactPath && fs.existsSync(impactPath) ? readJsonFile(impactPath) : undefined,
};
const blockers = collectBlockers(goLive, dryRun, approval, liveWindow, impactSnapshot);
const target = {
  instanceId: dryRun.target?.instanceId || approval.instanceId || "tom",
  action: dryRun.target?.action || approval.action || "healthcheck",
  operator: dryRun.target?.operator || approval.operator || "Anan",
};
const gitHead = impactSnapshot.report?.repoCommit || "";

const packet = {
  schemaVersion: 1,
  status: blockers.length === 0 ? "ready_for_manual_approval" : "blocked_preconditions",
  generatedAt: new Date().toISOString(),
  topologyMode,
  deployDir,
  target,
  git: {
    head: gitHead,
    short: gitHead ? gitHead.slice(0, 7) : "",
  },
  gates: {
    goLive: {
      status: goLive.status,
      existingInstancesStatus: goLive.stages?.existingInstances?.status,
      crossServerStatus: goLive.stages?.crossServerReadonlyMonitoring?.status,
      managedActionsStatus: goLive.stages?.managedActions?.status,
      exitCode: goLiveResult.exitCode,
    },
    dryRun: {
      status: dryRun.status,
      latest: dryRun.audit?.latest,
      issues: dryRun.issues || [],
      exitCode: dryRunResult.exitCode,
    },
    approval: {
      status: approval.status,
      approved: approval.approved === true,
      consumed: approval.consumed === true,
      approvedBy: approval.approvedBy || "",
      approvedAt: approval.approvedAt || "",
      issues: approval.issues || [],
      exitCode: approvalResult.exitCode,
    },
    liveWindow,
    impactSnapshot: {
      status: impactSnapshot.path && fs.existsSync(impactSnapshot.path) ? "generated" : "missing",
      path: impactSnapshot.path,
      exitCode: impactSnapshot.exitCode,
    },
  },
  blockers,
  nextCommands: blockers.length === 0
    ? [
        "CONFIRM_APPROVAL_RECORD=I_APPROVE_LIVE_HEALTHCHECK_RECORD APPROVED_BY=Anan repo/ops/tom-readonly/live-healthcheck-approval.sh approve runtime/live-healthcheck-approval.json",
        "CONFIRM_LIVE_HEALTHCHECK_WINDOW=I_UNDERSTAND_THIS_TEMPORARILY_ENABLES_LIVE_GATE CONFIRM_LIVE_HEALTHCHECK=I_UNDERSTAND_THIS_CALLS_LIVE_API LOCAL_API_TOKEN=<本地令牌> INSTANCE_ID=tom OPERATOR=Anan repo/ops/tom-readonly/live-healthcheck-window.sh run",
      ]
    : ["先处理 blockers，再重新生成批准前证据包。"],
  artifacts: {
    jsonPacket,
    markdownPacket: mdPacket,
    approvalFile,
    impactSnapshot: impactSnapshot.path,
  },
  safety: {
    writesControlCenterRuntimeOnly: true,
    createsImpactSnapshot: true,
    callsManagedActionsLiveApi: false,
    writesOpenClawInstanceDirs: false,
    restartsOpenClawInstances: false,
    bypassesApproval: false,
  },
  raw: {
    goLiveStderrLines: compactLines(goLiveResult.stderr, 40),
    dryRunStderrLines: compactLines(dryRunResult.stderr, 40),
    approvalStderrLines: compactLines(approvalResult.stderr, 40),
    liveWindowStderrLines: compactLines(liveWindowResult.stderr, 40),
    impactStderrLines: compactLines(impactResult.stderr, 40),
  },
};

fs.writeFileSync(jsonPacket, `${JSON.stringify(packet, null, 2)}\n`, "utf8");
fs.writeFileSync(mdPacket, buildMarkdown(packet), "utf8");
process.stdout.write(`${jsonPacket}\n`);
if (packet.status !== "ready_for_manual_approval") process.exitCode = 2;
NODE
}

check_packet() {
  local packet_file="${1:-}"

  DEPLOY_DIR="$DEPLOY_DIR" \
    PACKET_DIR="$PACKET_DIR" \
    PACKET_FILE="$packet_file" \
    OPENCLAW_TOPOLOGY_MODE="$OPENCLAW_TOPOLOGY_MODE" \
    PACKET_MAX_AGE_SECONDS="$PACKET_MAX_AGE_SECONDS" \
    INSTANCE_ID="${INSTANCE_ID:-tom}" \
    ACTION="${ACTION:-healthcheck}" \
    OPERATOR="${OPERATOR:-Anan}" \
    node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const deployDir = path.resolve(process.env.DEPLOY_DIR || "/srv/openclaw-control-center-readonly");
const packetDir = path.resolve(process.env.PACKET_DIR || path.join(deployDir, "runtime", "live-healthcheck-approval-packets"));
const explicitPacket = String(process.env.PACKET_FILE || "").trim();
const topologyMode = process.env.OPENCLAW_TOPOLOGY_MODE || "local-only";
const maxAgeSeconds = Number.parseInt(process.env.PACKET_MAX_AGE_SECONDS || "21600", 10);
const expected = {
  instanceId: process.env.INSTANCE_ID || "tom",
  action: process.env.ACTION || "healthcheck",
  operator: process.env.OPERATOR || "Anan",
};

function fail(message) {
  console.error(`[失败] ${message}`);
  process.exit(2);
}

function findLatestPacket() {
  if (!fs.existsSync(packetDir)) return undefined;
  const files = fs.readdirSync(packetDir)
    .filter((name) => /^live-healthcheck-approval-packet-.+\.json$/.test(name))
    .map((name) => path.join(packetDir, name))
    .map((file) => ({ file, mtimeMs: fs.statSync(file).mtimeMs }))
    .sort((a, b) => b.mtimeMs - a.mtimeMs);
  return files[0]?.file;
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    fail(`无法读取证据包：${file}：${formatError(error)}`);
  }
}

function currentCommit() {
  const result = spawnSync("git", ["-C", path.join(deployDir, "repo"), "rev-parse", "HEAD"], {
    encoding: "utf8",
  });
  return result.status === 0 ? result.stdout.trim() : "";
}

function formatError(error) {
  return error instanceof Error ? error.message : String(error);
}

function checkPacket(file, packet) {
  const issues = [];
  if (packet.schemaVersion !== 1) issues.push("schemaVersion must be 1");
  if (packet.status !== "ready_for_manual_approval") issues.push(`status is ${packet.status || "missing"}`);
  if (!Array.isArray(packet.blockers) || packet.blockers.length !== 0) issues.push("blockers must be empty");
  if (packet.topologyMode !== topologyMode) issues.push(`topologyMode mismatch: ${packet.topologyMode} != ${topologyMode}`);

  const generatedAtMs = Date.parse(String(packet.generatedAt || ""));
  const ageSeconds = Number.isFinite(generatedAtMs) ? Math.round((Date.now() - generatedAtMs) / 1000) : Number.NaN;
  if (!Number.isFinite(ageSeconds)) issues.push("generatedAt is invalid");
  if (Number.isFinite(ageSeconds) && ageSeconds < -60) issues.push("generatedAt is in the future");
  if (Number.isFinite(ageSeconds) && Number.isFinite(maxAgeSeconds) && ageSeconds > maxAgeSeconds) {
    issues.push(`packet is older than ${maxAgeSeconds}s`);
  }

  if (packet.target?.instanceId !== expected.instanceId) issues.push(`instanceId mismatch: ${packet.target?.instanceId}`);
  if (packet.target?.action !== expected.action) issues.push(`action mismatch: ${packet.target?.action}`);
  if (packet.target?.operator !== expected.operator) issues.push(`operator mismatch: ${packet.target?.operator}`);

  if (packet.gates?.goLive?.existingInstancesStatus !== "passed") issues.push("existing instance healthcheck is not passed");
  if (topologyMode === "local-only" && packet.gates?.goLive?.crossServerStatus !== "skipped_local_only") {
    issues.push("cross-server gate is not skipped in local-only mode");
  }
  if (packet.gates?.dryRun?.status !== "ready") issues.push("dry-run gate is not ready");
  if (!["needs_manual_approval", "approved", "approved_ready"].includes(packet.gates?.approval?.status || "")) {
    issues.push(`approval status is not acceptable: ${packet.gates?.approval?.status || "missing"}`);
  }
  if (packet.gates?.liveWindow?.readonlyMode !== "true") issues.push("live window readonlyMode is not true");
  if (packet.gates?.liveWindow?.liveEnabled === "true") issues.push("live gate was enabled when packet was generated");
  if (packet.gates?.liveWindow?.executorEnabled === "true") issues.push("live executor was enabled when packet was generated");
  if (packet.gates?.impactSnapshot?.status !== "generated") issues.push("impact snapshot was not generated");

  const impactSnapshot = packet.artifacts?.impactSnapshot || packet.gates?.impactSnapshot?.path;
  if (!impactSnapshot || !fs.existsSync(impactSnapshot)) issues.push(`impact snapshot file missing: ${impactSnapshot || "<empty>"}`);
  const markdownPacket = packet.artifacts?.markdownPacket;
  if (!markdownPacket || !fs.existsSync(markdownPacket)) issues.push(`markdown packet file missing: ${markdownPacket || "<empty>"}`);

  const head = currentCommit();
  if (head && packet.git?.head && packet.git.head !== head) {
    issues.push(`git commit mismatch: packet=${packet.git.head.slice(0, 12)} current=${head.slice(0, 12)}`);
  }
  if (packet.safety?.callsManagedActionsLiveApi !== false) issues.push("safety.callsManagedActionsLiveApi must be false");
  if (packet.safety?.writesOpenClawInstanceDirs !== false) issues.push("safety.writesOpenClawInstanceDirs must be false");
  if (packet.safety?.restartsOpenClawInstances !== false) issues.push("safety.restartsOpenClawInstances must be false");
  if (packet.safety?.bypassesApproval !== false) issues.push("safety.bypassesApproval must be false");

  return {
    schemaVersion: 1,
    status: issues.length === 0 ? "ready" : "blocked",
    checkedAt: new Date().toISOString(),
    packetFile: file,
    generatedAt: packet.generatedAt,
    ageSeconds: Number.isFinite(ageSeconds) ? ageSeconds : null,
    maxAgeSeconds,
    topologyMode,
    target: packet.target,
    commit: {
      packet: packet.git?.head || "",
      current: head,
    },
    issues,
    safety: {
      callsManagedActionsLiveApi: false,
      writesOpenClawInstanceDirs: false,
      restartsOpenClawInstances: false,
      bypassesApproval: false,
    },
  };
}

const file = explicitPacket ? path.resolve(explicitPacket) : findLatestPacket();
if (!file) fail(`找不到批准前证据包：${packetDir}`);
const report = checkPacket(file, readJson(file));
console.log(JSON.stringify(report, null, 2));
if (report.status !== "ready") process.exit(2);
NODE
}

usage() {
  cat <<'TEXT'
用法：
  live-healthcheck-approval-packet.sh generate
  live-healthcheck-approval-packet.sh check [packet.json]

说明：
  generate 会运行最终上线总闸门 check、dry-run 证据 status、approval status、live window status，
  并生成一份 pre-live 影响快照，最后写出 JSON 与 Markdown 证据包。
  check 会校验指定证据包；未指定时校验 PACKET_DIR 中最新的一份。
  本脚本不会批准 live healthcheck，不会打开 live gate，不会调用 managed-actions live API。
TEXT
}

main() {
  require_command node
  case "${1:-generate}" in
    generate)
      generate_packet
      ;;
    check)
      check_packet "${2:-}"
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
