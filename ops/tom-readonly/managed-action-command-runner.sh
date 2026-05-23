#!/usr/bin/env bash
set -euo pipefail
set +x

# OpenClaw/Discord 侧管理动作命令入口。
# plan 只校验命令并输出将要提交的 dry-run payload，不联网、不写审计。
# parse-text/plan-text 只解析自然语言文本并输出 dry-run payload，不联网、不写审计。
# dry-run 必须显式确认并提供 LOCAL_API_TOKEN，只调用 dry-run API 写审计，不执行实例命令。
# live 必须显式确认并提供 LOCAL_API_TOKEN，只调用 live API，且必须引用已存在 dry-run operationRequestId。
# status 只读取控制中心管理动作和 readiness 状态。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
CONTROL_CENTER_BASE_URL="${CONTROL_CENTER_BASE_URL:-http://127.0.0.1:4311}"
CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN="${CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN:-}"
CONFIRM_MANAGED_ACTION_COMMAND_LIVE="${CONFIRM_MANAGED_ACTION_COMMAND_LIVE:-}"
CONFIRM_MANAGED_ACTION_COMMAND_SKILL_RUN_LIVE="${CONFIRM_MANAGED_ACTION_COMMAND_SKILL_RUN_LIVE:-}"
LOCAL_API_TOKEN="${LOCAL_API_TOKEN:-}"
MANAGED_ACTION_COMMAND_TOKEN_SOURCE="${MANAGED_ACTION_COMMAND_TOKEN_SOURCE:-env}"
RESOLVED_LOCAL_API_TOKEN_SOURCE="${LOCAL_API_TOKEN:+env}"
COMMAND_FILE="${2:-${MANAGED_ACTION_COMMAND_FILE:-}}"
STDIN_COMMAND_TMP=""

cleanup() {
  if [ -n "$STDIN_COMMAND_TMP" ]; then
    rm -f "$STDIN_COMMAND_TMP"
  fi
}

trap cleanup EXIT

fail() {
  printf '[失败] %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"
}

materialize_stdin_command_file() {
  if [ "$COMMAND_FILE" != "-" ]; then
    return
  fi
  STDIN_COMMAND_TMP="$(mktemp "${TMPDIR:-/tmp}/managed-action-command.XXXXXX")"
  cat > "$STDIN_COMMAND_TMP"
  COMMAND_FILE="$STDIN_COMMAND_TMP"
}

usage() {
  cat <<'TEXT'
用法：
  managed-action-command-runner.sh status
  managed-action-command-runner.sh plan <command.json|-> 
  managed-action-command-runner.sh dry-run <command.json|->
  managed-action-command-runner.sh live <command.json|->
  managed-action-command-runner.sh parse-text <command.txt|->
  managed-action-command-runner.sh plan-text <command.txt|->
  managed-action-command-runner.sh dry-run-text <command.txt|->

command.json 示例：
  {
    "instanceId": "tom",
    "action": "skill_run",
    "operator": "Anan",
    "reason": "通过 OpenClaw 指令预览 skill 调用",
    "skillName": "zhihu-human-ops-writing",
    "agentId": "main",
    "message": "请使用 zhihu-human-ops-writing skill 执行一次安全测试，不要发布。"
  }

live command.json 还必须带 dry-run 返回的 operationRequestId：
  {
    "instanceId": "tom",
    "action": "collector_refresh",
    "operator": "Anan",
    "reason": "通过 OpenClaw 指令刷新 collector 快照",
    "operationRequestId": "<dry-run operationRequestId>"
  }

文本指令示例：
  对 tom 运行 zhihu-human-ops-writing dry-run
  instance=tom action=skill_run skill=zhihu-human-ops-writing dry-run

dry-run 必须设置：
  CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CALLS_MANAGED_ACTION_DRY_RUN_API
  LOCAL_API_TOKEN=<本地令牌>
  # 如果令牌只在 control-center 容器环境中，可以显式使用：
  MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container

live 必须设置：
  CONFIRM_MANAGED_ACTION_COMMAND_LIVE=I_UNDERSTAND_THIS_CALLS_MANAGED_ACTION_LIVE_API
  LOCAL_API_TOKEN=<本地令牌>

skill_run live 还必须额外设置：
  CONFIRM_MANAGED_ACTION_COMMAND_SKILL_RUN_LIVE=I_UNDERSTAND_THIS_MAY_RUN_OPENCLAW_SKILL_ON_ALLOWED_INSTANCE

安全边界：
  - plan 不联网、不写文件。
  - parse-text/plan-text 不联网、不写文件。
  - dry-run 只调用 /api/managed-actions/dry-run，不执行 OpenClaw 实例命令。
  - live 默认只允许 healthcheck/collector_refresh；skill_run live 必须额外确认，并要求 control-center readiness 显示 skill_run 白名单、rollout 和 skill/instance allowlist 已匹配。
  - 不打开 live gate，不重启实例；是否修改 OpenClaw 实例由 live API 返回的 safety 决定。
TEXT
}

