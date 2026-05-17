#!/usr/bin/env bash
set -euo pipefail
set +x

# 最终上线总闸门。
# 汇总 Tom 本体只读健康、跨服务器只读 collector 接入、管理动作 dry-run 证据和 live readiness。
# 本脚本不写远端文件、不修改任何 OpenClaw 实例目录、不重启实例、不调用 managed-actions live API。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
BUNDLE_DIR="${BUNDLE_DIR:-${DEPLOY_DIR}/runtime/remote-onboarding/remote-oracle}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  printf '[失败] %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"
}

usage() {
  cat <<'TEXT'
用法：
  go-live-gate.sh status <bundle-dir>
  go-live-gate.sh check <bundle-dir>

说明：
  status：只读取跨服务器 rollout 状态和 live readiness 状态，不执行 healthcheck。
  check：额外执行 Tom 控制中心 healthcheck，验证现有实例仍在只读安全边界内。

安全边界：
  - 不写远端文件。
  - 不修改任何 OpenClaw 实例目录。
  - 不重启 OpenClaw 实例。
  - 不调用 managed-actions live API。
  - 不绕过跨服务器 runner、approval、dry-run、审计日志或白名单闸门。
TEXT
}

run_node() {
  local mode="$1"
  local bundle="${2:-$BUNDLE_DIR}"
  MODE="$mode" \
    DEPLOY_DIR="$DEPLOY_DIR" \
    BUNDLE_DIR="$bundle" \
    SCRIPT_DIR="$SCRIPT_DIR" \
    node <<'NODE'
const { spawnSync } = require("node:child_process");
const path = require("node:path");

const mode = process.env.MODE || "status";
const deployDir = path.resolve(process.env.DEPLOY_DIR || "/srv/openclaw-control-center-readonly");
const bundleDir = path.resolve(process.env.BUNDLE_DIR || path.join(deployDir, "runtime", "remote-onboarding", "remote-oracle"));
const scriptDir = process.env.SCRIPT_DIR || path.join(deployDir, "repo", "ops", "tom-readonly");
const remoteRolloutRunnerScript = process.env.GO_LIVE_REMOTE_ROLLOUT_RUNNER_SCRIPT || path.join(scriptDir, "remote-collector-rollout-runner.sh");
const managedActionDryRunGateScript = process.env.GO_LIVE_MANAGED_ACTION_DRY_RUN_GATE_SCRIPT || path.join(scriptDir, "managed-action-dry-run-gate.sh");
const liveHealthcheckWindowScript = process.env.GO_LIVE_HEALTHCHECK_WINDOW_SCRIPT || path.join(scriptDir, "live-healthcheck-window.sh");
const healthcheckScript = process.env.GO_LIVE_HEALTHCHECK_SCRIPT || path.join(deployDir, "healthcheck.sh");

function runScript(command, args, extraEnv = {}) {
  const result = spawnSync(command, args, {
    env: { ...process.env, DEPLOY_DIR: deployDir, ...extraEnv },
    encoding: "utf8",
    maxBuffer: 20 * 1024 * 1024,
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
      raw: text.slice(0, 4000),
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
        const candidate = text.slice(start, index + 1);
        try {
          objects.push(JSON.parse(candidate));
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
  return text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, limit);
}

function deriveLiveStatus(result) {
  const combined = `${result.stdout}\n${result.stderr}`;
  const objects = extractJsonObjects(combined);
  const approval = objects.find((item) => item && typeof item === "object" && "approved" in item && "consumed" in item);
  const rollout = objects.find((item) => item && typeof item === "object" && item.action === "healthcheck" && item.risk === "low");
  const readonlyMode = firstMatch(combined, /READONLY_MODE=([^\s]+)/);
  const liveEnabled = firstMatch(combined, /MANAGED_ACTIONS_LIVE_ENABLED=([^\s]+)/);
  const executorEnabled = firstMatch(combined, /MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED=([^\s]+)/);
  const readinessStatus = firstMatch(combined, /readiness\.status=([^\s]+)/);
  const liveExecutionAvailable = firstMatch(combined, /readiness\.liveExecutionAvailable=([^\s]+)/);
  const productionWired = firstMatch(combined, /readiness\.executor\.productionWired=([^\s]+)/);
  const issues = [];

  if (result.exitCode !== 0) issues.push(`live status 脚本失败：exit=${result.exitCode}`);
  if (approval && approval.status !== "approved_ready") {
    const approvalIssues = Array.isArray(approval.issues) ? approval.issues : [];
    issues.push(`approval=${approval.status || "unknown"}`);
    issues.push(...approvalIssues.map((item) => `approval: ${item}`));
  }
  if (readinessStatus && readinessStatus !== "ready") issues.push(`readiness=${readinessStatus}`);
  if (liveExecutionAvailable && liveExecutionAvailable !== "true") issues.push("liveExecutionAvailable=false");
  if (readonlyMode === "true") issues.push("READONLY_MODE=true，管理动作 live 窗口未打开");

  return {
    status: issues.length > 0 ? "blocked" : "ready",
    approvalStatus: approval?.status || "unknown",
    approved: approval?.approved === true,
    consumed: approval?.consumed === true,
    readinessStatus: readinessStatus || "unknown",
    liveExecutionAvailable: liveExecutionAvailable || "unknown",
    productionWired: productionWired || "unknown",
    readonlyMode: readonlyMode || "unknown",
    liveEnabled: liveEnabled || "unknown",
    executorEnabled: executorEnabled || "unknown",
    rollout,
    issues,
    rawLines: compactLines(combined, 60),
  };
}

function firstMatch(text, pattern) {
  const match = text.match(pattern);
  return match ? match[1] : undefined;
}

function summarizeRemote(remote) {
  const stage = remote.stage || "unknown";
  const readyForHealthcheck = remote.status === "ready" && stage === "ready_for_healthcheck";
  return {
    status: readyForHealthcheck ? "ready_for_healthcheck" : "blocked",
    stage,
    serverId: remote.serverId,
    serverName: remote.serverName,
    remoteAccess: remote.evidence?.remoteAccess,
    preflight: remote.evidence?.preflight,
    pull: remote.evidence?.pull,
    snapshot: remote.evidence?.snapshot,
    registry: remote.evidence?.registry,
    nextCommands: Array.isArray(remote.nextCommands) ? remote.nextCommands : [],
  };
}

function summarizeDryRunEvidence(result) {
  if (result.exitCode !== 0) {
    return {
      status: "blocked",
      issues: [`dry-run 证据闸门脚本失败：exit=${result.exitCode}`],
      nextCommands: [
        "repo/ops/tom-readonly/managed-action-dry-run-gate.sh status",
        "CONFIRM_MANAGED_ACTION_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CREATES_DRY_RUN_AUDIT_RECORD LOCAL_API_TOKEN=<本地令牌> repo/ops/tom-readonly/managed-action-dry-run-gate.sh run",
      ],
      rawLines: compactLines(`${result.stdout}\n${result.stderr}`, 60),
    };
  }

  const parsed = parseJson(result.stdout, "managed action dry-run gate");
  if (parsed.status === "invalid_output") {
    return {
      status: "blocked",
      issues: [`dry-run 证据闸门输出不是有效 JSON：${parsed.error}`],
      nextCommands: [
        "repo/ops/tom-readonly/managed-action-dry-run-gate.sh status",
      ],
      rawStatus: parsed,
    };
  }

  const issues = Array.isArray(parsed.issues) ? parsed.issues : [];
  return {
    status: parsed.status === "ready" ? "ready" : "blocked",
    target: parsed.target,
    audit: parsed.audit,
    readiness: parsed.readiness,
    issues,
    nextCommands: Array.isArray(parsed.nextCommands) ? parsed.nextCommands : [],
    rawStatus: parsed,
  };
}

function buildNextCommands(decision, remoteSummary, dryRunSummary) {
  const runnerCommand = `CONFIRM_REMOTE_COLLECTOR_ROLLOUT_RUNNER=I_UNDERSTAND_THIS_RUNS_SAFE_REMOTE_COLLECTOR_ROLLOUT_STEPS repo/ops/tom-readonly/remote-collector-rollout-runner.sh run ${relativeRuntimePath(bundleDir)}`;
  if (decision === "blocked_existing_instances") {
    return ["./healthcheck.sh"];
  }
  if (decision === "blocked_cross_server_readonly") {
    if (remoteSummary.stage === "needs_remote_credentials") {
      return [
        ...remoteSummary.nextCommands,
        runnerCommand,
      ].filter(Boolean);
    }
    if (remoteSummary.stage === "needs_remote_collector_pull") {
      return [
        ...remoteSummary.nextCommands,
        runnerCommand,
      ].filter(Boolean);
    }
    return [runnerCommand];
  }
  if (decision === "ready_for_existing_instance_healthcheck") {
    return [`repo/ops/tom-readonly/go-live-gate.sh check ${relativeRuntimePath(bundleDir)}`];
  }
  if (decision === "blocked_managed_action_dry_run") {
    return dryRunSummary.nextCommands.length > 0 ? dryRunSummary.nextCommands : [
      "repo/ops/tom-readonly/managed-action-dry-run-gate.sh status",
      "CONFIRM_MANAGED_ACTION_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CREATES_DRY_RUN_AUDIT_RECORD LOCAL_API_TOKEN=<本地令牌> repo/ops/tom-readonly/managed-action-dry-run-gate.sh run",
    ];
  }
  if (decision === "blocked_managed_actions") {
    return [
      "repo/ops/tom-readonly/managed-action-dry-run-gate.sh status",
      "repo/ops/tom-readonly/live-healthcheck-approval.sh prepare runtime/live-healthcheck-approval.json",
      "CONFIRM_APPROVAL_RECORD=I_APPROVE_LIVE_HEALTHCHECK_RECORD APPROVED_BY=Anan repo/ops/tom-readonly/live-healthcheck-approval.sh approve runtime/live-healthcheck-approval.json",
      "CONFIRM_LIVE_HEALTHCHECK_WINDOW=I_UNDERSTAND_THIS_TEMPORARILY_ENABLES_LIVE_GATE CONFIRM_LIVE_HEALTHCHECK=I_UNDERSTAND_THIS_CALLS_LIVE_API LOCAL_API_TOKEN=<本地令牌> INSTANCE_ID=tom OPERATOR=Anan repo/ops/tom-readonly/live-healthcheck-window.sh run",
    ];
  }
  return [];
}

function relativeRuntimePath(file) {
  const root = `${deployDir}${path.sep}`;
  const resolved = path.resolve(file);
  return resolved.startsWith(root) ? path.relative(deployDir, resolved) : resolved;
}

function decide(remoteSummary, healthcheck, dryRunSummary, live) {
  if (healthcheck.status === "failed") return "blocked_existing_instances";
  if (remoteSummary.status !== "ready_for_healthcheck") return "blocked_cross_server_readonly";
  if (healthcheck.status === "skipped") return "ready_for_existing_instance_healthcheck";
  if (dryRunSummary.status !== "ready") return "blocked_managed_action_dry_run";
  if (live.status !== "ready") return "blocked_managed_actions";
  return "ready_for_live_healthcheck";
}

function formatError(error) {
  return error instanceof Error ? error.message : String(error);
}

const remoteRun = runScript(remoteRolloutRunnerScript, ["status", bundleDir]);
const remote = remoteRun.exitCode === 0 ? parseJson(remoteRun.stdout, "remote rollout") : {
  status: "script_failed",
  stage: "unknown",
  error: remoteRun.error || remoteRun.stderr || remoteRun.stdout,
};
const remoteSummary = summarizeRemote(remote);

const dryRunGateRun = runScript(managedActionDryRunGateScript, ["status"]);
const dryRunSummary = summarizeDryRunEvidence(dryRunGateRun);

const liveRun = runScript(liveHealthcheckWindowScript, ["status"]);
const live = deriveLiveStatus(liveRun);

let healthcheck = { status: "skipped", command: healthcheckScript };
if (mode === "check") {
  const healthRun = runScript(healthcheckScript, []);
  healthcheck = {
    status: healthRun.exitCode === 0 ? "passed" : "failed",
    command: healthRun.command,
    exitCode: healthRun.exitCode,
    stdoutLines: compactLines(healthRun.stdout, 80),
    stderrLines: compactLines(healthRun.stderr, 80),
  };
}

const decision = decide(remoteSummary, healthcheck, dryRunSummary, live);

console.log(JSON.stringify({
  schemaVersion: 1,
  status: decision,
  mode,
  generatedAt: new Date().toISOString(),
  deployDir,
  bundleDir,
  stages: {
    existingInstances: healthcheck,
    crossServerReadonlyMonitoring: remoteSummary,
    managedActionDryRunEvidence: dryRunSummary,
    managedActions: live,
  },
  nextCommands: buildNextCommands(decision, remoteSummary, dryRunSummary),
  safety: {
    readsStatusOnly: mode === "status",
    checkRunsHealthcheckOnly: mode === "check",
    writesRemoteFiles: false,
    writesOpenClawInstanceDirs: false,
    restartsOpenClawInstances: false,
    callsManagedActionsLiveApi: false,
    bypassesApproval: false,
  },
  evidence: {
    remoteRolloutRunner: {
      command: remoteRun.command,
      exitCode: remoteRun.exitCode,
      stderrLines: compactLines(remoteRun.stderr, 40),
      rawStatus: remote,
    },
    liveHealthcheckWindow: {
      command: liveRun.command,
      exitCode: liveRun.exitCode,
    },
    managedActionDryRunGate: {
      command: dryRunGateRun.command,
      exitCode: dryRunGateRun.exitCode,
    },
  },
}, null, 2));
NODE
}

main() {
  require_command node
  case "${1:-status}" in
    status|plan)
      run_node "status" "${2:-$BUNDLE_DIR}"
      ;;
    check)
      run_node "check" "${2:-$BUNDLE_DIR}"
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
