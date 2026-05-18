#!/usr/bin/env bash
set -euo pipefail
set +x

# heartbeat/token 周期性消耗只读检查器。
# 只读取 control-center registry、collector history，以及只读挂载中的 HEARTBEAT.md 元数据。
# 本脚本不修改任何 OpenClaw 实例目录，不清空 HEARTBEAT.md，不调用模型，不重启实例。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
INSTANCES_FILE="${INSTANCES_FILE:-${DEPLOY_DIR}/config/instances.json}"
HISTORY_FILE="${HISTORY_FILE:-${DEPLOY_DIR}/runtime/collectors/tom-oracle/history.json}"
INSTANCE_ID="${INSTANCE_ID:-}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
MAX_SMALL_DELTA_TOKENS="${MAX_SMALL_DELTA_TOKENS:-2000}"
MIN_PERIODIC_EVENTS="${MIN_PERIODIC_EVENTS:-4}"
MIN_PERIODIC_INTERVAL_MINUTES="${MIN_PERIODIC_INTERVAL_MINUTES:-10}"
MAX_PERIODIC_INTERVAL_MINUTES="${MAX_PERIODIC_INTERVAL_MINUTES:-90}"
RHYTHM_SCORE_MIN="${RHYTHM_SCORE_MIN:-0.55}"
HEARTBEAT_INSPECT_SOURCE="${HEARTBEAT_INSPECT_SOURCE:-control-center-container}"
CONTROL_CENTER_CONTAINER="${CONTROL_CENTER_CONTAINER:-openclaw-control-center-readonly}"
DOCKER_BIN="${DOCKER_BIN:-docker}"

fail() {
  printf '[失败] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'TEXT'
用法：
  heartbeat-burn-inspector.sh status [instanceId]
  heartbeat-burn-inspector.sh check [instanceId]

说明：
  status：只读输出 heartbeat/token 周期性消耗线索；输入文件缺失时会阻断。
  check：发现 suspiciousRows 时退出码为 2，便于告警或 cron 接入。

常用环境变量：
  DEPLOY_DIR=/srv/openclaw-control-center-readonly
  INSTANCES_FILE=$DEPLOY_DIR/config/instances.json
  HISTORY_FILE=$DEPLOY_DIR/runtime/collectors/tom-oracle/history.json
  INSTANCE_ID=deepseek
  LOOKBACK_HOURS=24
  HEARTBEAT_INSPECT_SOURCE=control-center-container|none
  CONTROL_CENTER_CONTAINER=openclaw-control-center-readonly

安全边界：
  - 只读 registry、collector history、HEARTBEAT.md 元数据。
  - 不写 OpenClaw 实例目录。
  - 不清空 HEARTBEAT.md。
  - 不调用模型。
  - 不重启实例。
TEXT
}

main() {
  local mode="${1:-status}"
  local instance_arg="${2:-$INSTANCE_ID}"
  case "$mode" in
    status|check)
      [ -r "$INSTANCES_FILE" ] || fail "找不到 instances 文件：${INSTANCES_FILE}"
      [ -r "$HISTORY_FILE" ] || fail "找不到 collector history：${HISTORY_FILE}"
      MODE="$mode" \
        DEPLOY_DIR="$DEPLOY_DIR" \
        INSTANCES_FILE="$INSTANCES_FILE" \
        HISTORY_FILE="$HISTORY_FILE" \
        INSTANCE_ID="$instance_arg" \
        LOOKBACK_HOURS="$LOOKBACK_HOURS" \
        MAX_SMALL_DELTA_TOKENS="$MAX_SMALL_DELTA_TOKENS" \
        MIN_PERIODIC_EVENTS="$MIN_PERIODIC_EVENTS" \
        MIN_PERIODIC_INTERVAL_MINUTES="$MIN_PERIODIC_INTERVAL_MINUTES" \
        MAX_PERIODIC_INTERVAL_MINUTES="$MAX_PERIODIC_INTERVAL_MINUTES" \
        RHYTHM_SCORE_MIN="$RHYTHM_SCORE_MIN" \
        HEARTBEAT_INSPECT_SOURCE="$HEARTBEAT_INSPECT_SOURCE" \
        CONTROL_CENTER_CONTAINER="$CONTROL_CENTER_CONTAINER" \
        DOCKER_BIN="$DOCKER_BIN" \
        node <<'NODE'
const fs = require("node:fs");
const { spawnSync } = require("node:child_process");