resolve_local_api_token_for_dry_run() {
  if [ -n "$LOCAL_API_TOKEN" ]; then
    RESOLVED_LOCAL_API_TOKEN_SOURCE="env"
    return
  fi
  if [ "$MANAGED_ACTION_COMMAND_TOKEN_SOURCE" != "container" ]; then
    RESOLVED_LOCAL_API_TOKEN_SOURCE="missing"
    return
  fi
  require_command docker
  LOCAL_API_TOKEN="$(
    cd "$DEPLOY_DIR" &&
      docker compose exec -T control-center sh -lc 'printf "%s" "$LOCAL_API_TOKEN"'
  )"
  if [ -n "$LOCAL_API_TOKEN" ]; then
    RESOLVED_LOCAL_API_TOKEN_SOURCE="container"
  else
    RESOLVED_LOCAL_API_TOKEN_SOURCE="missing"
  fi
}

run_node() {
  local mode="$1"
  MODE="$mode" \
    DEPLOY_DIR="$DEPLOY_DIR" \
    CONTROL_CENTER_BASE_URL="$CONTROL_CENTER_BASE_URL" \
    CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN="$CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN" \
    CONFIRM_MANAGED_ACTION_COMMAND_LIVE="$CONFIRM_MANAGED_ACTION_COMMAND_LIVE" \
    CONFIRM_MANAGED_ACTION_COMMAND_SKILL_RUN_LIVE="$CONFIRM_MANAGED_ACTION_COMMAND_SKILL_RUN_LIVE" \
    LOCAL_API_TOKEN="$LOCAL_API_TOKEN" \
    RESOLVED_LOCAL_API_TOKEN_SOURCE="$RESOLVED_LOCAL_API_TOKEN_SOURCE" \
    COMMAND_FILE="$COMMAND_FILE" \
    node <<'NODE'
const fs = require("node:fs");

const mode = process.env.MODE || "status";
const commandFile = process.env.COMMAND_FILE || "";
const baseUrl = normalizeBaseUrl(process.env.CONTROL_CENTER_BASE_URL || "http://127.0.0.1:4311");
const confirmDryRun = process.env.CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN || "";
const confirmLive = process.env.CONFIRM_MANAGED_ACTION_COMMAND_LIVE || "";
const confirmSkillRunLive = process.env.CONFIRM_MANAGED_ACTION_COMMAND_SKILL_RUN_LIVE || "";
const localApiToken = process.env.LOCAL_API_TOKEN || "";
const localApiTokenSource = process.env.RESOLVED_LOCAL_API_TOKEN_SOURCE || "missing";
const dryRunConfirmation = "DRY-RUN-ONLY";
const liveConfirmation = "LIVE-ACTION-APPROVED";
const skillRunLiveConfirmation = "I_UNDERSTAND_THIS_MAY_RUN_OPENCLAW_SKILL_ON_ALLOWED_INSTANCE";
const allowedActions = new Set(["healthcheck", "collector_refresh", "skill_run"]);
const liveAllowedActions = new Set(["healthcheck", "collector_refresh", "skill_run"]);
const thinkingLevels = new Set(["off", "minimal", "low", "medium", "high", "xhigh"]);

function normalizeBaseUrl(value) {
  const parsed = new URL(value);
  parsed.pathname = parsed.pathname.replace(/\/+$/, "");
  parsed.search = "";
  parsed.hash = "";
  return parsed.toString().replace(/\/$/, "");
}

function compactLines(text, limit = 80) {
  return String(text || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, limit);
}

function readCommand() {
  if (!commandFile) throw new Error("缺少 command.json 路径；plan/dry-run 必须提供命令文件。");
  const raw = commandFile === "-" ? fs.readFileSync(0, "utf8") : fs.readFileSync(commandFile, "utf8");
  const parsed = JSON.parse(raw);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("command.json 必须是 JSON object。");
  }
  return parsed;
}

