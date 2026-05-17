#!/usr/bin/env bash
set -euo pipefail
set +x

# 跨服务器只读 collector 接入总控闸门。
# 本脚本只读取 Tom 本地 onboarding、preflight、pull、registry 状态，输出下一步命令。
# 它不 SSH、不写 registry、不写远端文件、不启动容器、不调用 managed-actions live API。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
BUNDLE_DIR="${BUNDLE_DIR:-${DEPLOY_DIR}/runtime/remote-onboarding/remote-oracle}"
REGISTRY_FILE="${REGISTRY_FILE:-${DEPLOY_DIR}/config/instances.json}"
PREFLIGHT_STATE_DIR="${PREFLIGHT_STATE_DIR:-${DEPLOY_DIR}/runtime/remote-preflight-state}"
PULL_STATE_DIR="${PULL_STATE_DIR:-${DEPLOY_DIR}/runtime/collector-pull-state}"

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
  remote-collector-rollout.sh status <bundle-dir>
  remote-collector-rollout.sh plan <bundle-dir>

说明：
  status/plan 只读取 Tom 本地状态并输出跨服务器只读 collector 接入下一步。
  本脚本不 SSH、不写 registry、不写远端文件、不启动容器、不修改任何 OpenClaw 实例目录、不调用 managed-actions live API。

阶段顺序：
  1. onboarding bundle 离线校验
  2. Tom 本地远端 SSH 凭据就绪检查
  3. SSH 只读 preflight 状态
  4. 远端 collector snapshot 只读 pull 状态
  5. Tom registry 注册状态
  6. Tom healthcheck 验收
TEXT
}

run_node() {
  local mode="$1"
  local bundle="${2:-$BUNDLE_DIR}"
  MODE="$mode" \
    DEPLOY_DIR="$DEPLOY_DIR" \
    BUNDLE_DIR="$bundle" \
    REGISTRY_FILE="$REGISTRY_FILE" \
    PREFLIGHT_STATE_DIR="$PREFLIGHT_STATE_DIR" \
    PULL_STATE_DIR="$PULL_STATE_DIR" \
    node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const mode = process.env.MODE || "status";
const deployDir = path.resolve(process.env.DEPLOY_DIR || "/srv/openclaw-control-center-readonly");
const registryFile = path.resolve(process.env.REGISTRY_FILE || path.join(deployDir, "config", "instances.json"));
const preflightStateDir = path.resolve(process.env.PREFLIGHT_STATE_DIR || path.join(deployDir, "runtime", "remote-preflight-state"));
const pullStateDir = path.resolve(process.env.PULL_STATE_DIR || path.join(deployDir, "runtime", "collector-pull-state"));
const runtimeCollectorsDir = path.join(deployDir, "runtime", "collectors");
const bundleDir = resolveBundleDir(process.env.BUNDLE_DIR || path.join(deployDir, "runtime", "remote-onboarding", "remote-oracle"));
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

function readJson(file, label) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    throw new Error(`无法读取 ${label}：${file}：${formatError(error)}`);
  }
}

function readJsonOptional(file) {
  if (!fs.existsSync(file)) return { status: "missing", file };
  try {
    return { status: "present", file, data: JSON.parse(fs.readFileSync(file, "utf8")) };
  } catch (error) {
    return { status: "invalid", file, error: formatError(error) };
  }
}

function resolveBundleDir(value) {
  const text = readString(value);
  if (!text) throw new Error("bundle-dir 必须填写");
  const base = path.join(deployDir, "runtime", "remote-onboarding");
  const resolved = path.resolve(path.isAbsolute(text) ? text : path.join(process.cwd(), text));
  const allowedRoot = `${path.resolve(base)}${path.sep}`;
  if (!resolved.startsWith(allowedRoot)) {
    throw new Error(`bundle-dir 必须位于 ${base} 之下`);
  }
  return resolved;
}

function normalizeLocalSnapshotPath(value, serverId) {
  const raw = readString(value) || path.join(runtimeCollectorsDir, serverId, "snapshot.json");
  const resolved = path.resolve(path.isAbsolute(raw) ? raw : path.join(deployDir, raw));
  const allowedRoot = `${path.resolve(runtimeCollectorsDir)}${path.sep}`;
  if (!resolved.startsWith(allowedRoot)) {
    throw new Error(`localSnapshotPath 必须位于 ${runtimeCollectorsDir} 之下`);
  }
  return resolved;
}