const mode = process.env.MODE || "status";
const instancesFile = process.env.INSTANCES_FILE;
const historyFile = process.env.HISTORY_FILE;
const instanceFilter = String(process.env.INSTANCE_ID || "").trim();
const lookbackHours = readNumber(process.env.LOOKBACK_HOURS, 24);
const maxSmallDeltaTokens = readNumber(process.env.MAX_SMALL_DELTA_TOKENS, 2000);
const minPeriodicEvents = readNumber(process.env.MIN_PERIODIC_EVENTS, 4);
const minPeriodicIntervalMinutes = readNumber(process.env.MIN_PERIODIC_INTERVAL_MINUTES, 10);
const maxPeriodicIntervalMinutes = readNumber(process.env.MAX_PERIODIC_INTERVAL_MINUTES, 90);
const rhythmScoreMin = readNumber(process.env.RHYTHM_SCORE_MIN, 0.55);
const heartbeatInspectSource = String(process.env.HEARTBEAT_INSPECT_SOURCE || "control-center-container").trim();
const controlCenterContainer = String(process.env.CONTROL_CENTER_CONTAINER || "openclaw-control-center-readonly").trim();
const dockerBin = String(process.env.DOCKER_BIN || "docker").trim();

function readNumber(value, fallback) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function readJson(file, label) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    return {
      error: `${label} 无法读取或解析：${error instanceof Error ? error.message : String(error)}`,
    };
  }
}

function flattenInstances(config) {
  if (Array.isArray(config.instances)) return config.instances;
  if (Array.isArray(config.servers)) {
    return config.servers.flatMap((server) =>
      Array.isArray(server.instances)
        ? server.instances.map((instance) => ({
            ...instance,
            serverId: server.id,
            serverName: server.name,
            collectorSnapshotPath: server.collectorSnapshotPath,
          }))
        : [],
    );
  }
  return [];
}

function median(values) {
  const clean = values.filter((value) => Number.isFinite(value)).sort((a, b) => a - b);
  if (clean.length === 0) return 0;
  const mid = Math.floor(clean.length / 2);
  if (clean.length % 2 === 1) return clean[mid] || 0;
  return ((clean[mid - 1] || 0) + (clean[mid] || 0)) / 2;
}

