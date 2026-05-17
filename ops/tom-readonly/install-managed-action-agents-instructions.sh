#!/usr/bin/env bash
set -euo pipefail
set +x

# 安装 Tom AGENTS.md 中的 control-center inbox 使用规范。
# plan/status 不写文件；apply 必须显式确认，并只更新 AGENTS.md 标记块。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
if [ "$(basename "$DEFAULT_DEPLOY_DIR")" = "repo" ] && [ -d "${DEFAULT_DEPLOY_DIR}/../runtime" ]; then
  DEFAULT_DEPLOY_DIR="$(cd "${DEFAULT_DEPLOY_DIR}/.." && pwd)"
fi

export DEPLOY_DIR="${DEPLOY_DIR:-$DEFAULT_DEPLOY_DIR}"
export MODE_NAME="${1:-status}"
export MANAGED_ACTION_AGENTS_TARGET_SOURCE="${MANAGED_ACTION_AGENTS_TARGET_SOURCE:-local}"
export MANAGED_ACTION_AGENTS_TARGET_PATH="${MANAGED_ACTION_AGENTS_TARGET_PATH:-/home/node/.openclaw/workspace/AGENTS.md}"
export MANAGED_ACTION_AGENTS_CONTAINER="${MANAGED_ACTION_AGENTS_CONTAINER:-openclaw-work-openclaw-gateway-1}"
export MANAGED_ACTION_AGENTS_INBOX_PATH="${MANAGED_ACTION_AGENTS_INBOX_PATH:-/home/node/.openclaw/workspace/control-center-commands/inbox}"
export CONFIRM_MANAGED_ACTION_AGENTS_INSTALL="${CONFIRM_MANAGED_ACTION_AGENTS_INSTALL:-}"

