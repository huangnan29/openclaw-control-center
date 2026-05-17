#!/usr/bin/env bash
set -euo pipefail
set +x

# Tom registry 远端 collector 注册工具。
# plan 只读取 registry 和已拉取的 collector snapshot，不写文件。
# apply 会备份并原子更新 Tom 的 config/instances.json；不会修改任何 OpenClaw 实例目录，也不会调用 live API。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
REGISTRY_FILE="${REGISTRY_FILE:-${DEPLOY_DIR}/config/instances.json}"
CONFIG_FILE="${CONFIG_FILE:-${DEPLOY_DIR}/runtime/register-remote-collector.json}"
BACKUP_DIR="${BACKUP_DIR:-${DEPLOY_DIR}/runtime/deploy-state}"
CONFIRM_REMOTE_COLLECTOR_REGISTER="${CONFIRM_REMOTE_COLLECTOR_REGISTER:-}"

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
  register-remote-collector.sh plan [register.json]
  register-remote-collector.sh apply [register.json]

说明：
  plan 只读取配置、Tom registry 和本机已拉取的 collector snapshot，不写文件。
  apply 备份并原子更新 Tom config/instances.json，只注册 collector-only 远端 server。
  本脚本不会修改任何 OpenClaw 实例目录，不会重启实例，不会调用 managed-actions live API。

安全确认：
  apply 必须设置：
    CONFIRM_REMOTE_COLLECTOR_REGISTER=I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_REGISTRY

配置样板：
  repo/ops/tom-readonly/register-remote-collector.example.json
TEXT
}

run_node() {
  local mode="$1"
  local config="${2:-$CONFIG_FILE}"
  MODE="$mode" \
    DEPLOY_DIR="$DEPLOY_DIR" \
    REGISTRY_FILE="$REGISTRY_FILE" \
    CONFIG_FILE="$config" \
    BACKUP_DIR="$BACKUP_DIR" \
    CONFIRM_REMOTE_COLLECTOR_REGISTER="$CONFIRM_REMOTE_COLLECTOR_REGISTER" \
    node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const mode = process.env.MODE || "plan";
const deployDir = path.resolve(process.env.DEPLOY_DIR || "/srv/openclaw-control-center-readonly");
const registryFile = path.resolve(process.env.REGISTRY_FILE || path.join(deployDir, "config", "instances.json"));
const configFile = path.resolve(process.env.CONFIG_FILE || path.join(deployDir, "runtime", "register-remote-collector.json"));
const backupDir = path.resolve(process.env.BACKUP_DIR || path.join(deployDir, "runtime", "deploy-state"));
const confirm = process.env.CONFIRM_REMOTE_COLLECTOR_REGISTER || "";
const idPattern = /^[a-z0-9_-]+$/;

function fail(message) {
  console.error(`[失败] ${message}`);
  process.exit(2);
}

function readJsonFile(file, label) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    fail(`无法读取 ${label}：${file}：${formatError(error)}`);
  }
}

function asRecord(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : undefined;
}

function readString(value) {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : undefined;
}

function readId(value, label) {
  const text = readString(value);
  if (!text || !idPattern.test(text)) throw new Error(`${label} 必须匹配 ^[a-z0-9_-]+$`);
  return text;
}

function readName(value, label) {
  const text = readString(value);
  if (!text) throw new Error(`${label} 必须填写`);
  if (/[\r\n\0]/.test(text)) throw new Error(`${label} 包含非法字符`);
  return text;
}

function readOptionalName(value, label) {
  if (value === undefined) return undefined;
  return readName(value, label);
}

function collectorPathToHostPath(collectorSnapshotPath) {
  if (!collectorSnapshotPath.startsWith("/app/runtime/collectors/")) {
    throw new Error("collectorSnapshotPath 必须位于 /app/runtime/collectors/ 之下");
  }
  const relative = collectorSnapshotPath.slice("/app/runtime/".length);
  return path.join(deployDir, "runtime", relative);
}

