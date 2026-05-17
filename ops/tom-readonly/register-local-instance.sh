#!/usr/bin/env bash
set -euo pipefail
set +x

# Tom 本机实例注册工具。
# plan 只读取配置、registry、compose 和实例目录元数据，不写文件。
# apply 会备份并原子更新 control-center 的 config/instances.json 与 docker-compose.yml。
# 本脚本不会修改任何 OpenClaw 实例目录，不会重启实例，不会调用 managed-actions live API。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
REGISTRY_FILE="${REGISTRY_FILE:-${DEPLOY_DIR}/config/instances.json}"
COMPOSE_FILE="${COMPOSE_FILE:-${DEPLOY_DIR}/docker-compose.yml}"
CONFIG_FILE="${CONFIG_FILE:-${DEPLOY_DIR}/runtime/register-local-instance.json}"
BACKUP_DIR="${BACKUP_DIR:-${DEPLOY_DIR}/runtime/deploy-state}"
CONFIRM_LOCAL_INSTANCE_REGISTER="${CONFIRM_LOCAL_INSTANCE_REGISTER:-}"

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
  register-local-instance.sh plan [register-local-instance.json]
  register-local-instance.sh apply [register-local-instance.json]

说明：
  plan 只读取配置、Tom registry、docker-compose.yml 和实例目录元数据，不写文件。
  apply 备份并原子更新 Tom control-center 的 config/instances.json 与 docker-compose.yml。
  本脚本只为 control-center 增加本机实例的只读挂载和 registry 条目。
  本脚本不会修改任何 OpenClaw 实例目录，不会重启实例，不会调用 managed-actions live API。

安全确认：
  apply 必须设置：
    CONFIRM_LOCAL_INSTANCE_REGISTER=I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_LOCAL_REGISTRY

配置样板：
  repo/ops/tom-readonly/register-local-instance.example.json
TEXT
}

run_node() {
  local mode="$1"
  local config="${2:-$CONFIG_FILE}"
  MODE="$mode" \
    DEPLOY_DIR="$DEPLOY_DIR" \
    REGISTRY_FILE="$REGISTRY_FILE" \
    COMPOSE_FILE="$COMPOSE_FILE" \
    CONFIG_FILE="$config" \
    BACKUP_DIR="$BACKUP_DIR" \
    CONFIRM_LOCAL_INSTANCE_REGISTER="$CONFIRM_LOCAL_INSTANCE_REGISTER" \
    node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const mode = process.env.MODE || "plan";
const deployDir = path.resolve(process.env.DEPLOY_DIR || "/srv/openclaw-control-center-readonly");
const registryFile = path.resolve(process.env.REGISTRY_FILE || path.join(deployDir, "config", "instances.json"));
const composeFile = path.resolve(process.env.COMPOSE_FILE || path.join(deployDir, "docker-compose.yml"));
const configFile = path.resolve(process.env.CONFIG_FILE || path.join(deployDir, "runtime", "register-local-instance.json"));
const backupDir = path.resolve(process.env.BACKUP_DIR || path.join(deployDir, "runtime", "deploy-state"));
const confirm = process.env.CONFIRM_LOCAL_INSTANCE_REGISTER || "";
const idPattern = /^[a-z0-9_-]+$/;

function fail(message) {
  console.error(`[失败] ${message}`);
  process.exit(2);
}

function formatError(error) {
  return error instanceof Error ? error.message : String(error);
}

function asRecord(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : undefined;
}

function readJsonFile(file, label) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    fail(`无法读取 ${label}：${file}：${formatError(error)}`);
  }
}