usage() {
  cat <<'TEXT'
用法：
  install-managed-action-agents-instructions.sh status
  install-managed-action-agents-instructions.sh plan
  install-managed-action-agents-instructions.sh apply

常用环境变量：
  MANAGED_ACTION_AGENTS_TARGET_SOURCE=local|openclaw-container
  MANAGED_ACTION_AGENTS_TARGET_PATH=/home/node/.openclaw/workspace/AGENTS.md
  MANAGED_ACTION_AGENTS_CONTAINER=openclaw-work-openclaw-gateway-1
  MANAGED_ACTION_AGENTS_INBOX_PATH=/home/node/.openclaw/workspace/control-center-commands/inbox

apply 必须设置：
  CONFIRM_MANAGED_ACTION_AGENTS_INSTALL=I_UNDERSTAND_THIS_UPDATES_TOM_AGENTS_INSTRUCTIONS_ONLY

安全边界：
  - status/plan 不写文件。
  - apply 只更新 AGENTS.md 中的受控标记块，并备份原文件。
  - 不修改 OpenClaw 配置，不重启实例，不打开 live gate。
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
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const mode = process.env.MODE_NAME || "status";
const targetSource = process.env.MANAGED_ACTION_AGENTS_TARGET_SOURCE || "local";
const targetPath = process.env.MANAGED_ACTION_AGENTS_TARGET_PATH || "/home/node/.openclaw/workspace/AGENTS.md";
const containerName = process.env.MANAGED_ACTION_AGENTS_CONTAINER || "openclaw-work-openclaw-gateway-1";
const inboxPath = process.env.MANAGED_ACTION_AGENTS_INBOX_PATH || "/home/node/.openclaw/workspace/control-center-commands/inbox";
const confirm = process.env.CONFIRM_MANAGED_ACTION_AGENTS_INSTALL || "";
const confirmation = "I_UNDERSTAND_THIS_UPDATES_TOM_AGENTS_INSTRUCTIONS_ONLY";
const markerBegin = "<!-- OPENCLAW_CONTROL_CENTER_MANAGED_ACTIONS_BEGIN -->";
const markerEnd = "<!-- OPENCLAW_CONTROL_CENTER_MANAGED_ACTIONS_END -->";

function compactLines(text, limit = 40) {
  return String(text || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, limit);
}

function baseSafety(extra = {}) {
  return {
    writesAgentsMdOnly: false,
    writesOpenClawWorkspaceAgentsMdOnly: false,
    writesOpenClawConfig: false,
    writesOpenClawInstanceDirs: false,
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

function blocked(status, issue, extra = {}, code = 2) {
  emit({
    schemaVersion: 1,
    status,
    mode,
    generatedAt: new Date().toISOString(),
    issues: [issue],
    target: targetSummary(),
    nextCommands: [
      "repo/ops/tom-readonly/install-managed-action-agents-instructions.sh status",
      "repo/ops/tom-readonly/install-managed-action-agents-instructions.sh plan",
      `CONFIRM_MANAGED_ACTION_AGENTS_INSTALL=${confirmation} repo/ops/tom-readonly/install-managed-action-agents-instructions.sh apply`,
    ],
    safety: baseSafety({
      blockedBeforeWrite: true,
      ...extra,
    }),
  }, code);
}

function targetSummary() {
  return {
    source: targetSource,
    path: targetPath,
    ...(targetSource === "openclaw-container" ? { container: containerName } : {}),
  };
}

function renderBlock() {
  return [
    markerBegin,
    "## OpenClaw Control Center 受控管理动作",
    "",
    "当 Anan 在 Discord/Tom 中明确要求“控制中心 dry-run”“管理动作 dry-run”“对 <实例> 运行 <skill> dry-run”“预览控制中心动作”或类似请求时，按下面规则处理：",
    "",
    `1. 只写入 inbox 文本请求：先创建 \`${inboxPath}\`，再把 Anan 的原始请求逐字写入一个新的 \`.txt\` 文件。建议文件名使用 UTC 时间，例如 \`$(date -u +%Y%m%dT%H%M%SZ)-managed-action.txt\`。`,
    "2. 文本必须明确包含 `dry-run`、`预览` 或 `演练`；如果 Anan 的话没有这些词，先询问是否只做 dry-run，不要写成真实执行。",
    "3. 如果文本包含 `发布`、`真实执行`、`live`、`重启`、`approval`、`批准` 等高风险词，只说明该请求会被 control-center 阻断，不要声称已经执行。",
    "4. 写入 inbox 后，向 Anan 回报 inbox 文件路径，并说明 host 侧会用 `managed-action-inbox-runner.sh status/plan-next/run-next` 读取并创建 dry-run 审计。",
    "5. 不要调用 control-center API，不要读取或输出 LOCAL_API_TOKEN，不能把令牌写进日志或 Discord；不要打开 live gate，不要重启任何 OpenClaw 实例，不要删除或移动 inbox 请求文件。",
    "6. control-center 返回 dry-run 结果后，只汇报 `status`、`runnerStatus`、`operationRequestId`、`commandPreview` 和安全字段；不要把 dry-run 说成真实执行完成。",
    "",
    "可写入 inbox 的示例文本：",
    "",
    "```text",
    "对 tom 运行 zhihu-human-ops-writing dry-run",
    "```",
    markerEnd,
  ].join("\n");
}

function replaceBlock(content, block) {
  const start = content.indexOf(markerBegin);
  const end = content.indexOf(markerEnd);
  if (start >= 0 && end >= 0 && end > start) {
    return `${content.slice(0, start).replace(/\s*$/, "\n\n")}${block}${content.slice(end + markerEnd.length).replace(/^\s*/, "\n\n")}`;
  }
  return `${content.replace(/\s*$/, "\n\n")}${block}\n`;
}

function readLocalFile(filePath) {
  if (!fs.existsSync(filePath)) return "";
  return fs.readFileSync(filePath, "utf8");
}

function writeLocalFile(filePath, content) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content, "utf8");
}

function backupLocalFile(filePath, content) {
  const backupDir = path.join(path.dirname(filePath), ".backup", "control-center-agents");
  fs.mkdirSync(backupDir, { recursive: true });
  const backupPath = path.join(backupDir, `${new Date().toISOString().replace(/[:.]/g, "-")}-AGENTS.md`);
  fs.writeFileSync(backupPath, content, "utf8");
  return backupPath;
}

function dockerExec(args, options = {}) {
  return spawnSync("docker", ["exec", "-i", ...args], {
    encoding: "utf8",
    env: process.env,
    ...options,
  });
}

function readContainerFile() {
  const result = dockerExec([
    "-e",
    `TARGET_PATH=${targetPath}`,
    containerName,
    "sh",
    "-lc",
    'if [ -f "$TARGET_PATH" ]; then cat -- "$TARGET_PATH"; fi',
  ]);
  if (result.status !== 0) {
    blocked("blocked_target_read_failed", `无法读取容器 AGENTS.md：${compactLines(result.stderr || result.stdout, 5).join("；")}`);
  }
  return result.stdout;
}

function writeContainerFile(content) {
  const result = dockerExec([
    "-e",
    `TARGET_PATH=${targetPath}`,
    containerName,
    "sh",
    "-lc",
    'mkdir -p "$(dirname "$TARGET_PATH")" && cat > "$TARGET_PATH"',
  ], {
    input: content,
  });
  if (result.status !== 0) {
    blocked("blocked_target_write_failed", `无法写入容器 AGENTS.md：${compactLines(result.stderr || result.stdout, 5).join("；")}`);
  }
}

function backupContainerFile(content) {
  const backupName = `${new Date().toISOString().replace(/[:.]/g, "-")}-AGENTS.md`;
  const result = dockerExec([
    "-e",
    `TARGET_PATH=${targetPath}`,
    "-e",
    `BACKUP_NAME=${backupName}`,
    containerName,
    "sh",
    "-lc",
    'backup_dir="$(dirname "$TARGET_PATH")/.backup/control-center-agents"; mkdir -p "$backup_dir"; cat > "$backup_dir/$BACKUP_NAME"; printf "%s" "$backup_dir/$BACKUP_NAME"',
  ], {
    input: content,
  });
  if (result.status !== 0) {
    blocked("blocked_target_backup_failed", `无法备份容器 AGENTS.md：${compactLines(result.stderr || result.stdout, 5).join("；")}`);
  }
  return result.stdout.trim();
}

function readTarget() {
  if (targetSource === "local") return readLocalFile(targetPath);
  if (targetSource === "openclaw-container") return readContainerFile();
  blocked("blocked_invalid_target_source", `未知 MANAGED_ACTION_AGENTS_TARGET_SOURCE：${targetSource}`);
}

function writeTarget(content) {
  if (targetSource === "local") {
    writeLocalFile(targetPath, content);
    return;
  }
  if (targetSource === "openclaw-container") {
    writeContainerFile(content);
    return;
  }
  blocked("blocked_invalid_target_source", `未知 MANAGED_ACTION_AGENTS_TARGET_SOURCE：${targetSource}`);
}

function backupTarget(content) {
  if (targetSource === "local") return backupLocalFile(targetPath, content);
  if (targetSource === "openclaw-container") return backupContainerFile(content);
  blocked("blocked_invalid_target_source", `未知 MANAGED_ACTION_AGENTS_TARGET_SOURCE：${targetSource}`);
}

function compute() {
  const existing = readTarget();
  const block = renderBlock();
  const next = replaceBlock(existing, block);
  return {
    existing,
    block,
    next,
    installed: existing.includes(markerBegin) && existing.includes(markerEnd),
    needsUpdate: existing !== next,
  };
}

function statusReport() {
  const computed = compute();
  emit({
    schemaVersion: 1,
    status: computed.needsUpdate ? "agents_instructions_needs_update" : "agents_instructions_installed",
    mode,
    generatedAt: new Date().toISOString(),
    target: targetSummary(),
    installed: computed.installed,
    needsUpdate: computed.needsUpdate,
    safety: baseSafety(),
  });
}

function planReport() {
  const computed = compute();
  emit({
    schemaVersion: 1,
    status: "agents_instructions_plan_ready",
    mode,
    generatedAt: new Date().toISOString(),
    target: targetSummary(),
    plan: {
      installed: computed.installed,
      needsUpdate: computed.needsUpdate,
      markerBegin,
      markerEnd,
      block: computed.block,
    },
    nextCommands: computed.needsUpdate
      ? [`CONFIRM_MANAGED_ACTION_AGENTS_INSTALL=${confirmation} repo/ops/tom-readonly/install-managed-action-agents-instructions.sh apply`]
      : [],
    safety: baseSafety(),
  });
}

function applyReport() {
  if (confirm !== confirmation) {
    blocked("blocked_confirmation_required", `apply 必须设置 CONFIRM_MANAGED_ACTION_AGENTS_INSTALL=${confirmation}。`);
  }
  const computed = compute();
  if (!computed.needsUpdate) {
    emit({
      schemaVersion: 1,
      status: "agents_instructions_already_installed",
      mode,
      generatedAt: new Date().toISOString(),
      target: targetSummary(),
      safety: baseSafety(),
    });
  }
  const backupPath = backupTarget(computed.existing);
  writeTarget(computed.next);
  emit({
    schemaVersion: 1,
    status: "agents_instructions_installed",
    mode,
    generatedAt: new Date().toISOString(),
    target: targetSummary(),
    backupPath,
    safety: baseSafety({
      writesAgentsMdOnly: true,
      writesOpenClawWorkspaceAgentsMdOnly: true,
      writesOpenClawConfig: false,
      writesOpenClawInstanceDirs: false,
      restartsOpenClawInstances: false,
      callsManagedActionsLiveApi: false,
      opensLiveGate: false,
    }),
  });
}

if (!["status", "plan", "apply"].includes(mode)) {
  blocked("blocked_invalid_mode", `未知模式：${mode}。支持 status、plan、apply。`);
}
if (mode === "status") statusReport();
if (mode === "plan") planReport();
if (mode === "apply") applyReport();
NODE