function readCommandText() {
  if (!commandFile) throw new Error("缺少 command.txt 路径；parse-text/plan-text/dry-run-text 必须提供文本文件。");
  const raw = commandFile === "-" ? fs.readFileSync(0, "utf8") : fs.readFileSync(commandFile, "utf8");
  const text = String(raw || "").trim();
  if (!text) throw new Error("command.txt 不能为空。");
  if (text.length > 500) throw new Error("command.txt 不能超过 500 个字符。");
  return text;
}

function parseTextCommand(text) {
  const normalized = text
    .replace(/[，。；、]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  const lower = normalized.toLowerCase();
  if (!/\b(dry-run|dryrun|dry_run)\b|预览|演练|只预览|仅预览/.test(lower)) {
    throw new Error("文本指令必须明确包含 dry-run/预览/演练，避免误解为真实执行。");
  }
  if (/真实执行|正式执行|live\s*run|\blive\b|发布|重启|restart|approve|approval|打开\s*live|启用\s*live/.test(lower)) {
    throw new Error("文本指令包含真实执行/live/发布/重启/approval 等高风险词，已阻止。");
  }

  const instanceId = extractNamedValue(normalized, ["instance", "实例", "inst"])
    || extractAfterKeyword(normalized, ["对", "给", "for"])
    || extractKnownInstance(lower);
  if (!instanceId) throw new Error("无法从文本指令中识别 instanceId。请使用“对 tom ... dry-run”或 instance=tom。");

  const action = extractAction(lower);
  if (!action) throw new Error("无法从文本指令中识别 action。支持 healthcheck、collector_refresh、skill_run。");

  const skillName = action === "skill_run"
    ? extractNamedValue(normalized, ["skill", "skillName", "技能"])
      || extractSkillLikeToken(normalized, instanceId)
    : undefined;
  if (action === "skill_run" && !skillName) {
    throw new Error("action=skill_run 时无法识别 skillName。请使用 skill=zhihu-human-ops-writing 或“运行 zhihu-human-ops-writing dry-run”。");
  }

  const operator = extractNamedValue(normalized, ["operator", "操作者", "用户"]) || "Anan";
  const reason = extractNamedValue(normalized, ["reason", "原因"]) || `OpenClaw/Discord 文本指令 dry-run：${safeReason(normalized)}`;
  const agentId = action === "skill_run"
    ? extractNamedValue(normalized, ["agent", "agentId", "机器人"]) || "main"
    : undefined;
  const message = action === "skill_run"
    ? extractFreeformValue(normalized, ["message", "msg", "任务", "指令"])
      || `使用 ${skillName} 执行 OpenClaw/Discord 受控请求的最小化检查：确认 skill 可识别并返回状态；不要生成正式内容，不要生成图片，不要发布，不要操作浏览器。`
    : undefined;
  return buildPayload({
    instanceId,
    action,
    operator,
    reason,
    confirmedText: dryRunConfirmation,
    ...(skillName ? { skillName } : {}),
    ...(agentId ? { agentId } : {}),
    ...(message ? { message } : {}),
    ...(action === "skill_run" ? { timeoutSeconds: 90, deliver: false } : {}),
  });
}

function extractNamedValue(text, names) {
  for (const name of names) {
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const match = text.match(new RegExp(`${escaped}\\s*[:=：]\\s*([A-Za-z0-9_-]+)`, "i"));
    if (match?.[1]) return match[1].trim();
  }
  return undefined;
}

function extractFreeformValue(text, names) {
  for (const name of names) {
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const match = text.match(new RegExp(`${escaped}\\s*[:=：]\\s*(.+)$`, "i"));
    if (match?.[1]) return match[1].trim().slice(0, 360);
  }
  return undefined;
}

function extractAfterKeyword(text, keywords) {
  for (const keyword of keywords) {
    const escaped = keyword.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const match = text.match(new RegExp(`${escaped}\\s*([A-Za-z0-9_-]+)`, "i"));
    if (match?.[1]) return match[1].trim();
  }
  return undefined;
}

function extractKnownInstance(lower) {
  const known = ["main", "tom", "third", "deepseek", "spark"];
  return known.find((item) => new RegExp(`(^|\\s)${item}(\\s|$)`, "i").test(lower));
}

function extractAction(lower) {
  if (/\bhealthcheck\b|健康检查/.test(lower)) return "healthcheck";
  if (/\bcollector_refresh\b|\bcollector-refresh\b|collector\s+refresh|刷新\s*collector|刷新.*快照|collector.*快照/.test(lower)) return "collector_refresh";
  if (/\bskill_run\b|\bskill-run\b|skill\s+run|\bskill\b|技能|运行\s+[A-Za-z0-9_-]+/.test(lower)) return "skill_run";
  return undefined;
}

function extractSkillLikeToken(text, instanceId) {
  const ignored = new Set([
    "dry-run",
    "dryrun",
    "dry_run",
    "skill",
    "skill_run",
    "skill-run",
    "run",
    "openclaw",
    "discord",
    "healthcheck",
    "collector",
    "collector_refresh",
    "preview",
    "plan",
    instanceId.toLowerCase(),
  ]);
  const tokens = text.match(/[A-Za-z][A-Za-z0-9_-]{2,}/g) || [];
  return tokens.find((token) => !ignored.has(token.toLowerCase()) && token.includes("-"));
}

function safeReason(text) {
  return text.replace(/\s+/g, " ").slice(0, 180);
}

function readRequiredString(obj, key, limit) {
  const value = typeof obj[key] === "string" ? obj[key].trim() : "";
  if (!value) throw new Error(`${key} 不能为空。`);
  if (value.length > limit) throw new Error(`${key} 不能超过 ${limit} 个字符。`);
  return value;
}

function readOptionalString(obj, key, limit) {
  const value = typeof obj[key] === "string" ? obj[key].trim() : "";
  if (!value) return undefined;
  if (value.length > limit) throw new Error(`${key} 不能超过 ${limit} 个字符。`);
  return value;
}

function readOptionalInteger(obj, key, min, max) {
  if (obj[key] === undefined || obj[key] === null || obj[key] === "") return undefined;
  if (!Number.isInteger(obj[key])) throw new Error(`${key} 必须是整数。`);
  if (obj[key] < min || obj[key] > max) throw new Error(`${key} 必须在 ${min}..${max} 之间。`);
  return obj[key];
}

function readOptionalBoolean(obj, key) {
  if (obj[key] === undefined || obj[key] === null || obj[key] === "") return undefined;
  if (typeof obj[key] !== "boolean") throw new Error(`${key} 必须是 boolean。`);
  return obj[key];
}

function readOptionalThinking(obj, key) {
  const value = readOptionalString(obj, key, 16);
  if (!value) return undefined;
  if (!thinkingLevels.has(value)) throw new Error(`${key} must be one of: off, minimal, low, medium, high, xhigh.`);
  return value;
}

function buildPayload(command) {
  const instanceId = readRequiredString(command, "instanceId", 120);
  const action = readRequiredString(command, "action", 80);
  if (!allowedActions.has(action)) throw new Error("action must be one of: healthcheck, collector_refresh, skill_run.");
  const operator = readRequiredString(command, "operator", 120);
  const reason = readRequiredString(command, "reason", 240);
  const skillName = readOptionalString(command, "skillName", 120);
  const agentId = readOptionalString(command, "agentId", 160);
  const sessionKey = readOptionalString(command, "sessionKey", 220);
  const sessionId = readOptionalString(command, "sessionId", 160);
  const message = readOptionalString(command, "message", 4000);
  const thinking = readOptionalThinking(command, "thinking");
  const timeoutSeconds = readOptionalInteger(command, "timeoutSeconds", 1, 7200);
  const deliver = readOptionalBoolean(command, "deliver");
  if (action === "skill_run" && !skillName) throw new Error("action=skill_run 时必须提供 skillName。");
  const confirmedText = readOptionalString(command, "confirmedText", 80) || dryRunConfirmation;
  if (confirmedText !== dryRunConfirmation) throw new Error(`confirmedText must equal ${dryRunConfirmation}.`);
  return {
    instanceId,
    action,
    operator,
    reason,
    confirmedText,
    ...(skillName ? { skillName } : {}),
    ...(agentId ? { agentId } : {}),
    ...(sessionKey ? { sessionKey } : {}),
    ...(sessionId ? { sessionId } : {}),
    ...(message ? { message } : {}),
    ...(thinking ? { thinking } : {}),
    ...(timeoutSeconds ? { timeoutSeconds } : {}),
    ...(deliver !== undefined ? { deliver } : {}),
  };
}

function buildLivePayload(command) {
  const payload = buildPayload({ ...command, confirmedText: dryRunConfirmation });
  const operationRequestId = readRequiredString(command, "operationRequestId", 120);
  if (!liveAllowedActions.has(payload.action)) {
    throw new Error("live 只允许 healthcheck、collector_refresh 或受控 skill_run。");
  }
  if (payload.action === "skill_run") {
    if (confirmSkillRunLive !== skillRunLiveConfirmation) {
      throw new Error(`skill_run live 必须额外设置 CONFIRM_MANAGED_ACTION_COMMAND_SKILL_RUN_LIVE=${skillRunLiveConfirmation}。`);
    }
    if (!payload.message || !(payload.agentId || payload.sessionKey || payload.sessionId)) {
      throw new Error("skill_run live 必须提供 message，并指定 agentId/sessionKey/sessionId 之一。");
    }
  }
  return {
    ...payload,
    operationRequestId,
    confirmedText: liveConfirmation,
  };
}

function safePayloadForOutput(payload) {
  return { ...payload };
}

async function requestJson(path, options = {}) {
  const response = await fetch(`${baseUrl}${path}`, {
    method: options.method || "GET",
    headers: {
      ...(options.body ? { "content-type": "application/json" } : {}),
      ...(options.token ? { "x-local-token": options.token } : {}),
    },
    body: options.body ? JSON.stringify(options.body) : undefined,
  });
  const text = await response.text();
  let body;
  try {
    body = text ? JSON.parse(text) : {};
  } catch (error) {
    body = { status: "invalid_json", rawLines: compactLines(text, 40), error: String(error?.message || error) };
  }
  return { statusCode: response.status, ok: response.ok, body };
}

function baseSafety(extra = {}) {
  return {
    callsManagedActionsDryRunApi: false,
    callsManagedActionsLiveApi: false,
    writesOpenClawInstanceDirs: false,
    restartsOpenClawInstances: false,
    mutatesOpenClawInstance: false,
    opensLiveGate: false,
    ...extra,
  };
}

function nextDryRunCommand(inputKind = "json") {
  const modeName = inputKind === "text" ? "dry-run-text" : "dry-run";
  const label = inputKind === "text" ? "<command.txt>" : "<command.json>";
  return `CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CALLS_MANAGED_ACTION_DRY_RUN_API LOCAL_API_TOKEN=<本地令牌> repo/ops/tom-readonly/managed-action-command-runner.sh ${modeName} ${label}`;
}

function nextLiveCommand() {
  return "CONFIRM_MANAGED_ACTION_COMMAND_LIVE=I_UNDERSTAND_THIS_CALLS_MANAGED_ACTION_LIVE_API LOCAL_API_TOKEN=<本地令牌> repo/ops/tom-readonly/managed-action-command-runner.sh live <command.json>";
}

function nextSkillRunLiveCommand() {
  return "CONFIRM_MANAGED_ACTION_COMMAND_LIVE=I_UNDERSTAND_THIS_CALLS_MANAGED_ACTION_LIVE_API CONFIRM_MANAGED_ACTION_COMMAND_SKILL_RUN_LIVE=I_UNDERSTAND_THIS_MAY_RUN_OPENCLAW_SKILL_ON_ALLOWED_INSTANCE LOCAL_API_TOKEN=<本地令牌> repo/ops/tom-readonly/managed-action-command-runner.sh live <command.json>";
}

function plannedReport(payload, inputKind = "json") {
  return {
    schemaVersion: 1,
    status: "planned",
    mode,
    generatedAt: new Date().toISOString(),
    baseUrl,
    target: {
      instanceId: payload.instanceId,
      action: payload.action,
      operator: payload.operator,
      ...(payload.skillName ? { skillName: payload.skillName } : {}),
      ...(payload.agentId ? { agentId: payload.agentId } : {}),
      ...(payload.sessionKey ? { sessionKey: payload.sessionKey } : {}),
      ...(payload.sessionId ? { sessionId: payload.sessionId } : {}),
    },
    payload: safePayloadForOutput(payload),
    nextCommands: [nextDryRunCommand(inputKind)],
    safety: baseSafety({
      readsCommandFileOnly: true,
      requiresDryRunConfirmation: true,
      requiresLocalApiToken: true,
    }),
  };
}

function parsedTextReport(payload, text) {
  return {
    schemaVersion: 1,
    status: "parsed",
    mode,
    generatedAt: new Date().toISOString(),
    inputText: text,
    command: safePayloadForOutput(payload),
    nextCommands: [
      "repo/ops/tom-readonly/managed-action-command-runner.sh plan-text <command.txt>",
      nextDryRunCommand("text"),
    ],
    safety: baseSafety({
      readsCommandTextOnly: true,
      callsManagedActionsDryRunApi: false,
      requiresDryRunConfirmation: true,
      requiresLocalApiToken: true,
    }),
  };
}

async function statusReport() {
  const actions = await requestJson("/api/managed-actions");
  const readiness = await requestJson("/api/managed-actions/readiness");
  const ok = actions.ok && readiness.ok;
  return {
    schemaVersion: 1,
    status: ok ? "status_ready" : "blocked_status_api",
    mode,
    generatedAt: new Date().toISOString(),
    baseUrl,
    stages: {
      actions: { statusCode: actions.statusCode, body: actions.body },
      readiness: { statusCode: readiness.statusCode, body: readiness.body },
    },
    nextCommands: ["repo/ops/tom-readonly/managed-action-command-runner.sh plan <command.json>"],
    safety: baseSafety({
      readsStatusOnly: true,
    }),
  };
}

async function dryRunReport(payload, inputKind = "json") {
  if (confirmDryRun !== "I_UNDERSTAND_THIS_ONLY_CALLS_MANAGED_ACTION_DRY_RUN_API") {
    return {
      schemaVersion: 1,
      status: "blocked_confirmation_required",
      mode,
      generatedAt: new Date().toISOString(),
      issues: ["必须设置 CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CALLS_MANAGED_ACTION_DRY_RUN_API。"],
      nextCommands: [nextDryRunCommand(inputKind)],
      safety: baseSafety({
        blockedBeforeApi: true,
        requiresDryRunConfirmation: true,
      }),
    };
  }
  if (!localApiToken.trim()) {
    return {
      schemaVersion: 1,
      status: "blocked_local_token_required",
      mode,
      generatedAt: new Date().toISOString(),
      issues: ["必须通过 LOCAL_API_TOKEN 提供本地令牌。"],
      nextCommands: [nextDryRunCommand(inputKind)],
      safety: baseSafety({
        blockedBeforeApi: true,
        requiresLocalApiToken: true,
        localApiTokenSource,
      }),
    };
  }

  const result = await requestJson("/api/managed-actions/dry-run", {
    method: "POST",
    token: localApiToken,
    body: payload,
  });
  const ok = result.ok && result.body?.ok === true && result.body?.dryRun === true;
  return {
    schemaVersion: 1,
    status: ok ? "dry_run_completed" : "blocked_dry_run_api",
    mode,
    generatedAt: new Date().toISOString(),
    target: {
      instanceId: payload.instanceId,
      action: payload.action,
      operator: payload.operator,
      ...(payload.skillName ? { skillName: payload.skillName } : {}),
      ...(payload.agentId ? { agentId: payload.agentId } : {}),
      ...(payload.sessionKey ? { sessionKey: payload.sessionKey } : {}),
      ...(payload.sessionId ? { sessionId: payload.sessionId } : {}),
    },
    payload: safePayloadForOutput(payload),
    dryRunApi: {
      statusCode: result.statusCode,
      body: result.body,
    },
    nextCommands: ok
      ? [
        "repo/ops/tom-readonly/managed-action-command-runner.sh status",
        nextLiveCommand(),
        "repo/ops/tom-readonly/live-healthcheck-readiness.sh status",
      ]
      : [nextDryRunCommand(inputKind)],
    safety: baseSafety({
      callsManagedActionsDryRunApi: true,
      createsDryRunAuditOnly: ok,
      requiresDryRunConfirmation: true,
      requiresLocalApiToken: true,
      localApiTokenSource,
    }),
  };
}

async function liveReport(payload) {
  if (confirmLive !== "I_UNDERSTAND_THIS_CALLS_MANAGED_ACTION_LIVE_API") {
    return {
      schemaVersion: 1,
      status: "blocked_confirmation_required",
      mode,
      generatedAt: new Date().toISOString(),
      issues: ["必须设置 CONFIRM_MANAGED_ACTION_COMMAND_LIVE=I_UNDERSTAND_THIS_CALLS_MANAGED_ACTION_LIVE_API。"],
      nextCommands: [nextLiveCommand()],
      safety: baseSafety({
        blockedBeforeApi: true,
        requiresLiveConfirmation: true,
      }),
    };
  }
  if (!localApiToken.trim()) {
    return {
      schemaVersion: 1,
      status: "blocked_local_token_required",
      mode,
      generatedAt: new Date().toISOString(),
      issues: ["必须通过 LOCAL_API_TOKEN 提供本地令牌。"],
      nextCommands: [nextLiveCommand()],
      safety: baseSafety({
        blockedBeforeApi: true,
        requiresLocalApiToken: true,
        localApiTokenSource,
      }),
    };
  }

  let skillRunReadiness;
  if (payload.action === "skill_run") {
    skillRunReadiness = await checkSkillRunReadiness(payload);
    if (!skillRunReadiness.allowed) {
      return {
        schemaVersion: 1,
        status: "blocked_skill_run_readiness",
        mode,
        generatedAt: new Date().toISOString(),
        target: {
          instanceId: payload.instanceId,
          action: payload.action,
          operator: payload.operator,
          operationRequestId: payload.operationRequestId,
          skillName: payload.skillName,
          ...(payload.agentId ? { agentId: payload.agentId } : {}),
          ...(payload.sessionKey ? { sessionKey: payload.sessionKey } : {}),
          ...(payload.sessionId ? { sessionId: payload.sessionId } : {}),
        },
        issues: skillRunReadiness.issues,
        readinessApi: skillRunReadiness.readinessApi,
        nextCommands: [
          "repo/ops/tom-readonly/managed-action-command-runner.sh status",
          nextSkillRunLiveCommand(),
        ],
        safety: baseSafety({
          blockedBeforeLiveApi: true,
          checkedSkillRunReadiness: true,
          callsManagedActionsLiveApi: false,
          requiresLiveConfirmation: true,
          requiresSkillRunLiveConfirmation: true,
          requiresLocalApiToken: true,
          localApiTokenSource,
        }),
      };
    }
  }

  const result = await requestJson("/api/managed-actions/live", {
    method: "POST",
    token: localApiToken,
    body: payload,
  });
  const ok = result.ok && result.body?.ok === true && result.body?.liveExecution === true;
  return {
    schemaVersion: 1,
    status: ok ? "live_completed" : "blocked_live_api",
    mode,
    generatedAt: new Date().toISOString(),
    target: {
      instanceId: payload.instanceId,
      action: payload.action,
      operator: payload.operator,
      operationRequestId: payload.operationRequestId,
      ...(payload.skillName ? { skillName: payload.skillName } : {}),
      ...(payload.agentId ? { agentId: payload.agentId } : {}),
      ...(payload.sessionKey ? { sessionKey: payload.sessionKey } : {}),
      ...(payload.sessionId ? { sessionId: payload.sessionId } : {}),
    },
    liveApi: {
      statusCode: result.statusCode,
      body: result.body,
    },
    ...(skillRunReadiness ? { skillRunReadiness } : {}),
    nextCommands: ok
      ? [
        "repo/ops/tom-readonly/managed-action-command-runner.sh status",
        "repo/ops/tom-readonly/healthcheck.sh",
      ]
      : [nextLiveCommand()],
    safety: baseSafety({
      callsManagedActionsLiveApi: true,
      requiresLiveConfirmation: true,
      requiresSkillRunLiveConfirmation: payload.action === "skill_run",
      requiresLocalApiToken: true,
      localApiTokenSource,
      mutatesOpenClawInstance: result.body?.safety?.mutatesOpenClawInstance === true,
    }),
  };
}

async function checkSkillRunReadiness(payload) {
  const readiness = await requestJson("/api/managed-actions/readiness");
  const issues = [];
  const body = readiness.body || {};
  const gateActions = Array.isArray(body.gate?.allowedActions) ? body.gate.allowedActions : [];
  const rolloutActions = Array.isArray(body.rollout?.actions) ? body.rollout.actions : [];
  const allowedSkills = Array.isArray(body.skillRunPolicy?.allowedSkills) ? body.skillRunPolicy.allowedSkills : [];
  const allowedInstances = Array.isArray(body.skillRunPolicy?.allowedInstances) ? body.skillRunPolicy.allowedInstances : [];
  if (!readiness.ok || body.ok !== true) issues.push("无法读取 managed-actions readiness。");
  if (body.liveExecutionAvailable !== true) issues.push("managed-actions readiness 尚未 ready。");
  if (!gateActions.includes("skill_run")) issues.push("live gate 未允许 skill_run。");
  if (!rolloutActions.includes("skill_run")) issues.push("rollout 未允许 skill_run。");
  if (body.skillRunPolicy?.required !== true) issues.push("skill_run policy 未处于 required 状态。");
  if (!allowedSkills.includes(payload.skillName)) issues.push(`skill_run skillName 未在 allowlist 中：${payload.skillName}`);
  if (!allowedInstances.includes(payload.instanceId)) issues.push(`skill_run instance 未在 allowlist 中：${payload.instanceId}`);
  if (body.skillRunPolicy?.deliverAllowed !== true && payload.deliver === true) issues.push("skill_run policy 不允许 deliver=true。");
  if (
    typeof payload.timeoutSeconds === "number"
    && typeof body.skillRunPolicy?.maxTimeoutSeconds === "number"
    && payload.timeoutSeconds > body.skillRunPolicy.maxTimeoutSeconds
  ) {
    issues.push(`skill_run timeoutSeconds 超过 policy 上限：${payload.timeoutSeconds} > ${body.skillRunPolicy.maxTimeoutSeconds}`);
  }
  return {
    allowed: issues.length === 0,
    issues,
    readinessApi: {
      statusCode: readiness.statusCode,
      body,
    },
  };
}

async function main() {
  if (mode === "status") return statusReport();
  if (mode === "parse-text") {
    const text = readCommandText();
    return parsedTextReport(parseTextCommand(text), text);
  }
  if (mode === "plan-text" || mode === "dry-run-text") {
    const payload = parseTextCommand(readCommandText());
    if (mode === "plan-text") return plannedReport(payload, "text");
    return dryRunReport(payload, "text");
  }
  if (mode !== "plan" && mode !== "dry-run" && mode !== "live") throw new Error(`未知模式：${mode}`);
  const command = readCommand();
  if (mode === "live") return liveReport(buildLivePayload(command));
  const payload = buildPayload(command);
  if (mode === "plan") return plannedReport(payload, "json");
  return dryRunReport(payload, "json");
}

main()
  .then((report) => {
    console.log(JSON.stringify(report, null, 2));
    process.exit(String(report.status || "").startsWith("blocked_") ? 2 : 0);
  })
  .catch((error) => {
    console.log(JSON.stringify({
      schemaVersion: 1,
      status: "blocked_invalid_command",
      mode,
      generatedAt: new Date().toISOString(),
      issues: [error instanceof Error ? error.message : String(error)],
      nextCommands: mode === "status" ? [] : ["repo/ops/tom-readonly/managed-action-command-runner.sh plan <command.json>"],
      safety: baseSafety({
        blockedBeforeApi: true,
      }),
    }, null, 2));
    process.exit(2);
  });
NODE
}

