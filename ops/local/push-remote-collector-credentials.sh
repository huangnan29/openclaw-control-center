#!/usr/bin/env bash
set -euo pipefail
set +x

# 本机到 Tom 的远端 collector 凭据推送工具。
# plan 只校验本机配置，不联网、不写文件。
# apply 只通过 SSH 写 Tom control-center runtime/ssh 和 runtime/remote-collector-onboarding.json。
# 它不会连接第二台 Oracle，不会写 Tom registry，不会修改任何 OpenClaw 实例目录。

CONFIG_FILE="${CONFIG_FILE:-ops/local/push-remote-collector-credentials.example.json}"
CONFIRM_PUSH_REMOTE_COLLECTOR_CREDENTIALS="${CONFIRM_PUSH_REMOTE_COLLECTOR_CREDENTIALS:-}"

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
  push-remote-collector-credentials.sh plan [config.json]
  push-remote-collector-credentials.sh apply [config.json]

说明：
  plan 只校验本机配置，不联网、不写文件。
  apply 只通过 SSH 写 Tom control-center runtime：
    1. runtime/ssh/<serverId>-readonly.key
    2. runtime/remote-collector-onboarding.json

安全边界：
  本脚本不会连接第二台 Oracle，不会写远端 collector 节点，不会写 Tom config/instances.json，不会修改任何 OpenClaw 实例目录，不会调用 managed-actions live API。

安全确认：
  apply 必须设置：
    CONFIRM_PUSH_REMOTE_COLLECTOR_CREDENTIALS=I_UNDERSTAND_THIS_ONLY_PUSHES_REMOTE_COLLECTOR_CREDENTIALS_TO_TOM_RUNTIME

配置样板：
  ops/local/push-remote-collector-credentials.example.json
TEXT
}

run_node() {
  local mode="$1"
  local config="${2:-$CONFIG_FILE}"
  MODE="$mode" \
    CONFIG_FILE="$config" \
    CONFIRM_PUSH_REMOTE_COLLECTOR_CREDENTIALS="$CONFIRM_PUSH_REMOTE_COLLECTOR_CREDENTIALS" \
    node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const mode = process.env.MODE || "plan";
const configFile = path.resolve(process.env.CONFIG_FILE || "ops/local/push-remote-collector-credentials.example.json");
const confirm = process.env.CONFIRM_PUSH_REMOTE_COLLECTOR_CREDENTIALS || "";
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

function readPort(value, fallback, label) {
  const parsed = Number.parseInt(String(value === undefined ? fallback : value), 10);
  if (!Number.isFinite(parsed) || parsed < 1 || parsed > 65535) throw new Error(`${label} 必须在 1-65535 之间`);
  return parsed;
}

function readJsonFile(file, label) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    throw new Error(`无法读取 ${label}：${file}：${formatError(error)}`);
  }
}

function ensureUnderTomRuntime(file, deployDir, label) {
  const runtimeDir = path.join(deployDir, "runtime");
  const resolved = path.resolve(file);
  const allowedRoot = `${path.resolve(runtimeDir)}${path.sep}`;
  if (!resolved.startsWith(allowedRoot)) {
    throw new Error(`${label} 必须位于 Tom 的 ${runtimeDir} 之下`);
  }
  return resolved;
}

