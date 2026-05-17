#!/usr/bin/env bash
set -euo pipefail
set +x

# 远端 collector 凭据准备工具。
# plan 只校验凭据配置，不写文件、不联网。
# apply 只把 Tom 本地可读的远端只读 SSH key 复制到 control-center runtime/ssh，
# 并生成 runtime/remote-collector-onboarding.json；不 SSH、不写 registry、不修改任何 OpenClaw 实例目录。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
CONFIG_FILE="${CONFIG_FILE:-${DEPLOY_DIR}/runtime/remote-collector-credentials.json}"
CONFIRM_REMOTE_COLLECTOR_CREDENTIALS="${CONFIRM_REMOTE_COLLECTOR_CREDENTIALS:-}"

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
  remote-collector-credentials.sh plan [credentials.json]
  remote-collector-credentials.sh apply [credentials.json]

说明：
  plan 只校验远端凭据配置，不写文件、不联网。
  apply 只写 Tom control-center runtime：
    1. 复制 sourceSshKeyPath 到 runtime/ssh/<serverId>-readonly.key，并设置 600 权限。
    2. 生成 runtime/remote-collector-onboarding.json，供 remote-collector-onboarding.sh 使用。

安全边界：
  本脚本不会 SSH，不会写远端文件，不会修改 config/instances.json，不会修改任何 OpenClaw 实例目录，不会调用 managed-actions live API。

安全确认：
  apply 必须设置：
    CONFIRM_REMOTE_COLLECTOR_CREDENTIALS=I_UNDERSTAND_THIS_ONLY_WRITES_CONTROL_CENTER_REMOTE_CREDENTIALS

配置样板：
  repo/ops/tom-readonly/remote-collector-credentials.example.json
TEXT
}

run_node() {
  local mode="$1"
  local config="${2:-$CONFIG_FILE}"
  MODE="$mode" \
    DEPLOY_DIR="$DEPLOY_DIR" \
    CONFIG_FILE="$config" \
    CONFIRM_REMOTE_COLLECTOR_CREDENTIALS="$CONFIRM_REMOTE_COLLECTOR_CREDENTIALS" \
    node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const mode = process.env.MODE || "plan";
const deployDir = path.resolve(process.env.DEPLOY_DIR || "/srv/openclaw-control-center-readonly");
const configFile = path.resolve(process.env.CONFIG_FILE || path.join(deployDir, "runtime", "remote-collector-credentials.json"));
const confirm = process.env.CONFIRM_REMOTE_COLLECTOR_CREDENTIALS || "";
const idPattern = /^[a-z0-9_-]+$/;

function fail(message) {
  console.error(`[失败] ${message}`);
  process.exit(2);
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

function readAbsolutePath(value, label) {
  const text = readString(value);
  if (!text) throw new Error(`${label} 必须填写`);
  if (!path.isAbsolute(text)) throw new Error(`${label} 必须是绝对路径`);
  if (/[\r\n\0]/.test(text)) throw new Error(`${label} 包含非法字符`);
  return path.resolve(text);
}

function readOptionalAbsolutePath(value, label) {
  if (value === undefined) return undefined;
  return readAbsolutePath(value, label);
}

function readBoolean(value, fallback) {
  if (value === undefined) return fallback;
  if (value === true || value === "true") return true;
  if (value === false || value === "false") return false;
  throw new Error("布尔配置只能是 true 或 false");
}

function readPort(value, fallback) {
  const parsed = Number.parseInt(String(value === undefined ? fallback : value), 10);
  if (!Number.isFinite(parsed) || parsed < 1 || parsed > 65535) throw new Error("remote.port 必须在 1-65535 之间");
  return parsed;
}

function readJsonFile(file, label) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    throw new Error(`无法读取 ${label}：${file}：${formatError(error)}`);
  }
}

function ensureUnderRuntime(file, label) {
  const runtimeDir = path.join(deployDir, "runtime");
  const resolved = path.resolve(file);
  const allowedRoot = `${path.resolve(runtimeDir)}${path.sep}`;
  if (!resolved.startsWith(allowedRoot)) {
    throw new Error(`${label} 必须位于 ${runtimeDir} 之下`);
  }
  return resolved;
}

function defaultTargetKeyPath(serverId) {
  return path.join(deployDir, "runtime", "ssh", `${serverId}-readonly.key`);
}

function defaultKnownHostsFile() {
  return path.join(deployDir, "runtime", "ssh", "known_hosts");
}

function defaultOutputConfigFile() {
  return path.join(deployDir, "runtime", "remote-collector-onboarding.json");
}