main() {
  require_command node
  case "${1:-status}" in
    status)
      run_node "status"
      ;;
    plan)
      [ -n "$COMMAND_FILE" ] || fail "plan 必须提供 command.json 路径"
      materialize_stdin_command_file
      run_node "plan"
      ;;
    parse-text)
      [ -n "$COMMAND_FILE" ] || fail "parse-text 必须提供 command.txt 路径"
      materialize_stdin_command_file
      run_node "parse-text"
      ;;
    plan-text)
      [ -n "$COMMAND_FILE" ] || fail "plan-text 必须提供 command.txt 路径"
      materialize_stdin_command_file
      run_node "plan-text"
      ;;
    dry-run)
      [ -n "$COMMAND_FILE" ] || fail "dry-run 必须提供 command.json 路径"
      materialize_stdin_command_file
      resolve_local_api_token_for_dry_run
      run_node "dry-run"
      ;;
    live)
      [ -n "$COMMAND_FILE" ] || fail "live 必须提供 command.json 路径"
      materialize_stdin_command_file
      resolve_local_api_token_for_dry_run
      run_node "live"
      ;;
    dry-run-text)
      [ -n "$COMMAND_FILE" ] || fail "dry-run-text 必须提供 command.txt 路径"
      materialize_stdin_command_file
      resolve_local_api_token_for_dry_run
      run_node "dry-run-text"
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