function collectorPathToHostPath(value) {
  const text = readString(value);
  if (!text) throw new Error("collectorSnapshotPath 必须填写");
  if (!text.startsWith("/app/runtime/collectors/")) {
    throw new Error("collectorSnapshotPath 必须位于 /app/runtime/collectors/ 之下");
  }
  return path.join(deployDir, "runtime", text.slice("/app/runtime/".length));
}

function relativeControlPath(file) {
  const resolved = path.resolve(file);
  const root = `${deployDir}${path.sep}`;
  if (resolved.startsWith(root)) return path.relative(deployDir, resolved);
  return resolved;
}

function loadBundle() {
  const requiredFiles = {
    collectorNodeFile: path.join(bundleDir, "collector-node.json"),
    pullConfigFile: path.join(bundleDir, "remote-collector-pull.sources.json"),
    registerConfigFile: path.join(bundleDir, "register-remote-collector.json"),
    safetyFile: path.join(bundleDir, "safety.json"),
    runbookFile: path.join(bundleDir, "RUNBOOK.md"),
    bootstrapFile: path.join(bundleDir, "bootstrap-collector-node.sh"),
  };
  const missingFiles = Object.values(requiredFiles).filter((file) => !fs.existsSync(file));
  if (missingFiles.length > 0) {
    return {
      status: "invalid",
      bundleDir,
      error: `接入包缺少文件：${missingFiles.map(relativeControlPath).join(", ")}`,
      requiredFiles,
      missingFiles,
    };
  }

  const collectorNode = readJson(requiredFiles.collectorNodeFile, "collector-node.json");
  const pullConfig = readJson(requiredFiles.pullConfigFile, "remote-collector-pull.sources.json");
  const registerConfig = readJson(requiredFiles.registerConfigFile, "register-remote-collector.json");
  const safety = readJson(requiredFiles.safetyFile, "safety.json");

  if (!asRecord(collectorNode) || collectorNode.schemaVersion !== 1) throw new Error("collector-node.json schemaVersion 必须为 1");
  if (!asRecord(pullConfig) || pullConfig.schemaVersion !== 1) throw new Error("remote-collector-pull.sources.json schemaVersion 必须为 1");
  if (!asRecord(registerConfig) || registerConfig.schemaVersion !== 1) throw new Error("register-remote-collector.json schemaVersion 必须为 1");
  if (!asRecord(safety)) throw new Error("safety.json 必须是 object");

  const serverId = readId(asRecord(collectorNode.server)?.id, "collectorNode.server.id");
  const serverName = readString(asRecord(collectorNode.server)?.name) || serverId;
  const source = Array.isArray(pullConfig.sources) ? asRecord(pullConfig.sources[0]) : undefined;
  if (!source) throw new Error("remote-collector-pull.sources.json 必须包含 sources[0]");
  if (source.serverId !== serverId) throw new Error("pull source serverId 与 collector-node 不一致");
  const registerServer = asRecord(registerConfig.server);
  if (readId(registerServer?.id, "register.server.id") !== serverId) {
    throw new Error("register serverId 与 collector-node 不一致");
  }
  const localSnapshotPath = normalizeLocalSnapshotPath(source.localSnapshotPath, serverId);
  const hostSnapshotPath = collectorPathToHostPath(registerConfig.collectorSnapshotPath);
  if (path.resolve(hostSnapshotPath) !== path.resolve(localSnapshotPath)) {
    throw new Error("pull localSnapshotPath 与 register collectorSnapshotPath 指向不一致");
  }

  const instances = Array.isArray(registerConfig.instances) ? registerConfig.instances.map((entry, index) => {
    const item = asRecord(entry);
    if (!item) throw new Error(`register.instances[${index}] 必须是 object`);
    return {
      id: readId(item.id, `register.instances[${index}].id`),
      name: readString(item.name) || String(item.id),
    };
  }) : [];
  if (instances.length === 0) throw new Error("register.instances 必须是非空数组");

  const unsafe = [];
  const expectedFalse = [
    "writesActiveRegistry",
    "connectsSsh",
    "mutatesOpenClawInstance",
    "callsLiveApi",
  ];
  for (const key of expectedFalse) {
    if (safety[key] !== false) unsafe.push(`safety.${key} 必须为 false`);
  }

  return {
    status: unsafe.length > 0 ? "unsafe" : "valid",
    serverId,
    serverName,
    bundleDir,
    requiredFiles,
    unsafe,
    source: {
      host: source.host,
      user: source.user || "ubuntu",
      port: source.port || 22,
      enabled: source.enabled !== false,
      sshKey: readString(source.sshKey),
      knownHostsFile: readString(source.knownHostsFile),
      remoteSnapshotPath: source.remoteSnapshotPath,
      localSnapshotPath,
      configFile: requiredFiles.pullConfigFile,
    },
    registration: {
      configFile: requiredFiles.registerConfigFile,
      collectorSnapshotPath: registerConfig.collectorSnapshotPath,
      hostSnapshotPath,
      server: {
        id: serverId,
        name: readString(registerServer?.name) || serverName,
        host: readString(registerServer?.host),
        region: readString(registerServer?.region),
      },
      instances,
    },
    safety: {
      writesActiveRegistry: safety.writesActiveRegistry,
      connectsSsh: safety.connectsSsh,
      mutatesOpenClawInstance: safety.mutatesOpenClawInstance,
      callsLiveApi: safety.callsLiveApi,
      bundlesBuildContext: safety.bundlesBuildContext === true,
    },
  };
}