function normalizeConfig(raw) {
  const config = asRecord(raw);
  if (!config) throw new Error("配置必须是 JSON object");
  if (config.schemaVersion !== 1) throw new Error("schemaVersion 必须为 1");

  const server = asRecord(config.server);
  if (!server) throw new Error("server 必须是 object");
  const serverId = readId(server.id, "server.id");
  const serverName = readName(server.name, "server.name");
  const serverHost = readName(server.host, "server.host");

  const remote = asRecord(config.remote);
  if (!remote) throw new Error("remote 必须是 object");
  const remoteHost = readName(remote.host || serverHost, "remote.host");
  const remoteUser = readName(remote.user || "ubuntu", "remote.user");
  const remotePort = readPort(remote.port, 22);
  const sourceSshKeyPath = readAbsolutePath(remote.sourceSshKeyPath, "remote.sourceSshKeyPath");
  const targetSshKeyPath = ensureUnderRuntime(
    readOptionalAbsolutePath(remote.targetSshKeyPath, "remote.targetSshKeyPath") || defaultTargetKeyPath(serverId),
    "remote.targetSshKeyPath",
  );
  const knownHostsFile = ensureUnderRuntime(
    readOptionalAbsolutePath(remote.knownHostsFile, "remote.knownHostsFile") || defaultKnownHostsFile(),
    "remote.knownHostsFile",
  );
  const strictHostKeyChecking = readString(remote.strictHostKeyChecking) || "accept-new";
  if (!["yes", "accept-new", "no"].includes(strictHostKeyChecking)) {
    throw new Error("remote.strictHostKeyChecking 只能是 yes、accept-new 或 no");
  }
  const connectTimeoutSeconds = Number.parseInt(String(remote.connectTimeoutSeconds || 10), 10);
  if (!Number.isFinite(connectTimeoutSeconds) || connectTimeoutSeconds < 1 || connectTimeoutSeconds > 120) {
    throw new Error("remote.connectTimeoutSeconds 必须在 1-120 之间");
  }
  const remoteDeployDir = readAbsolutePath(remote.deployDir || "/srv/openclaw-collector-node", "remote.deployDir");

  const collectorNode = asRecord(config.collectorNode) || {};
  const instancesRaw = Array.isArray(config.instances) ? config.instances : undefined;
  if (!instancesRaw || instancesRaw.length === 0) throw new Error("instances 必须是非空数组");
  const seen = new Set();
  const instances = instancesRaw.map((entry, index) => {
    const item = asRecord(entry);
    if (!item) throw new Error(`instances[${index}] 必须是 object`);
    const id = readId(item.id, `instances[${index}].id`);
    if (seen.has(id)) throw new Error(`重复实例 id：${id}`);
    seen.add(id);
    return {
      id,
      name: readName(item.name || id, `instances[${index}].name`),
      gatewayUrl: readName(item.gatewayUrl, `instances[${index}].gatewayUrl`),
      configDir: readAbsolutePath(item.configDir, `instances[${index}].configDir`),
      workspaceDir: readAbsolutePath(item.workspaceDir, `instances[${index}].workspaceDir`),
      ...(readOptionalAbsolutePath(item.codexDir, `instances[${index}].codexDir`) ? {
        codexDir: readOptionalAbsolutePath(item.codexDir, `instances[${index}].codexDir`),
      } : {}),
    };
  });

  const outputConfigFile = ensureUnderRuntime(
    readOptionalAbsolutePath(config.outputConfigFile, "outputConfigFile") || defaultOutputConfigFile(),
    "outputConfigFile",
  );
  const overwrite = readBoolean(config.overwrite, false);
  return {
    server: {
      id: serverId,
      name: serverName,
      host: serverHost,
      ...(readOptionalName(server.region, "server.region") ? { region: readOptionalName(server.region, "server.region") } : {}),
      ...(readOptionalName(server.description, "server.description") ? { description: readOptionalName(server.description, "server.description") } : {}),
    },
    remote: {
      host: remoteHost,
      user: remoteUser,
      port: remotePort,
      sourceSshKeyPath,
      targetSshKeyPath,
      knownHostsFile,
      strictHostKeyChecking,
      connectTimeoutSeconds,
      deployDir: remoteDeployDir,
    },
    collectorNode: {
      image: readName(collectorNode.image || "openclaw-control-center:collector-node", "collectorNode.image"),
      bundleBuildContext: readBoolean(collectorNode.bundleBuildContext, true),
      ...(readOptionalAbsolutePath(collectorNode.buildContext, "collectorNode.buildContext") ? {
        buildContext: readOptionalAbsolutePath(collectorNode.buildContext, "collectorNode.buildContext"),
      } : {}),
      collectorContainerName: readName(collectorNode.collectorContainerName || `openclaw-collector-${serverId}`, "collectorNode.collectorContainerName"),
      cronSchedule: readName(collectorNode.cronSchedule || "*/2 * * * *", "collectorNode.cronSchedule"),
    },
    instances,
    outputConfigFile,
    overwrite,
  };
}

function buildOnboardingConfig(config) {
  return {
    schemaVersion: 1,
    server: config.server,
    remote: {
      host: config.remote.host,
      user: config.remote.user,
      port: config.remote.port,
      sshKey: config.remote.targetSshKeyPath,
      knownHostsFile: config.remote.knownHostsFile,
      strictHostKeyChecking: config.remote.strictHostKeyChecking,
      connectTimeoutSeconds: config.remote.connectTimeoutSeconds,
      deployDir: config.remote.deployDir,
    },
    collectorNode: config.collectorNode,
    instances: config.instances,
  };
}