function normalizeConfig(raw) {
  const config = asRecord(raw);
  if (!config) throw new Error("配置必须是 JSON object");
  if (config.schemaVersion !== 1) throw new Error("schemaVersion 必须为 1");

  const tom = asRecord(config.tom);
  if (!tom) throw new Error("tom 必须是 object");
  const tomDeployDir = readAbsolutePath(tom.deployDir || "/srv/openclaw-control-center-readonly", "tom.deployDir");
  const tomConfig = {
    host: readName(tom.host, "tom.host"),
    user: readName(tom.user || "ubuntu", "tom.user"),
    port: readPort(tom.port, 22, "tom.port"),
    sshKey: readOptionalAbsolutePath(tom.sshKey, "tom.sshKey"),
    knownHostsFile: readOptionalAbsolutePath(tom.knownHostsFile, "tom.knownHostsFile"),
    strictHostKeyChecking: readString(tom.strictHostKeyChecking) || "accept-new",
    connectTimeoutSeconds: readPort(tom.connectTimeoutSeconds, 15, "tom.connectTimeoutSeconds"),
    deployDir: tomDeployDir,
  };
  if (!["yes", "accept-new", "no"].includes(tomConfig.strictHostKeyChecking)) {
    throw new Error("tom.strictHostKeyChecking 只能是 yes、accept-new 或 no");
  }

  const server = asRecord(config.server);
  if (!server) throw new Error("server 必须是 object");
  const serverId = readId(server.id, "server.id");
  const serverConfig = {
    id: serverId,
    name: readName(server.name, "server.name"),
    host: readName(server.host, "server.host"),
    ...(readOptionalName(server.region, "server.region") ? { region: readOptionalName(server.region, "server.region") } : {}),
    ...(readOptionalName(server.description, "server.description") ? { description: readOptionalName(server.description, "server.description") } : {}),
  };

  const remote = asRecord(config.remote);
  if (!remote) throw new Error("remote 必须是 object");
  const targetSshKeyPath = ensureUnderTomRuntime(
    readOptionalAbsolutePath(remote.targetSshKeyPath, "remote.targetSshKeyPath") ||
      path.join(tomDeployDir, "runtime", "ssh", `${serverId}-readonly.key`),
    tomDeployDir,
    "remote.targetSshKeyPath",
  );
  const knownHostsFile = ensureUnderTomRuntime(
    readOptionalAbsolutePath(remote.knownHostsFile, "remote.knownHostsFile") ||
      path.join(tomDeployDir, "runtime", "ssh", "known_hosts"),
    tomDeployDir,
    "remote.knownHostsFile",
  );
  const remoteStrictHostKeyChecking = readString(remote.strictHostKeyChecking) || "accept-new";
  if (!["yes", "accept-new", "no"].includes(remoteStrictHostKeyChecking)) {
    throw new Error("remote.strictHostKeyChecking 只能是 yes、accept-new 或 no");
  }
  const remoteConfig = {
    host: readName(remote.host || serverConfig.host, "remote.host"),
    user: readName(remote.user || "ubuntu", "remote.user"),
    port: readPort(remote.port, 22, "remote.port"),
    sourceSshKeyPath: readAbsolutePath(remote.sourceSshKeyPath, "remote.sourceSshKeyPath"),
    targetSshKeyPath,
    knownHostsFile,
    strictHostKeyChecking: remoteStrictHostKeyChecking,
    connectTimeoutSeconds: readPort(remote.connectTimeoutSeconds, 10, "remote.connectTimeoutSeconds"),
    deployDir: readAbsolutePath(remote.deployDir || "/srv/openclaw-collector-node", "remote.deployDir"),
  };

  const collectorNode = asRecord(config.collectorNode) || {};
  const collectorNodeConfig = {
    image: readName(collectorNode.image || "openclaw-control-center:collector-node", "collectorNode.image"),
    bundleBuildContext: readBoolean(collectorNode.bundleBuildContext, true),
    ...(readOptionalAbsolutePath(collectorNode.buildContext, "collectorNode.buildContext") ? {
      buildContext: readOptionalAbsolutePath(collectorNode.buildContext, "collectorNode.buildContext"),
    } : {}),
    collectorContainerName: readName(collectorNode.collectorContainerName || `openclaw-collector-${serverId}`, "collectorNode.collectorContainerName"),
    cronSchedule: readName(collectorNode.cronSchedule || "*/2 * * * *", "collectorNode.cronSchedule"),
  };

  const instanceEntries = Array.isArray(config.instances) ? config.instances : undefined;
  if (!instanceEntries || instanceEntries.length === 0) throw new Error("instances 必须是非空数组");
  const seen = new Set();
  const instances = instanceEntries.map((entry, index) => {
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

  const outputConfigFile = ensureUnderTomRuntime(
    readOptionalAbsolutePath(config.outputConfigFile, "outputConfigFile") ||
      path.join(tomDeployDir, "runtime", "remote-collector-onboarding.json"),
    tomDeployDir,
    "outputConfigFile",
  );

  return {
    tom: tomConfig,
    server: serverConfig,
    remote: remoteConfig,
    collectorNode: collectorNodeConfig,
    instances,
    outputConfigFile,
    overwrite: readBoolean(config.overwrite, false),
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

function sshArgs(tom, command) {
  const args = [
    "-p",
    String(tom.port),
    "-o",
    "BatchMode=yes",
    "-o",
    `ConnectTimeout=${tom.connectTimeoutSeconds}`,
    "-o",
    `StrictHostKeyChecking=${tom.strictHostKeyChecking}`,
  ];
  if (tom.knownHostsFile) args.push("-o", `UserKnownHostsFile=${tom.knownHostsFile}`);
  if (tom.sshKey) args.push("-i", tom.sshKey);
  args.push(`${tom.user}@${tom.host}`, command);
  return args;
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function remoteApplyCommand() {
  const script = `
const fs = require("node:fs");
const path = require("node:path");
const payload = JSON.parse(fs.readFileSync(0, "utf8"));
function fail(message) {
  console.error("[失败] " + message);
  process.exit(2);
}
function writeAtomic(file, text, modeValue) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const tmp = path.join(path.dirname(file), "." + path.basename(file) + "." + process.pid + "." + Date.now() + ".tmp");
  fs.writeFileSync(tmp, text.endsWith("\\n") ? text : text + "\\n", { encoding: "utf8", mode: modeValue });
  fs.chmodSync(tmp, modeValue);
  fs.renameSync(tmp, file);
}
try {
  const runtimeRoot = path.resolve(payload.tomDeployDir, "runtime") + path.sep;
  for (const [label, file] of [["targetSshKeyPath", payload.targetSshKeyPath], ["outputConfigFile", payload.outputConfigFile]]) {
    const resolved = path.resolve(file);
    if (!resolved.startsWith(runtimeRoot)) fail(label + " 必须位于 " + runtimeRoot + " 之下");
    if (!payload.overwrite && fs.existsSync(resolved)) fail(label + " 已存在：" + resolved);
  }
  writeAtomic(payload.targetSshKeyPath, payload.keyText, 0o600);
  writeAtomic(payload.outputConfigFile, JSON.stringify(payload.onboardingConfig, null, 2), 0o600);
  console.log(JSON.stringify({
    status: "applied",
    written: {
      keyFile: payload.targetSshKeyPath,
      onboardingConfigFile: payload.outputConfigFile
    },
    safety: {
      writesControlCenterRuntimeOnly: true,
      connectsSecondOracle: false,
      writesRemoteFiles: false,
      writesActiveRegistry: false,
      mutatesOpenClawInstance: false,
      callsLiveApi: false
    }
  }, null, 2));
} catch (error) {
  fail(error instanceof Error ? error.message : String(error));
}
`;
  return `node -e ${shellQuote(script)}`;
}

function assertApplyReady(config) {
  if (!fs.existsSync(config.remote.sourceSshKeyPath)) {
    throw new Error(`remote.sourceSshKeyPath 不存在：${config.remote.sourceSshKeyPath}`);
  }
  try {
    fs.accessSync(config.remote.sourceSshKeyPath, fs.constants.R_OK);
  } catch {
    throw new Error(`remote.sourceSshKeyPath 不可读：${config.remote.sourceSshKeyPath}`);
  }
  if (config.tom.sshKey && !fs.existsSync(config.tom.sshKey)) {
    throw new Error(`tom.sshKey 不存在：${config.tom.sshKey}`);
  }
}

function applyConfig(config) {
  assertApplyReady(config);
  const keyText = fs.readFileSync(config.remote.sourceSshKeyPath, "utf8");
  const payload = {
    tomDeployDir: config.tom.deployDir,
    targetSshKeyPath: config.remote.targetSshKeyPath,
    outputConfigFile: config.outputConfigFile,
    overwrite: config.overwrite,
    keyText,
    onboardingConfig: buildOnboardingConfig(config),
  };
  const result = spawnSync("ssh", sshArgs(config.tom, remoteApplyCommand()), {
    input: JSON.stringify(payload),
    encoding: "utf8",
    maxBuffer: 4 * 1024 * 1024,
  });
  if (result.status !== 0) {
    throw new Error((result.stderr || result.stdout || `ssh exited with code ${result.status}`).trim());
  }
  return result.stdout.trim() ? JSON.parse(result.stdout) : { status: "applied" };
}

function safety(writes) {
  return {
    writesTomControlCenterRuntimeOnly: writes,
    connectsTomSsh: writes,
    connectsSecondOracle: false,
    writesRemoteCollectorNode: false,
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
  normalized = normalizeConfig(readJsonFile(configFile, "本机推送配置"));
} catch (error) {
  fail(formatError(error));
}

const summary = {
  configFile,
  serverId: normalized.server.id,
  tom: {
    host: normalized.tom.host,
    user: normalized.tom.user,
    port: normalized.tom.port,
    deployDir: normalized.tom.deployDir,
    sshKey: normalized.tom.sshKey,
  },
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
    tomKeyExists: normalized.tom.sshKey ? fs.existsSync(normalized.tom.sshKey) : undefined,
    safety: safety(false),
  }, null, 2));
} else if (mode === "apply") {
  if (confirm !== "I_UNDERSTAND_THIS_ONLY_PUSHES_REMOTE_COLLECTOR_CREDENTIALS_TO_TOM_RUNTIME") {
    fail("必须设置 CONFIRM_PUSH_REMOTE_COLLECTOR_CREDENTIALS=I_UNDERSTAND_THIS_ONLY_PUSHES_REMOTE_COLLECTOR_CREDENTIALS_TO_TOM_RUNTIME");
  }
  let remoteResult;
  try {
    remoteResult = applyConfig(normalized);
  } catch (error) {
    fail(formatError(error));
  }
  console.log(JSON.stringify({
    status: "applied",
    ...summary,
    remoteResult,
    nextActions: [
      `ssh ${normalized.tom.user}@${normalized.tom.host} 'cd ${normalized.tom.deployDir} && repo/ops/tom-readonly/remote-collector-onboarding.sh plan ${normalized.outputConfigFile}'`,
      `ssh ${normalized.tom.user}@${normalized.tom.host} 'cd ${normalized.tom.deployDir} && CONFIRM_REMOTE_COLLECTOR_ONBOARDING=I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_ONBOARDING_BUNDLE repo/ops/tom-readonly/remote-collector-onboarding.sh write ${normalized.outputConfigFile}'`,
      `ssh ${normalized.tom.user}@${normalized.tom.host} 'cd ${normalized.tom.deployDir} && repo/ops/tom-readonly/remote-collector-rollout.sh status runtime/remote-onboarding/${normalized.server.id}'`,
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
      require_command ssh
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