function readTextFile(file, label) {
  try {
    return fs.readFileSync(file, "utf8");
  } catch (error) {
    fail(`无法读取 ${label}：${file}：${formatError(error)}`);
  }
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

function readGatewayUrl(value, label) {
  const text = readName(value, label);
  let parsed;
  try {
    parsed = new URL(text);
  } catch {
    throw new Error(`${label} 必须是有效 URL`);
  }
  if (!["ws:", "wss:", "http:", "https:"].includes(parsed.protocol)) {
    throw new Error(`${label} 只允许 ws/wss/http/https`);
  }
  return text;
}

function readHostDir(value, label) {
  const text = readName(value, label);
  if (!path.isAbsolute(text)) throw new Error(`${label} 必须是绝对路径`);
  if (/[\r\n\0]/.test(text) || /\s/.test(text) || text.includes(":")) {
    throw new Error(`${label} 不能包含空白、冒号或控制字符`);
  }
  let stat;
  try {
    stat = fs.statSync(text);
  } catch (error) {
    throw new Error(`${label} 无法读取：${text}：${formatError(error)}`);
  }
  if (!stat.isDirectory()) throw new Error(`${label} 必须是目录：${text}`);
  return text;
}

function normalizeConfig(raw) {
  const config = asRecord(raw);
  if (!config) throw new Error("注册配置必须是 JSON object");
  if (config.schemaVersion !== 1) throw new Error("schemaVersion 必须为 1");

  const server = asRecord(config.server);
  if (!server) throw new Error("server 必须是 object");
  const instance = asRecord(config.instance);
  if (!instance) throw new Error("instance 必须是 object");

  const instanceId = readId(instance.id, "instance.id");
  return {
    server: {
      id: readId(server.id, "server.id"),
      name: readName(server.name, "server.name"),
      ...(readOptionalName(server.host, "server.host") ? { host: readOptionalName(server.host, "server.host") } : {}),
      ...(readOptionalName(server.region, "server.region") ? { region: readOptionalName(server.region, "server.region") } : {}),
    },
    instance: {
      id: instanceId,
      name: readName(instance.name || instanceId, "instance.name"),
      gatewayUrl: readGatewayUrl(instance.gatewayUrl, "instance.gatewayUrl"),
      configDir: readHostDir(instance.configDir, "instance.configDir"),
      workspaceDir: readHostDir(instance.workspaceDir, "instance.workspaceDir"),
      openclawHome: `/instances/${instanceId}/config`,
      workspaceRoot: `/instances/${instanceId}/workspace`,
      readonly: true,
    },
    replaceExisting: config.replaceExisting === true,
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

function normalizeInstanceForRegistry(input) {
  return {
    id: input.id,
    name: input.name,
    gatewayUrl: input.gatewayUrl,
    openclawHome: input.openclawHome,
    workspaceRoot: input.workspaceRoot,
    readonly: true,
  };
}

function findServer(registry, serverId) {
  return registry.servers.findIndex((server) => asRecord(server)?.id === serverId);
}

function ensureUniqueInstanceIds(registry, config, existingServerIndex, existingInstanceIndex) {
  for (let serverIndex = 0; serverIndex < registry.servers.length; serverIndex += 1) {
    const server = asRecord(registry.servers[serverIndex]);
    const entries = Array.isArray(server?.instances) ? server.instances : [];
    for (let instanceIndex = 0; instanceIndex < entries.length; instanceIndex += 1) {
      const entry = asRecord(entries[instanceIndex]);
      if (readString(entry?.id) !== config.instance.id) continue;
      if (serverIndex === existingServerIndex && instanceIndex === existingInstanceIndex) continue;
      throw new Error(`实例 id 已存在：${config.instance.id}`);
    }
  }
}

function buildNextRegistry(registry, config) {
  const serverIndex = findServer(registry, config.server.id);
  if (serverIndex < 0) {
    throw new Error(`server 不存在：${config.server.id}。本机扩展必须挂到当前 Oracle server。`);
  }

  const server = { ...asRecord(registry.servers[serverIndex]) };
  const instances = Array.isArray(server.instances) ? server.instances.map((item) => ({ ...asRecord(item) })) : [];
  const existingIndex = instances.findIndex((item) => readString(item.id) === config.instance.id);
  if (existingIndex >= 0 && !config.replaceExisting) {
    const existing = instances[existingIndex];
    const expected = normalizeInstanceForRegistry(config.instance);
    const identical =
      existing.name === expected.name &&
      existing.gatewayUrl === expected.gatewayUrl &&
      existing.openclawHome === expected.openclawHome &&
      existing.workspaceRoot === expected.workspaceRoot &&
      existing.readonly === true;
    if (!identical) throw new Error(`实例已存在，若要替换请设置 replaceExisting=true：${config.instance.id}`);
  }

  ensureUniqueInstanceIds(registry, config, serverIndex, existingIndex);

  const nextInstance = normalizeInstanceForRegistry(config.instance);
  if (existingIndex >= 0) {
    instances[existingIndex] = nextInstance;
  } else {
    instances.push(nextInstance);
  }

  const nextServers = [...registry.servers];
  nextServers[serverIndex] = {
    ...server,
    id: config.server.id,
    name: server.name || config.server.name,
    ...(server.host || config.server.host ? { host: server.host || config.server.host } : {}),
    ...(server.region || config.server.region ? { region: server.region || config.server.region } : {}),
    instances,
  };

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
      readGatewayUrl(instance?.gatewayUrl || "ws://host.docker.internal:18789", "registry.instance.gatewayUrl");
      readName(instance?.openclawHome, "registry.instance.openclawHome");
      readName(instance?.workspaceRoot, "registry.instance.workspaceRoot");
      if (instance.readonly !== true) throw new Error(`registry.instance.readonly 必须为 true：${instanceId}`);
    }
  }
}

function volumeLine(hostDir, instanceId, targetName) {
  return `      - ${hostDir}:/instances/${instanceId}/${targetName}:ro`;
}

function hasVolumeTarget(composeText, instanceId, targetName) {
  return new RegExp(`:/instances/${escapeRegExp(instanceId)}/${targetName}:ro(?:\\s|$)`).test(composeText);
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function buildNextCompose(composeText, config) {
  const configTarget = `/instances/${config.instance.id}/config`;
  const workspaceTarget = `/instances/${config.instance.id}/workspace`;
  const configLine = volumeLine(config.instance.configDir, config.instance.id, "config");
  const workspaceLine = volumeLine(config.instance.workspaceDir, config.instance.id, "workspace");
  const alreadyHasConfig = hasVolumeTarget(composeText, config.instance.id, "config");
  const alreadyHasWorkspace = hasVolumeTarget(composeText, config.instance.id, "workspace");

  if (alreadyHasConfig && alreadyHasWorkspace && !config.replaceExisting) {
    return { text: composeText, changed: false, addedVolumes: [] };
  }

  let lines = composeText.split(/\n/);
  lines = lines.filter((line) => !line.includes(`:${configTarget}:ro`) && !line.includes(`:${workspaceTarget}:ro`));

  const volumesIndex = lines.findIndex((line) => line === "    volumes:");
  if (volumesIndex < 0) throw new Error("docker-compose.yml 中找不到 control-center volumes 块");

  let insertIndex = volumesIndex + 1;
  while (insertIndex < lines.length) {
    const line = lines[insertIndex];
    if (line === "" || /^      /.test(line)) {
      insertIndex += 1;
      continue;
    }
    break;
  }

  const nextLines = [
    ...lines.slice(0, insertIndex),
    configLine,
    workspaceLine,
    ...lines.slice(insertIndex),
  ];
  return {
    text: nextLines.join("\n"),
    changed: true,
    addedVolumes: [configLine.trim(), workspaceLine.trim()],
  };
}

function writeAtomic(file, text) {
  const tmp = path.join(path.dirname(file), `.${path.basename(file)}.${process.pid}.${Date.now()}.tmp`);
  fs.writeFileSync(tmp, text.endsWith("\n") ? text : `${text}\n`, "utf8");
  fs.renameSync(tmp, file);
}

function backupAndWrite(nextRegistry, nextCompose) {
  fs.mkdirSync(backupDir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\..+$/, "Z");
  const registryBackupFile = path.join(backupDir, `instances.before-local-register.${stamp}.json.bak`);
  const composeBackupFile = path.join(backupDir, `docker-compose.before-local-register.${stamp}.yml.bak`);
  fs.copyFileSync(registryFile, registryBackupFile);
  fs.copyFileSync(composeFile, composeBackupFile);
  writeAtomic(registryFile, `${JSON.stringify(nextRegistry, null, 2)}\n`);
  writeAtomic(composeFile, nextCompose.text);
  return { registryBackupFile, composeBackupFile };
}

let config;
let registry;
let composeText;
let nextRegistry;
let nextCompose;
try {
  config = normalizeConfig(readJsonFile(configFile, "本机实例注册配置"));
  registry = normalizeRegistry(readJsonFile(registryFile, "instances registry"));
  composeText = readTextFile(composeFile, "docker-compose.yml");
  nextRegistry = buildNextRegistry(registry, config);
  validateNextRegistry(nextRegistry);
  nextCompose = buildNextCompose(composeText, config);
} catch (error) {
  fail(formatError(error));
}

const serverIndex = findServer(registry, config.server.id);
const server = asRecord(registry.servers[serverIndex]);
const entries = Array.isArray(server?.instances) ? server.instances : [];
const existed = entries.some((entry) => asRecord(entry)?.id === config.instance.id);
const registryChanged = JSON.stringify(registry) !== JSON.stringify(nextRegistry);
const composeChanged = nextCompose.changed;
const status = existed && !registryChanged && !composeChanged ? "already_registered" : "planned";
const summary = {
  configFile,
  registryFile,
  composeFile,
  serverId: config.server.id,
  instance: {
    id: config.instance.id,
    name: config.instance.name,
    gatewayUrl: config.instance.gatewayUrl,
    configDir: config.instance.configDir,
    workspaceDir: config.instance.workspaceDir,
    openclawHome: config.instance.openclawHome,
    workspaceRoot: config.instance.workspaceRoot,
  },
  action: existed ? (config.replaceExisting ? "replace" : "noop_or_blocked_existing") : "add",
  registryChanged,
  composeChanged,
  addedVolumes: nextCompose.addedVolumes,
  safety: {
    updatesControlCenterRegistryOnly: false,
    updatesControlCenterRegistryAndComposeOnly: true,
    writesOpenClawInstanceDirs: false,
    mutatesOpenClawInstance: false,
    restartsOpenClawInstance: false,
    restartsControlCenter: false,
    callsLiveApi: false,
  },
};

if (mode === "plan") {
  console.log(JSON.stringify({ status, ...summary }, null, 2));
} else if (mode === "apply") {
  if (confirm !== "I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_LOCAL_REGISTRY") {
    fail("必须设置 CONFIRM_LOCAL_INSTANCE_REGISTER=I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_LOCAL_REGISTRY");
  }
  if (!registryChanged && !composeChanged) {
    console.log(JSON.stringify({ status: "already_registered", ...summary }, null, 2));
  } else {
    const backups = backupAndWrite(nextRegistry, nextCompose);
    console.log(JSON.stringify({
      status: "applied",
      ...summary,
      ...backups,
      nextActions: [
        "运行 docker compose up -d control-center 仅重建控制中心容器挂载。",
        "运行 ./collector-snapshot.sh 刷新 Tom 本机 collector snapshot。",
        "运行 ./healthcheck.sh 验证新增实例和只读边界。",
      ],
    }, null, 2));
  }
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