function normalizeRegistration(raw) {
  const config = asRecord(raw);
  if (!config) throw new Error("注册配置必须是 JSON object");
  if (config.schemaVersion !== 1) throw new Error("schemaVersion 必须为 1");
  const server = asRecord(config.server);
  if (!server) throw new Error("server 必须是 object");
  const serverId = readId(server.id, "server.id");
  const collectorSnapshotPath = readName(config.collectorSnapshotPath, "collectorSnapshotPath");
  const hostSnapshotPath = collectorPathToHostPath(collectorSnapshotPath);
  const instances = Array.isArray(config.instances) ? config.instances.map((entry, index) => {
    const item = asRecord(entry);
    if (!item) throw new Error(`instances[${index}] 必须是 object`);
    return {
      id: readId(item.id, `instances[${index}].id`),
      name: readName(item.name || item.id, `instances[${index}].name`),
    };
  }) : undefined;
  return {
    server: {
      id: serverId,
      name: readName(server.name, "server.name"),
      ...(readOptionalName(server.host, "server.host") ? { host: readOptionalName(server.host, "server.host") } : {}),
      ...(readOptionalName(server.region, "server.region") ? { region: readOptionalName(server.region, "server.region") } : {}),
      ...(readOptionalName(server.description, "server.description") ? { description: readOptionalName(server.description, "server.description") } : {}),
      collectorSnapshotPath,
    },
    hostSnapshotPath,
    replaceExisting: config.replaceExisting === true,
    instances,
  };
}

function validateSnapshot(registration) {
  const snapshot = readJsonFile(registration.hostSnapshotPath, "collector snapshot");
  if (!asRecord(snapshot)) throw new Error("collector snapshot 必须是 object");
  if (snapshot.schemaVersion !== 1) throw new Error("collector snapshot schemaVersion 必须为 1");
  if (snapshot.serverId !== registration.server.id) {
    throw new Error(`collector snapshot serverId 不匹配：expected=${registration.server.id} actual=${snapshot.serverId}`);
  }
  const generatedAtMs = Date.parse(String(snapshot.generatedAt || ""));
  if (!Number.isFinite(generatedAtMs)) throw new Error("collector snapshot generatedAt 必须是可解析时间");
  if (!Array.isArray(snapshot.instances) || snapshot.instances.length === 0) {
    throw new Error("collector snapshot instances 必须是非空数组");
  }
  const snapshotInstances = snapshot.instances.map((entry, index) => {
    const item = asRecord(entry);
    if (!item) throw new Error(`snapshot.instances[${index}] 必须是 object`);
    const id = readId(item.id, `snapshot.instances[${index}].id`);
    const status = readString(item.status);
    if (!["connected", "partial", "not_connected"].includes(status || "")) {
      throw new Error(`snapshot.instances[${index}].status 无效`);
    }
    if (!asRecord(item.snapshot)) throw new Error(`snapshot.instances[${index}].snapshot 缺失`);
    return { id, name: id };
  });
  const requested = registration.instances ?? snapshotInstances;
  const snapshotIds = new Set(snapshotInstances.map((item) => item.id));
  for (const item of requested) {
    if (!snapshotIds.has(item.id)) throw new Error(`注册实例不在 collector snapshot 中：${item.id}`);
  }
  return {
    serverId: snapshot.serverId,
    generatedAt: snapshot.generatedAt,
    instances: requested,
    snapshotInstances,
  };
}

function normalizeRegistry(raw) {
  const registry = asRecord(raw);
  if (!registry) throw new Error("instances registry 必须是 JSON object");
  const servers = Array.isArray(registry.servers) ? registry.servers : undefined;
  if (!servers) throw new Error("instances registry 必须包含 servers 数组");
  return {
    ...registry,
    servers: servers.map((server) => ({ ...server })),
  };
}

function buildNextRegistry(registry, registration, snapshot) {
  const existingIndex = registry.servers.findIndex((server) => asRecord(server)?.id === registration.server.id);
  if (existingIndex >= 0 && !registration.replaceExisting) {
    throw new Error(`server 已存在，若要替换请设置 replaceExisting=true：${registration.server.id}`);
  }
  const existingInstanceIds = new Set();
  for (const server of registry.servers) {
    const record = asRecord(server);
    if (!record || record.id === registration.server.id) continue;
    const entries = Array.isArray(record.instances) ? record.instances : [];
    for (const entry of entries) {
      const id = readString(asRecord(entry)?.id);
      if (id) existingInstanceIds.add(id);
    }
  }
  for (const item of snapshot.instances) {
    if (existingInstanceIds.has(item.id)) {
      throw new Error(`实例 id 已被其他 server 使用：${item.id}`);
    }
  }

  const nextServer = {
    ...registration.server,
    instances: snapshot.instances.map((item) => ({
      id: item.id,
      name: item.name,
    })),
  };
  const nextServers = [...registry.servers];
  if (existingIndex >= 0) {
    nextServers[existingIndex] = nextServer;
  } else {
    nextServers.push(nextServer);
  }
  return {
    ...registry,
    servers: nextServers,
  };
}