function readRemoteAccess(bundle) {
  const issues = [];
  const source = bundle.source || {};
  const sshKey = readString(source.sshKey);
  if (source.enabled !== true) {
    issues.push("remote-collector-pull.sources.json 中 source.enabled 必须为 true");
  }
  if (!readString(source.host)) {
    issues.push("远端 host 必须填写真实 Oracle 地址");
  }
  if (!readString(source.user)) {
    issues.push("远端 user 必须填写");
  }
  if (sshKey) {
    if (!path.isAbsolute(sshKey)) {
      issues.push("sshKey 必须是 Tom 上的绝对路径");
    } else if (!fs.existsSync(sshKey)) {
      issues.push(`Tom 上缺少远端只读 SSH key：${sshKey}`);
    } else {
      try {
        fs.accessSync(sshKey, fs.constants.R_OK);
      } catch {
        issues.push(`Tom 无法读取远端只读 SSH key：${sshKey}`);
      }
    }
  }
  const knownHostsFile = readString(source.knownHostsFile);
  if (knownHostsFile && !path.isAbsolute(knownHostsFile)) {
    issues.push("knownHostsFile 必须是 Tom 上的绝对路径");
  }
  return {
    status: issues.length > 0 ? "blocked" : "ready",
    acceptable: issues.length === 0,
    host: source.host,
    user: source.user,
    port: source.port,
    sshKey: sshKey ? { path: sshKey, exists: fs.existsSync(sshKey) } : { path: "", exists: false, optional: true },
    knownHostsFile: knownHostsFile || "",
    issues,
  };
}

function readPreflight(bundle) {
  const file = path.join(preflightStateDir, `${bundle.serverId}.json`);
  const state = readJsonOptional(file);
  if (state.status !== "present") return state;
  const data = asRecord(state.data);
  if (!data) return { status: "invalid", file, error: "state 必须是 object" };
  const stale = data.bundleDir && path.resolve(String(data.bundleDir)) !== path.resolve(bundle.bundleDir);
  const acceptable = data.status === "ready" || data.status === "warning";
  return {
    status: data.status || "unknown",
    acceptable: acceptable && !stale,
    stale: Boolean(stale),
    checkedAt: data.checkedAt,
    updatedAt: data.updatedAt,
    results: Array.isArray(data.results) ? data.results.length : undefined,
    file,
  };
}

function readPull(bundle) {
  const file = path.join(pullStateDir, `${bundle.serverId}.json`);
  const state = readJsonOptional(file);
  if (state.status !== "present") return state;
  const data = asRecord(state.data);
  if (!data) return { status: "invalid", file, error: "state 必须是 object" };
  const source = asRecord(data.source);
  const stalePath = source?.localSnapshotPath && path.resolve(String(source.localSnapshotPath)) !== path.resolve(bundle.source.localSnapshotPath);
  return {
    status: data.status || "unknown",
    acceptable: data.status === "pulled" && !stalePath,
    stalePath: Boolean(stalePath),
    updatedAt: data.updatedAt,
    pulledAt: data.pulledAt,
    generatedAt: data.generatedAt,
    instances: data.instances,
    error: data.error,
    file,
  };
}