function assertApplyReady(config) {
  if (!fs.existsSync(config.remote.sourceSshKeyPath)) {
    throw new Error(`sourceSshKeyPath 不存在：${config.remote.sourceSshKeyPath}`);
  }
  try {
    fs.accessSync(config.remote.sourceSshKeyPath, fs.constants.R_OK);
  } catch {
    throw new Error(`sourceSshKeyPath 不可读：${config.remote.sourceSshKeyPath}`);
  }
  if (!config.overwrite && fs.existsSync(config.remote.targetSshKeyPath)) {
    throw new Error(`targetSshKeyPath 已存在；如需覆盖请设置 overwrite=true：${config.remote.targetSshKeyPath}`);
  }
  if (!config.overwrite && fs.existsSync(config.outputConfigFile)) {
    throw new Error(`outputConfigFile 已存在；如需覆盖请设置 overwrite=true：${config.outputConfigFile}`);
  }
}

function writeAtomic(file, text, modeValue) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = path.join(path.dirname(file), `.${path.basename(file)}.${process.pid}.${Date.now()}.tmp`);
  fs.writeFileSync(tmp, text.endsWith("\n") ? text : `${text}\n`, { encoding: "utf8", mode: modeValue });
  if (modeValue !== undefined) fs.chmodSync(tmp, modeValue);
  fs.renameSync(tmp, file);
}

function applyConfig(config) {
  assertApplyReady(config);
  fs.mkdirSync(path.dirname(config.remote.targetSshKeyPath), { recursive: true, mode: 0o700 });
  const keyText = fs.readFileSync(config.remote.sourceSshKeyPath, "utf8");
  writeAtomic(config.remote.targetSshKeyPath, keyText, 0o600);
  fs.chmodSync(config.remote.targetSshKeyPath, 0o600);
  const onboarding = buildOnboardingConfig(config);
  writeAtomic(config.outputConfigFile, JSON.stringify(onboarding, null, 2), 0o600);
  return {
    keyFile: config.remote.targetSshKeyPath,
    onboardingConfigFile: config.outputConfigFile,
  };
}

function safety(writes) {
  return {
    writesControlCenterRuntimeOnly: writes,
    connectsSsh: false,
    writesRemoteFiles: false,
    writesActiveRegistry: false,
    startsContainers: false,
    mutatesOpenClawInstance: false,
    restartsOpenClawInstance: false,
    callsLiveApi: false,
  };
}

function formatError(error) {
  return error instanceof Error ? error.message : String(error);
}

let normalized;
try {
  normalized = normalizeConfig(readJsonFile(configFile, "凭据配置"));
} catch (error) {
  fail(formatError(error));
}

const summary = {
  configFile,
  serverId: normalized.server.id,
  server: normalized.server,
  remote: {
    host: normalized.remote.host,
    user: normalized.remote.user,
    port: normalized.remote.port,
    sourceSshKeyPath: normalized.remote.sourceSshKeyPath,
    targetSshKeyPath: normalized.remote.targetSshKeyPath,
    knownHostsFile: normalized.remote.knownHostsFile,
    deployDir: normalized.remote.deployDir,
  },
  outputConfigFile: normalized.outputConfigFile,
  overwrite: normalized.overwrite,
  instances: normalized.instances.map((item) => ({ id: item.id, name: item.name })),
};

if (mode === "plan") {
  console.log(JSON.stringify({
    status: "planned",
    ...summary,
    sourceKeyExists: fs.existsSync(normalized.remote.sourceSshKeyPath),
    targetKeyExists: fs.existsSync(normalized.remote.targetSshKeyPath),
    onboardingConfigExists: fs.existsSync(normalized.outputConfigFile),
    safety: safety(false),
  }, null, 2));
} else if (mode === "apply") {
  if (confirm !== "I_UNDERSTAND_THIS_ONLY_WRITES_CONTROL_CENTER_REMOTE_CREDENTIALS") {
    fail("必须设置 CONFIRM_REMOTE_COLLECTOR_CREDENTIALS=I_UNDERSTAND_THIS_ONLY_WRITES_CONTROL_CENTER_REMOTE_CREDENTIALS");
  }
  let written;
  try {
    written = applyConfig(normalized);
  } catch (error) {
    fail(formatError(error));
  }
  console.log(JSON.stringify({
    status: "applied",
    ...summary,
    written,
    nextActions: [
      `repo/ops/tom-readonly/remote-collector-onboarding.sh plan ${normalized.outputConfigFile}`,
      `CONFIRM_REMOTE_COLLECTOR_ONBOARDING=I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_ONBOARDING_BUNDLE repo/ops/tom-readonly/remote-collector-onboarding.sh write ${normalized.outputConfigFile}`,
      `repo/ops/tom-readonly/remote-collector-onboarding.sh verify runtime/remote-onboarding/${normalized.server.id}`,
      `repo/ops/tom-readonly/remote-collector-rollout.sh status runtime/remote-onboarding/${normalized.server.id}`,
    ],
    safety: safety(true),
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
