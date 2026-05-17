#!/usr/bin/env bash
set -euo pipefail
set +x

# 跨服务器 collector 快照拉取工具。
# 只通过 SSH 读取远端已经生成好的 collector JSON，并写入本机控制中心 runtime。
# 不执行远端 collector，不修改任何 OpenClaw 实例目录，也不调用 managed-actions live API。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
CONFIG_FILE="${CONFIG_FILE:-${DEPLOY_DIR}/runtime/remote-collector-pull.sources.json}"
STATE_DIR="${STATE_DIR:-${DEPLOY_DIR}/runtime/collector-pull-state}"
CONFIRM_REMOTE_COLLECTOR_PULL="${CONFIRM_REMOTE_COLLECTOR_PULL:-}"

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

usage() {
  cat <<'TEXT'
用法：
  remote-collector-pull.sh plan [sources.json]
  remote-collector-pull.sh pull [sources.json]
  remote-collector-pull.sh status [sources.json]

说明：
  plan 只校验配置并输出拉取计划，不联网。
  pull 只通过 SSH 读取远端 collector snapshot JSON，校验后原子写入 runtime/collectors。
  status 读取最近一次拉取状态文件，不联网。

安全确认：
  pull 必须设置：
    CONFIRM_REMOTE_COLLECTOR_PULL=I_UNDERSTAND_THIS_ONLY_READS_REMOTE_COLLECTOR_SNAPSHOTS

配置样板：
  repo/ops/tom-readonly/remote-collector-pull.sources.example.json
TEXT
}

run_node() {
  local mode="$1"
  local config="${2:-$CONFIG_FILE}"
  MODE="$mode" \
    DEPLOY_DIR="$DEPLOY_DIR" \
    CONFIG_FILE="$config" \
    STATE_DIR="$STATE_DIR" \
    CONFIRM_REMOTE_COLLECTOR_PULL="$CONFIRM_REMOTE_COLLECTOR_PULL" \
    node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const mode = process.env.MODE;
const deployDir = path.resolve(process.env.DEPLOY_DIR || "/srv/openclaw-control-center-readonly");
const configFile = path.resolve(process.env.CONFIG_FILE || path.join(deployDir, "runtime/remote-collector-pull.sources.json"));
const stateDir = path.resolve(process.env.STATE_DIR || path.join(deployDir, "runtime/collector-pull-state"));
const confirm = process.env.CONFIRM_REMOTE_COLLECTOR_PULL || "";
const runtimeCollectorsDir = path.join(deployDir, "runtime", "collectors");
const serverIdPattern = /^[a-z0-9_-]+$/;
const namePattern = /^[A-Za-z0-9._:-]+$/;

function fail(message) {
  console.error(`[失败] ${message}`);
  process.exit(2);
}

function warn(message) {
  console.error(`[提示] ${message}`);
}

function readJsonFile(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    fail(`无法读取配置：${file}：${formatError(error)}`);
  }
}

function asRecord(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : undefined;
}

function readString(value) {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : undefined;
}