function readSnapshot(bundle) {
  const file = bundle.source.localSnapshotPath;
  if (!fs.existsSync(file)) return { status: "missing", file };
  try {
    const snapshot = JSON.parse(fs.readFileSync(file, "utf8"));
    if (!asRecord(snapshot)) throw new Error("snapshot 必须是 object");
    if (snapshot.schemaVersion !== 1) throw new Error("snapshot schemaVersion 必须为 1");
    if (snapshot.serverId !== bundle.serverId) {
      throw new Error(`snapshot serverId 不匹配：expected=${bundle.serverId} actual=${snapshot.serverId}`);
    }
    if (!Array.isArray(snapshot.instances) || snapshot.instances.length === 0) {
      throw new Error("snapshot instances 必须是非空数组");
    }
    return {
      status: "valid",
      file,
      generatedAt: snapshot.generatedAt,
      instances: snapshot.instances.length,
    };
  } catch (error) {
    return { status: "invalid", file, error: formatError(error) };
  }
}

function readRegistry(bundle) {
  const state = readJsonOptional(registryFile);
  if (state.status !== "present") return state;
  const registry = asRecord(state.data);
  const servers = Array.isArray(registry?.servers) ? registry.servers : undefined;
  if (!servers) return { status: "invalid", file: registryFile, error: "registry 必须包含 servers 数组" };
  const server = servers.map(asRecord).find((item) => item?.id === bundle.serverId);
  if (!server) return { status: "missing_server", file: registryFile };
  const expectedSnapshotPath = bundle.registration.collectorSnapshotPath;
  const snapshotMatches = server.collectorSnapshotPath === expectedSnapshotPath;
  const entries = Array.isArray(server.instances) ? server.instances.map(asRecord) : [];
  const instanceIds = new Set(entries.map((item) => readString(item?.id)).filter(Boolean));
  const missingInstances = bundle.registration.instances.map((item) => item.id).filter((id) => !instanceIds.has(id));
  return {
    status: snapshotMatches && missingInstances.length === 0 ? "registered" : "mismatch",
    file: registryFile,
    collectorSnapshotPath: server.collectorSnapshotPath,
    expectedCollectorSnapshotPath: expectedSnapshotPath,
    instances: entries.length,
    missingInstances,
  };
}