function inspectHeartbeat(instance) {
  const workspaceRoot = String(instance.workspaceRoot || "").trim();
  if (!workspaceRoot) {
    return {
      status: "not_configured",
      detail: "registry 未配置 workspaceRoot。",
    };
  }
  const heartbeatPath = `${workspaceRoot.replace(/\/+$/, "")}/HEARTBEAT.md`;
  if (heartbeatInspectSource === "none") {
    return {
      status: "skipped",
      path: heartbeatPath,
      detail: "HEARTBEAT_INSPECT_SOURCE=none，已跳过文件元数据检查。",
    };
  }
  if (heartbeatInspectSource !== "control-center-container") {
    return {
      status: "unsupported_source",
      path: heartbeatPath,
      detail: `不支持的 HEARTBEAT_INSPECT_SOURCE：${heartbeatInspectSource}`,
    };
  }

  const script = `
const fs = require("node:fs");
const file = process.argv[1];
try {
  if (!fs.existsSync(file)) {
    console.log(JSON.stringify({ status: "missing", path: file, sizeBytes: 0, nonEmpty: false }));
    process.exit(0);
  }
  const stat = fs.statSync(file);
  const text = fs.readFileSync(file, "utf8");
  const firstContentLine = text.split(/\\r?\\n/).map((line) => line.trim()).find(Boolean) || "";
  console.log(JSON.stringify({
    status: "read",
    path: file,
    sizeBytes: stat.size,
    nonEmpty: stat.size > 0 && text.trim().length > 0,
    firstContentLine: firstContentLine.slice(0, 120),
    updatedAt: stat.mtime.toISOString(),
  }));
} catch (error) {
  console.log(JSON.stringify({
    status: "unreadable",
    path: file,
    detail: error instanceof Error ? error.message : String(error),
  }));
}
`;
  const result = spawnSync(dockerBin, ["exec", controlCenterContainer, "node", "-e", script, heartbeatPath], {
    encoding: "utf8",
    timeout: 15_000,
    maxBuffer: 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    return {
      status: "container_unavailable",
      path: heartbeatPath,
      detail: result.error ? String(result.error.message || result.error) : String(result.stderr || "docker exec failed").trim(),
    };
  }
  try {
    return JSON.parse(result.stdout);
  } catch (error) {
    return {
      status: "invalid_output",
      path: heartbeatPath,
      detail: error instanceof Error ? error.message : String(error),
    };
  }
}

function analyzeInstance(instance, history) {
  const samples = Array.isArray(history.samples) ? history.samples : [];
  const scopedSamples = samples
    .map((sample) => {
      const generatedAt = String(sample.generatedAt || "");
      const timestampMs = Date.parse(generatedAt);
      const item = Array.isArray(sample.instances) ? sample.instances.find((entry) => entry.id === instance.id) : undefined;
      if (!item || !Number.isFinite(timestampMs)) return undefined;
      return {
        generatedAt,
        timestampMs,
        totalTokens: Number(item.totalTokens || 0),
      };
    })
    .filter(Boolean)
    .sort((a, b) => a.timestampMs - b.timestampMs);
  if (scopedSamples.length < 3) {
    return {
      instanceId: instance.id,
      instanceName: instance.name || instance.id,
      status: "insufficient_history",
      samples: scopedSamples.length,
      heartbeat: inspectHeartbeat(instance),
      nextCommands: [],
    };
  }

  const latest = scopedSamples[scopedSamples.length - 1];
  const thresholdMs = latest.timestampMs - lookbackHours * 60 * 60 * 1000;
  const windowSamples = scopedSamples.filter((sample) => sample.timestampMs >= thresholdMs);
  const first = windowSamples[0] || scopedSamples[0];
  const growthEvents = [];
  for (let index = 1; index < windowSamples.length; index += 1) {
    const previous = windowSamples[index - 1];
    const current = windowSamples[index];
    const tokens = current.totalTokens - previous.totalTokens;
    if (tokens > 0) growthEvents.push({ tokens, timestampMs: current.timestampMs, generatedAt: current.generatedAt });
  }
  const growthIntervals = growthEvents
    .slice(1)
    .map((event, index) => {
      const previous = growthEvents[index];
      return previous ? (event.timestampMs - previous.timestampMs) / 60_000 : 0;
    })
    .filter((value) => Number.isFinite(value) && value > 0);
  const medianDelta = median(growthEvents.map((event) => event.tokens));
  const medianIntervalMinutes = median(growthIntervals);
  const rhythmScore = medianDelta > 0
    ? growthEvents.filter((event) => Math.abs(event.tokens - medianDelta) / medianDelta <= 0.45).length / growthEvents.length
    : 0;
  const recentDelta = growthEvents[growthEvents.length - 1]?.tokens || 0;
  const totalDelta = latest.totalTokens - first.totalTokens;
  const periodicSmallGrowth =
    growthEvents.length >= minPeriodicEvents &&
    growthIntervals.length >= Math.max(1, minPeriodicEvents - 1) &&
    medianDelta > 0 &&
    medianDelta <= maxSmallDeltaTokens &&
    medianIntervalMinutes >= minPeriodicIntervalMinutes &&
    medianIntervalMinutes <= maxPeriodicIntervalMinutes &&
    rhythmScore >= rhythmScoreMin;
  const recentSpike = recentDelta >= Math.max(5000, medianDelta * 5);
  const heartbeat = inspectHeartbeat(instance);
  const suspicious = periodicSmallGrowth || recentSpike;
  const nextCommands = suspicious
    ? [
        `查看页面：https://openclaw.ananclaw.com/?section=usage-cost&usage_instance=${encodeURIComponent(instance.id)}&lang=zh`,
        `只读复查：repo/ops/tom-readonly/heartbeat-burn-inspector.sh status ${instance.id}`,
        heartbeat.path ? `人工确认后再处理：检查 ${heartbeat.path} 是否需要清空或关闭` : "人工确认后再处理该实例 HEARTBEAT.md",
      ]
    : [];

  return {
    instanceId: instance.id,
    instanceName: instance.name || instance.id,
    status: suspicious ? (recentSpike ? "recent_spike" : "periodic_small_growth") : "ok",
    suspicious,
    samples: windowSamples.length,
    lookbackHours,
    totalDelta,
    recentDelta,
    nonZeroDeltas: growthEvents.length,
    medianDelta,
    medianIntervalMinutes,
    rhythmScore,
    latestAt: latest.generatedAt,
    heartbeat,
    nextCommands,
  };
}

const config = readJson(instancesFile, "instances");
const history = readJson(historyFile, "collector history");
const issues = [config.error, history.error].filter(Boolean);
const instances = issues.length > 0
  ? []
  : flattenInstances(config).filter((instance) => !instanceFilter || instance.id === instanceFilter);
if (!issues.length && instanceFilter && instances.length === 0) issues.push(`未找到实例：${instanceFilter}`);

const rows = issues.length > 0 ? [] : instances.map((instance) => analyzeInstance(instance, history));
const suspiciousRows = rows.filter((row) => row.suspicious);
const report = {
  schemaVersion: 1,
  status: issues.length > 0 ? "blocked" : suspiciousRows.length > 0 ? "suspicious_usage_detected" : "ok",
  mode,
  generatedAt: new Date().toISOString(),
  source: {
    instancesFile,
    historyFile,
    heartbeatInspectSource,
    controlCenterContainer,
  },
  filters: {
    instanceId: instanceFilter || "",
    lookbackHours,
  },
  summary: {
    instances: rows.length,
    suspiciousRows: suspiciousRows.length,
  },
  rows,
  issues,
  safety: {
    readsCollectorHistoryOnly: true,
    readsHeartbeatMetadataOnly: heartbeatInspectSource !== "none",
    writesOpenClawInstanceDirs: false,
    clearsHeartbeatFiles: false,
    callsModelApis: false,
    restartsOpenClawInstances: false,
    callsManagedActionsLiveApi: false,
  },
};

console.log(JSON.stringify(report, null, 2));
if (mode === "check" && suspiciousRows.length > 0) process.exit(2);
if (issues.length > 0) process.exit(2);
NODE
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage
      fail "未知模式：${mode}"
      ;;
  esac
}

main "$@"