function readInt(value, fallback) {
  if (value === undefined) return fallback;
  const parsed = Number.parseInt(String(value), 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function normalizeLocalPath(value, serverId) {
  const raw = readString(value) || path.join(runtimeCollectorsDir, serverId, "snapshot.json");
  const normalized = path.resolve(path.isAbsolute(raw) ? raw : path.join(deployDir, raw));
  const allowedRoot = `${path.resolve(runtimeCollectorsDir)}${path.sep}`;
  if (!normalized.startsWith(allowedRoot)) {
    throw new Error(`localSnapshotPath 必须位于 ${runtimeCollectorsDir} 之下`);
  }
  return normalized;
}

function validateRemotePath(value) {
  const remotePath = readString(value);
  if (!remotePath) throw new Error("remoteSnapshotPath 必须填写");
  if (!remotePath.startsWith("/")) throw new Error("remoteSnapshotPath 必须是绝对路径");
  if (/[\r\n\0]/.test(remotePath)) throw new Error("remoteSnapshotPath 包含非法字符");
  return remotePath;
}

function validateName(value, label) {
  const text = readString(value);
  if (!text) throw new Error(`${label} 必须填写`);
  if (!namePattern.test(text)) throw new Error(`${label} 包含非法字符`);
  return text;
}

function validateOptionalName(value, label) {
  const text = readString(value);
  if (!text) return undefined;
  if (/[\r\n\0]/.test(text)) throw new Error(`${label} 包含非法字符`);
  return text;
}

function validateAbsoluteFile(value, label) {
  const text = readString(value);
  if (!text) return undefined;
  if (!path.isAbsolute(text)) throw new Error(`${label} 必须是绝对路径`);
  if (/[\r\n\0]/.test(text)) throw new Error(`${label} 包含非法字符`);
  return text;
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function loadSources() {
  const config = readJsonFile(configFile);
  if (!asRecord(config)) fail("配置必须是 JSON object");
  const entries = Array.isArray(config.sources) ? config.sources : undefined;
  if (!entries) fail("配置必须包含 sources 数组");

  return entries.map((entry, index) => {
    try {
      const record = asRecord(entry);
      if (!record) throw new Error("source 必须是 object");
      const serverId = readString(record.serverId);
      if (!serverId || !serverIdPattern.test(serverId)) throw new Error("serverId 必须匹配 ^[a-z0-9_-]+$");
      const enabled = record.enabled !== false;
      const host = validateName(record.host, "host");
      const user = validateName(record.user, "user");
      const port = readInt(record.port, 22);
      if (port < 1 || port > 65535) throw new Error("port 必须在 1-65535 之间");
      const remoteSnapshotPath = validateRemotePath(record.remoteSnapshotPath);
      const localSnapshotPath = normalizeLocalPath(record.localSnapshotPath, serverId);
      const sshKey = validateAbsoluteFile(record.sshKey, "sshKey");
      const knownHostsFile = validateAbsoluteFile(record.knownHostsFile, "knownHostsFile") ||
        path.join(deployDir, "runtime", "ssh", "known_hosts");
      const strictHostKeyChecking = readString(record.strictHostKeyChecking) || "accept-new";
      if (!["yes", "accept-new", "no"].includes(strictHostKeyChecking)) {
        throw new Error("strictHostKeyChecking 只能是 yes、accept-new 或 no");
      }
      const connectTimeoutSeconds = readInt(record.connectTimeoutSeconds, 10);
      const name = validateOptionalName(record.name, "name");
      return {
        index,
        serverId,
        ...(name ? { name } : {}),
        enabled,
        host,
        user,
        port,
        ...(sshKey ? { sshKey } : {}),
        knownHostsFile,
        strictHostKeyChecking,
        connectTimeoutSeconds,
        remoteSnapshotPath,
        localSnapshotPath,
      };
    } catch (error) {
      throw new Error(`sources[${index}] 配置无效：${formatError(error)}`);
    }
  });
}

function validateSnapshot(text, source) {
  let snapshot;
  try {
    snapshot = JSON.parse(text);
  } catch (error) {
    throw new Error(`collector snapshot JSON 无法解析：${formatError(error)}`);
  }
  if (!asRecord(snapshot)) throw new Error("collector snapshot 必须是 object");
  if (snapshot.schemaVersion !== 1) throw new Error("collector snapshot schemaVersion 必须为 1");
  if (snapshot.serverId !== source.serverId) {
    throw new Error(`collector snapshot serverId 不匹配：expected=${source.serverId} actual=${snapshot.serverId}`);
  }
  const generatedAtMs = Date.parse(String(snapshot.generatedAt || ""));
  if (!Number.isFinite(generatedAtMs)) throw new Error("collector snapshot generatedAt 必须是可解析时间");
  if (!Array.isArray(snapshot.instances) || snapshot.instances.length === 0) {
    throw new Error("collector snapshot instances 必须是非空数组");
  }
  for (const item of snapshot.instances) {
    const entry = asRecord(item);
    const id = readString(entry?.id);
    if (!id || !serverIdPattern.test(id)) throw new Error(`collector snapshot instance id 无效：${id || ""}`);
    const status = readString(entry?.status);
    if (!["connected", "partial", "not_connected"].includes(status || "")) {
      throw new Error(`collector snapshot instance status 无效：${id}`);
    }
    if (!asRecord(entry?.snapshot)) throw new Error(`collector snapshot instance 缺少 snapshot：${id}`);
  }
  return snapshot;
}

function writeAtomic(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = path.join(path.dirname(file), `.${path.basename(file)}.${process.pid}.${Date.now()}.tmp`);
  fs.writeFileSync(tmp, text.endsWith("\n") ? text : `${text}\n`, "utf8");
  fs.renameSync(tmp, file);
}

function writeState(source, status, extra = {}) {
  fs.mkdirSync(stateDir, { recursive: true });
  const file = path.join(stateDir, `${source.serverId}.json`);
  const payload = {
    schemaVersion: 1,
    serverId: source.serverId,
    status,
    updatedAt: new Date().toISOString(),
    source: {
      host: source.host,
      user: source.user,
      port: source.port,
      remoteSnapshotPath: source.remoteSnapshotPath,
      localSnapshotPath: source.localSnapshotPath,
    },
    ...extra,
  };
  fs.writeFileSync(file, `${JSON.stringify(payload, null, 2)}\n`, "utf8");
  return file;
}

function pullSource(source) {
  if (!source.enabled) {
    return {
      serverId: source.serverId,
      status: "skipped_disabled",
      localSnapshotPath: source.localSnapshotPath,
    };
  }

  const args = [
    "-p",
    String(source.port),
    "-o",
    "BatchMode=yes",
    "-o",
    `ConnectTimeout=${source.connectTimeoutSeconds}`,
    "-o",
    `StrictHostKeyChecking=${source.strictHostKeyChecking}`,
    "-o",
    `UserKnownHostsFile=${source.knownHostsFile}`,
  ];
  if (source.sshKey) args.push("-i", source.sshKey);
  args.push(`${source.user}@${source.host}`, `cat -- ${shellQuote(source.remoteSnapshotPath)}`);

  fs.mkdirSync(path.dirname(source.knownHostsFile), { recursive: true });
  const result = spawnSync("ssh", args, {
    encoding: "utf8",
    maxBuffer: 10 * 1024 * 1024,
  });

  if (result.status !== 0) {
    const message = (result.stderr || result.stdout || `ssh exited with code ${result.status}`).trim();
    const stateFile = writeState(source, "failed", { error: message });
    return {
      serverId: source.serverId,
      status: "failed",
      error: message,
      stateFile,
      localSnapshotPath: source.localSnapshotPath,
    };
  }

  try {
    const snapshot = validateSnapshot(result.stdout, source);
    writeAtomic(source.localSnapshotPath, result.stdout);
    const stateFile = writeState(source, "pulled", {
      pulledAt: new Date().toISOString(),
      generatedAt: snapshot.generatedAt,
      instances: snapshot.instances.length,
    });
    return {
      serverId: source.serverId,
      status: "pulled",
      generatedAt: snapshot.generatedAt,
      instances: snapshot.instances.length,
      localSnapshotPath: source.localSnapshotPath,
      stateFile,
    };
  } catch (error) {
    const message = formatError(error);
    const stateFile = writeState(source, "failed", { error: message });
    return {
      serverId: source.serverId,
      status: "failed",
      error: message,
      stateFile,
      localSnapshotPath: source.localSnapshotPath,
    };
  }
}

function readStatus(sources) {
  return sources.map((source) => {
    const stateFile = path.join(stateDir, `${source.serverId}.json`);
    if (!fs.existsSync(stateFile)) {
      return {
        serverId: source.serverId,
        status: "missing",
        stateFile,
        localSnapshotPath: source.localSnapshotPath,
      };
    }
    try {
      const state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
      return {
        serverId: source.serverId,
        status: state.status || "unknown",
        updatedAt: state.updatedAt,
        generatedAt: state.generatedAt,
        instances: state.instances,
        error: state.error,
        stateFile,
        localSnapshotPath: source.localSnapshotPath,
      };
    } catch (error) {
      return {
        serverId: source.serverId,
        status: "invalid_state",
        error: formatError(error),
        stateFile,
        localSnapshotPath: source.localSnapshotPath,
      };
    }
  });
}

function formatError(error) {
  return error instanceof Error ? error.message : String(error);
}

let sources;
try {
  sources = loadSources();
} catch (error) {
  fail(formatError(error));
}

if (mode === "plan") {
  console.log(JSON.stringify({
    status: "planned",
    configFile,
    deployDir,
    sources: sources.map((source) => ({
      serverId: source.serverId,
      enabled: source.enabled,
      host: source.host,
      user: source.user,
      port: source.port,
      remoteSnapshotPath: source.remoteSnapshotPath,
      localSnapshotPath: source.localSnapshotPath,
      strictHostKeyChecking: source.strictHostKeyChecking,
    })),
  }, null, 2));
} else if (mode === "pull") {
  if (confirm !== "I_UNDERSTAND_THIS_ONLY_READS_REMOTE_COLLECTOR_SNAPSHOTS") {
    fail("必须设置 CONFIRM_REMOTE_COLLECTOR_PULL=I_UNDERSTAND_THIS_ONLY_READS_REMOTE_COLLECTOR_SNAPSHOTS");
  }
  const results = sources.map(pullSource);
  const failed = results.filter((item) => item.status === "failed");
  console.log(JSON.stringify({
    status: failed.length > 0 ? "failed" : "completed",
    configFile,
    results,
  }, null, 2));
  if (failed.length > 0) process.exit(2);
} else if (mode === "status") {
  console.log(JSON.stringify({
    status: "reported",
    configFile,
    stateDir,
    results: readStatus(sources),
  }, null, 2));
} else {
  fail(`未知模式：${mode}`);
}

if (sources.length === 0) warn("配置中没有 sources。");
NODE
}

main() {
  require_command node
  case "${1:-plan}" in
    plan)
      run_node "plan" "${2:-$CONFIG_FILE}"
      ;;
    pull)
      require_command ssh
      run_node "pull" "${2:-$CONFIG_FILE}"
      ;;
    status)
      run_node "status" "${2:-$CONFIG_FILE}"
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