function validateNextRegistry(registry) {
  const serverIds = new Set();
  const instanceIds = new Set();
  for (const server of registry.servers) {
    const record = asRecord(server);
    const serverId = readId(record?.id, "registry.server.id");
    if (serverIds.has(serverId)) throw new Error(`重复 server id：${serverId}`);
    serverIds.add(serverId);
    const entries = Array.isArray(record.instances) ? record.instances : [];
    if (entries.length === 0) throw new Error(`server.instances 不能为空：${serverId}`);
    for (const entry of entries) {
      const instance = asRecord(entry);
      const instanceId = readId(instance?.id, "registry.instance.id");
      if (instanceIds.has(instanceId)) throw new Error(`重复 instance id：${instanceId}`);
      instanceIds.add(instanceId);
      readName(instance?.name || instanceId, "registry.instance.name");
    }
  }
}

function backupAndWrite(nextRegistry) {
  fs.mkdirSync(backupDir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\..+$/, "Z");
  const backupFile = path.join(backupDir, `instances.before-remote-register.${stamp}.json.bak`);
  fs.copyFileSync(registryFile, backupFile);
  const tmp = path.join(path.dirname(registryFile), `.instances.json.${process.pid}.${Date.now()}.tmp`);
  fs.writeFileSync(tmp, `${JSON.stringify(nextRegistry, null, 2)}\n`, "utf8");
  fs.renameSync(tmp, registryFile);
  return backupFile;
}

function formatError(error) {
  return error instanceof Error ? error.message : String(error);
}

let registration;
let registry;
let snapshot;
let nextRegistry;
try {
  registration = normalizeRegistration(readJsonFile(configFile, "注册配置"));
  snapshot = validateSnapshot(registration);
  registry = normalizeRegistry(readJsonFile(registryFile, "instances registry"));
  nextRegistry = buildNextRegistry(registry, registration, snapshot);
  validateNextRegistry(nextRegistry);
} catch (error) {
  fail(formatError(error));
}

const action = registry.servers.some((server) => asRecord(server)?.id === registration.server.id) ? "replace" : "add";
const summary = {
  configFile,
  registryFile,
  serverId: registration.server.id,
  action,
  collectorSnapshotPath: registration.server.collectorSnapshotPath,
  hostSnapshotPath: registration.hostSnapshotPath,
  snapshotGeneratedAt: snapshot.generatedAt,
  instances: snapshot.instances,
  safety: {
    updatesControlCenterRegistryOnly: true,
    mutatesOpenClawInstance: false,
    restartsOpenClawInstance: false,
    callsLiveApi: false,
  },
};

if (mode === "plan") {
  console.log(JSON.stringify({ status: "planned", ...summary }, null, 2));
} else if (mode === "apply") {
  if (confirm !== "I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_REGISTRY") {
    fail("必须设置 CONFIRM_REMOTE_COLLECTOR_REGISTER=I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_REGISTRY");
  }
  const backupFile = backupAndWrite(nextRegistry);
  console.log(JSON.stringify({
    status: "applied",
    ...summary,
    backupFile,
    nextActions: [
      "运行 ./healthcheck.sh 验证 collector snapshot 新鲜度和页面只读状态。",
      "确认 UI 中出现新增 server 和实例。",
    ],
  }, null, 2));
} else {
  fail(`未知模式：${mode}`);
}
NODE
}

main() {
  require_command node
  case "${1:-plan}" in
    plan)
      run_node "plan" "${2:-$CONFIG_FILE}"
      ;;
    apply)
      run_node "apply" "${2:-$CONFIG_FILE}"
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