function buildCommands(bundle, stage) {
  const bundlePath = relativeControlPath(bundle.bundleDir);
  if (stage === "needs_onboarding_verify") {
    return [
      `repo/ops/tom-readonly/remote-collector-onboarding.sh verify ${bundlePath}`,
    ];
  }
  if (stage === "needs_remote_preflight") {
    return [
      `repo/ops/tom-readonly/remote-collector-preflight.sh plan ${bundlePath}`,
      `CONFIRM_REMOTE_COLLECTOR_PREFLIGHT=I_UNDERSTAND_THIS_ONLY_READS_REMOTE_PREREQUISITES repo/ops/tom-readonly/remote-collector-preflight.sh check ${bundlePath}`,
    ];
  }
  if (stage === "needs_remote_credentials") {
    return [
      "# 如果远端只读 SSH key 在本机：先在本机把真实第二台 Oracle 的 host/user/port/sourceSshKeyPath 写入 push 配置",
      "cp ops/local/push-remote-collector-credentials.example.json runtime/push-remote-collector-credentials.json",
      "ops/local/push-remote-collector-credentials.sh plan runtime/push-remote-collector-credentials.json",
      "CONFIRM_PUSH_REMOTE_COLLECTOR_CREDENTIALS=I_UNDERSTAND_THIS_ONLY_PUSHES_REMOTE_COLLECTOR_CREDENTIALS_TO_TOM_RUNTIME ops/local/push-remote-collector-credentials.sh apply runtime/push-remote-collector-credentials.json",
      "# 如果远端只读 SSH key 已在 Tom 上：走 Tom 端 credentials 配置",
      "cp repo/ops/tom-readonly/remote-collector-credentials.example.json runtime/remote-collector-credentials.json",
      "repo/ops/tom-readonly/remote-collector-credentials.sh plan runtime/remote-collector-credentials.json",
      "CONFIRM_REMOTE_COLLECTOR_CREDENTIALS=I_UNDERSTAND_THIS_ONLY_WRITES_CONTROL_CENTER_REMOTE_CREDENTIALS repo/ops/tom-readonly/remote-collector-credentials.sh apply runtime/remote-collector-credentials.json",
      "repo/ops/tom-readonly/remote-collector-onboarding.sh plan runtime/remote-collector-onboarding.json",
      `CONFIRM_REMOTE_COLLECTOR_ONBOARDING=I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_ONBOARDING_BUNDLE repo/ops/tom-readonly/remote-collector-onboarding.sh write runtime/remote-collector-onboarding.json`,
      `repo/ops/tom-readonly/remote-collector-onboarding.sh verify ${bundlePath}`,
    ];
  }
  if (stage === "needs_remote_collector_pull") {
    const pullConfig = relativeControlPath(bundle.source.configFile);
    return [
      `# 先按 ${bundlePath}/RUNBOOK.md 在远端生成 collector snapshot`,
      `repo/ops/tom-readonly/remote-collector-pull.sh plan ${pullConfig}`,
      `CONFIRM_REMOTE_COLLECTOR_PULL=I_UNDERSTAND_THIS_ONLY_READS_REMOTE_COLLECTOR_SNAPSHOTS repo/ops/tom-readonly/remote-collector-pull.sh pull ${pullConfig}`,
    ];
  }
  if (stage === "needs_registry_register") {
    const registerConfig = relativeControlPath(bundle.registration.configFile);
    return [
      `repo/ops/tom-readonly/register-remote-collector.sh plan ${registerConfig}`,
      `CONFIRM_REMOTE_COLLECTOR_REGISTER=I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_REGISTRY repo/ops/tom-readonly/register-remote-collector.sh apply ${registerConfig}`,
    ];
  }
  if (stage === "ready_for_healthcheck") {
    return ["./healthcheck.sh"];
  }
  return [];
}

function decide(bundle, remoteAccess, preflight, pull, snapshot, registry) {
  if (bundle.status !== "valid") return "needs_onboarding_verify";
  if (!remoteAccess.acceptable) return "needs_remote_credentials";
  if (!preflight.acceptable) return "needs_remote_preflight";
  if (!pull.acceptable || snapshot.status !== "valid") return "needs_remote_collector_pull";
  if (registry.status !== "registered") return "needs_registry_register";
  return "ready_for_healthcheck";
}

function safety() {
  return {
    statusOnly: true,
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

let bundle;
try {
  bundle = loadBundle();
} catch (error) {
  fail(formatError(error));
}

const remoteAccess = bundle.status === "valid" ? readRemoteAccess(bundle) : { status: "skipped_invalid_bundle" };
const preflight = bundle.status === "valid" ? readPreflight(bundle) : { status: "skipped_invalid_bundle" };
const pull = bundle.status === "valid" ? readPull(bundle) : { status: "skipped_invalid_bundle" };
const snapshot = bundle.status === "valid" ? readSnapshot(bundle) : { status: "skipped_invalid_bundle" };
const registry = bundle.status === "valid" ? readRegistry(bundle) : { status: "skipped_invalid_bundle" };
const stage = decide(bundle, remoteAccess, preflight, pull, snapshot, registry);
const outputStatus = stage === "ready_for_healthcheck" ? "ready" : "blocked";

console.log(JSON.stringify({
  status: outputStatus,
  mode,
  stage,
  bundleDir,
  serverId: bundle.serverId,
  serverName: bundle.serverName,
  evidence: {
    bundle: {
      status: bundle.status,
      unsafe: bundle.unsafe || [],
      files: bundle.requiredFiles ? Object.fromEntries(Object.entries(bundle.requiredFiles).map(([key, file]) => [key, relativeControlPath(file)])) : undefined,
      safety: bundle.safety,
    },
    remoteAccess,
    preflight,
    pull,
    snapshot,
    registry,
  },
  nextCommands: buildCommands(bundle, stage),
  safety: safety(),
}, null, 2));
NODE
}

main() {
  require_command node
  case "${1:-status}" in
    status|plan)
      run_node "${1:-status}" "${2:-$BUNDLE_DIR}"
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
