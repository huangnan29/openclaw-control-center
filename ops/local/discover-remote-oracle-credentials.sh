#!/usr/bin/env bash
set -euo pipefail
set +x

# 本机远端 Oracle 只读凭据候选发现工具。
# scan 只读取本机 SSH 配置和候选 key 文件元数据，不联网、不写文件。
# probe 必须显式确认，只用 SSH 执行只读探测命令，不写远端文件、不写 Tom runtime、不修改任何 OpenClaw 实例目录。

CONFIG_FILE="${CONFIG_FILE:-ops/local/discover-remote-oracle-credentials.example.json}"
CONFIRM_REMOTE_ORACLE_DISCOVERY="${CONFIRM_REMOTE_ORACLE_DISCOVERY:-}"

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
  discover-remote-oracle-credentials.sh scan [config.json]
  discover-remote-oracle-credentials.sh probe [config.json]
  discover-remote-oracle-credentials.sh render-push-config [config.json]

说明：
  scan 只读取本机 SSH config 和候选 key 文件元数据，不联网、不写文件、不输出私钥内容。
  probe 会对候选 host/key 组合执行 SSH 只读探测命令：
    id -un / uname -n / uname -s
  render-push-config 只根据 REMOTE_ORACLE_HOST 和 REMOTE_ORACLE_KEY_PATH 输出 push 配置 JSON，不写文件、不联网。

安全确认：
  probe 必须设置：
    CONFIRM_REMOTE_ORACLE_DISCOVERY=I_UNDERSTAND_THIS_ONLY_PROBES_SSH_READONLY

配置样板：
  ops/local/discover-remote-oracle-credentials.example.json
TEXT
}

run_node() {
  local mode="$1"
  local config="${2:-$CONFIG_FILE}"
  MODE="$mode" \
    CONFIG_FILE="$config" \
    CONFIRM_REMOTE_ORACLE_DISCOVERY="$CONFIRM_REMOTE_ORACLE_DISCOVERY" \
    node <<'NODE'
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const mode = process.env.MODE || "scan";
const configFile = path.resolve(process.env.CONFIG_FILE || "ops/local/discover-remote-oracle-credentials.example.json");
const confirm = process.env.CONFIRM_REMOTE_ORACLE_DISCOVERY || "";
const selectedHostFromEnv = readString(process.env.REMOTE_ORACLE_HOST);
const selectedKeyFromEnv = readString(process.env.REMOTE_ORACLE_KEY_PATH);
const selectedUserFromEnv = readString(process.env.REMOTE_ORACLE_USER);
const selectedPortFromEnv = readString(process.env.REMOTE_ORACLE_PORT);

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

function readArray(value) {
  return Array.isArray(value) ? value : [];
}

function readInt(value, fallback, label) {
  if (value === undefined) return fallback;
  const parsed = Number.parseInt(String(value), 10);
  if (!Number.isFinite(parsed) || parsed < 1 || parsed > 65535) throw new Error(`${label} 必须在 1-65535 之间`);
  return parsed;
}

function readOptionalInt(value, label) {
  if (value === undefined || value === "") return undefined;
  return readInt(value, 0, label);
}

function readJsonFile(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    throw new Error(`无法读取配置：${file}：${formatError(error)}`);
  }
}

function expandHome(value) {
  const text = readString(value);
  if (!text) return "";
  if (text === "~") return os.homedir();
  if (text.startsWith("~/")) return path.join(os.homedir(), text.slice(2));
  return text;
}

function normalizeConfig(raw) {
  const config = asRecord(raw);
  if (!config) throw new Error("配置必须是 JSON object");
  if (config.schemaVersion !== 1) throw new Error("schemaVersion 必须为 1");
  const tom = asRecord(config.tom) || {};
  const scan = asRecord(config.scan) || {};
  const server = asRecord(config.server) || {};
  const remote = asRecord(config.remote) || {};
  const collectorNode = asRecord(config.collectorNode) || {};
  const render = asRecord(config.render) || {};
  const excludeHosts = new Set([
    "127.0.0.1",
    "localhost",
    "::1",
    readString(tom.host),
    ...readArray(scan.excludeHosts).map(readString),
  ].filter(Boolean));
  const envHosts = (process.env.REMOTE_ORACLE_HOSTS || "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
  const envHintFiles = (process.env.REMOTE_ORACLE_HOST_HINT_FILES || "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
  const hostHints = [
    ...readArray(scan.hostHints).map(readString).filter(Boolean),
    ...envHosts,
  ];
  const tomDeployDir = readString(tom.deployDir) || "/srv/openclaw-control-center-readonly";
  const serverId = readString(server.id) || "remote-oracle";
  return {
    tom: {
      host: readString(tom.host) || "",
      user: readString(tom.user) || "ubuntu",
      port: readInt(tom.port, 22, "tom.port"),
      sshKey: expandHome(tom.sshKey),
      deployDir: tomDeployDir,
      strictHostKeyChecking: readString(tom.strictHostKeyChecking) || "accept-new",
    },
    server: {
      id: serverId,
      name: readString(server.name) || "Remote Oracle",
      region: readString(server.region) || "oracle-us",
      description: readString(server.description) || "第二台 Oracle 只读 collector 节点",
    },
    remote: {
      targetSshKeyPath: readString(remote.targetSshKeyPath) || path.join(tomDeployDir, "runtime", "ssh", `${serverId}-readonly.key`),
      knownHostsFile: readString(remote.knownHostsFile) || path.join(tomDeployDir, "runtime", "ssh", "known_hosts"),
      strictHostKeyChecking: readString(remote.strictHostKeyChecking) || "accept-new",
      connectTimeoutSeconds: readInt(remote.connectTimeoutSeconds, 10, "remote.connectTimeoutSeconds"),
      deployDir: readString(remote.deployDir) || "/srv/openclaw-collector-node",
    },
    collectorNode: {
      image: readString(collectorNode.image) || "openclaw-control-center:collector-node",
      bundleBuildContext: collectorNode.bundleBuildContext !== false,
      collectorContainerName: readString(collectorNode.collectorContainerName) || `openclaw-collector-${serverId}`,
      cronSchedule: readString(collectorNode.cronSchedule) || "*/2 * * * *",
    },
    instances: normalizeInstances(config.instances),
    render: {
      host: readString(render.host),
      user: readString(render.user),
      port: readOptionalInt(render.port, "render.port"),
      sourceSshKeyPath: expandHome(render.sourceSshKeyPath),
    },
    scan: {
      sshConfigFiles: readArray(scan.sshConfigFiles).map(expandHome).filter(Boolean),
      hostHintFiles: [
        ...readArray(scan.hostHintFiles).map(expandHome).filter(Boolean),
        ...envHintFiles.map(expandHome).filter(Boolean),
      ],
      keyGlobs: readArray(scan.keyGlobs).map(expandHome).filter(Boolean),
      excludeHosts,
      hostHints,
      defaultUser: readString(scan.defaultUser) || "ubuntu",
      defaultPort: readInt(scan.defaultPort, 22, "scan.defaultPort"),
      connectTimeoutSeconds: readInt(scan.connectTimeoutSeconds, 5, "scan.connectTimeoutSeconds"),
      maxProbeCombinations: readInt(scan.maxProbeCombinations, 20, "scan.maxProbeCombinations"),
    },
  };
}

function normalizeInstances(value) {
  const entries = Array.isArray(value) && value.length > 0 ? value : [
    {
      id: "remote-main",
      name: "Remote Main",
      gatewayUrl: "ws://host.docker.internal:18789",
      configDir: "/srv/openclaw/config",
      workspaceDir: "/srv/openclaw/workspace",
    },
  ];
  return entries.map((entry, index) => {
    const item = asRecord(entry);
    if (!item) throw new Error(`instances[${index}] 必须是 object`);
    return {
      id: readString(item.id) || `remote-${index + 1}`,
      name: readString(item.name) || readString(item.id) || `Remote ${index + 1}`,
      gatewayUrl: readString(item.gatewayUrl) || "ws://host.docker.internal:18789",
      configDir: readString(item.configDir) || "/srv/openclaw/config",
      workspaceDir: readString(item.workspaceDir) || "/srv/openclaw/workspace",
      ...(readString(item.codexDir) ? { codexDir: readString(item.codexDir) } : {}),
    };
  });
}

function parseSshConfigFile(file) {
  if (!fs.existsSync(file)) return [];
  const text = fs.readFileSync(file, "utf8");
  const entries = [];
  let current = undefined;
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.replace(/#.*/, "").trim();
    if (!line) continue;
    const [rawKey, ...rest] = line.split(/\s+/);
    const key = rawKey.toLowerCase();
    const value = rest.join(" ").trim();
    if (key === "host") {
      if (current) entries.push(current);
      current = { sourceFile: file, aliases: value.split(/\s+/).filter(Boolean) };
      continue;
    }
    if (!current) continue;
    if (key === "hostname") current.hostName = value;
    if (key === "user") current.user = value;
    if (key === "port") current.port = Number.parseInt(value, 10);
    if (key === "identityfile") {
      current.identityFiles = current.identityFiles || [];
      current.identityFiles.push(expandHome(value.replace(/^"|"$/g, "")));
    }
  }
  if (current) entries.push(current);
  return entries.filter((entry) => !entry.aliases.some((alias) => alias.includes("*") || alias.includes("?")));
}

function expandSimpleGlob(pattern) {
  const resolved = expandHome(pattern);
  if (!resolved.includes("*")) return fs.existsSync(resolved) ? [resolved] : [];
  const dir = path.dirname(resolved);
  const base = path.basename(resolved);
  if (!fs.existsSync(dir)) return [];
  const [prefix, suffix] = base.split("*", 2);
  return fs.readdirSync(dir)
    .filter((name) => name.startsWith(prefix) && name.endsWith(suffix || ""))
    .map((name) => path.join(dir, name));
}

function isLikelyPrivateKey(file) {
  const name = path.basename(file);
  if (name.endsWith(".pub")) return false;
  if (["config", "known_hosts", "authorized_keys"].includes(name)) return false;
  try {
    const stat = fs.statSync(file);
    if (!stat.isFile()) return false;
    const head = fs.readFileSync(file, { encoding: "utf8" }).slice(0, 200);
    return head.includes("PRIVATE KEY") || name.endsWith(".key") || name.startsWith("id_");
  } catch {
    return false;
  }
}

function keyMetadata(file, sources) {
  const stat = fs.statSync(file);
  const mode = (stat.mode & 0o777).toString(8).padStart(3, "0");
  return {
    path: file,
    exists: true,
    mode,
    tooOpen: (stat.mode & 0o077) !== 0,
    sizeBytes: stat.size,
    sources: Array.from(sources).sort(),
  };
}

function discover(config) {
  const sshEntries = config.scan.sshConfigFiles.flatMap(parseSshConfigFile);
  const fileHostHints = config.scan.hostHintFiles.flatMap(readHostHintsFromFile);
  const hostMap = new Map();
  for (const hint of config.scan.hostHints) {
    addHost(hostMap, {
      host: hint,
      user: config.scan.defaultUser,
      port: config.scan.defaultPort,
      source: "hostHint",
      identityFiles: [],
      aliases: [],
    }, config);
  }
  for (const hint of fileHostHints) {
    addHost(hostMap, {
      host: hint.host,
      user: config.scan.defaultUser,
      port: config.scan.defaultPort,
      source: `hostHintFile:${hint.file}`,
      identityFiles: [],
      aliases: [],
    }, config);
  }
  for (const entry of sshEntries) {
    const host = readString(entry.hostName) || entry.aliases[0];
    addHost(hostMap, {
      host,
      user: readString(entry.user) || config.scan.defaultUser,
      port: Number.isFinite(entry.port) ? entry.port : config.scan.defaultPort,
      source: `sshConfig:${entry.sourceFile}`,
      identityFiles: entry.identityFiles || [],
      aliases: entry.aliases,
    }, config);
  }

  const keySources = new Map();
  for (const pattern of config.scan.keyGlobs) {
    for (const file of expandSimpleGlob(pattern)) {
      if (!isLikelyPrivateKey(file)) continue;
      addKeySource(keySources, path.resolve(file), `glob:${pattern}`);
    }
  }
  for (const entry of sshEntries) {
    for (const file of entry.identityFiles || []) {
      if (fs.existsSync(file) && isLikelyPrivateKey(file)) {
        addKeySource(keySources, path.resolve(file), `sshConfig:${entry.sourceFile}`);
      }
    }
  }

  const hosts = Array.from(hostMap.values()).sort((a, b) => a.host.localeCompare(b.host));
  const keys = Array.from(keySources.entries())
    .map(([file, sources]) => keyMetadata(file, sources))
    .sort((a, b) => a.path.localeCompare(b.path));
  const probePlan = buildProbePlan(hosts, keys, config.scan.maxProbeCombinations);
  return { sshEntries, hosts, keys, probePlan };
}

function readHostHintsFromFile(filePattern) {
  const files = expandSimpleGlob(filePattern);
  const hints = [];
  for (const file of files) {
    try {
      const stat = fs.statSync(file);
      if (!stat.isFile() || stat.size > 2 * 1024 * 1024) continue;
      const text = fs.readFileSync(file, "utf8");
      const matches = text.match(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g) || [];
      for (const host of matches) {
        if (isPublicIpv4(host)) hints.push({ host, file });
      }
    } catch {
      // 忽略无法读取的候选文件，scan 保持只读且不中断。
    }
  }
  return uniqueBy(hints, (item) => `${item.host}|${item.file}`);
}

function isPublicIpv4(value) {
  const parts = value.split(".").map((item) => Number.parseInt(item, 10));
  if (parts.length !== 4 || parts.some((part) => !Number.isFinite(part) || part < 0 || part > 255)) return false;
  const [a, b] = parts;
  if (a === 0 || a === 10 || a === 127 || a >= 224) return false;
  if (a === 169 && b === 254) return false;
  if (a === 172 && b >= 16 && b <= 31) return false;
  if (a === 192 && b === 168) return false;
  if (a === 100 && b >= 64 && b <= 127) return false;
  if (a === 192 && b === 0 && parts[2] === 2) return false;
  if (a === 198 && b === 51 && parts[2] === 100) return false;
  if (a === 203 && b === 0 && parts[2] === 113) return false;
  return true;
}

function uniqueBy(items, keyFn) {
  const seen = new Set();
  const result = [];
  for (const item of items) {
    const key = keyFn(item);
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(item);
  }
  return result;
}

function addHost(hostMap, raw, config) {
  const host = readString(raw.host);
  if (!host || config.scan.excludeHosts.has(host)) return;
  const existing = hostMap.get(host) || {
    host,
    user: raw.user || config.scan.defaultUser,
    port: raw.port || config.scan.defaultPort,
    aliases: [],
    identityFiles: [],
    sources: [],
  };
  existing.user = existing.user || raw.user || config.scan.defaultUser;
  existing.port = existing.port || raw.port || config.scan.defaultPort;
  existing.aliases.push(...(raw.aliases || []));
  existing.identityFiles.push(...(raw.identityFiles || []));
  existing.sources.push(raw.source);
  existing.aliases = Array.from(new Set(existing.aliases)).filter(Boolean);
  existing.identityFiles = Array.from(new Set(existing.identityFiles.map((file) => path.resolve(file)))).filter(Boolean);
  existing.sources = Array.from(new Set(existing.sources)).filter(Boolean);
  hostMap.set(host, existing);
}

function addKeySource(keySources, file, source) {
  const set = keySources.get(file) || new Set();
  set.add(source);
  keySources.set(file, set);
}

function buildProbePlan(hosts, keys, max) {
  const planned = [];
  for (const host of hosts) {
    const preferred = host.identityFiles.filter((file) => keys.some((key) => key.path === file));
    const candidateKeys = preferred.length > 0 ? preferred : keys.map((key) => key.path);
    for (const keyPath of candidateKeys) {
      if (planned.length >= max) return planned;
      planned.push({
        host: host.host,
        user: host.user,
        port: host.port,
        keyPath,
        hostSources: host.sources,
      });
    }
  }
  return planned;
}

function probeCandidates(plan, timeoutSeconds) {
  return plan.map((candidate) => {
    const args = [
      "-i",
      candidate.keyPath,
      "-p",
      String(candidate.port),
      "-o",
      "BatchMode=yes",
      "-o",
      `ConnectTimeout=${timeoutSeconds}`,
      "-o",
      "StrictHostKeyChecking=no",
      "-o",
      "UserKnownHostsFile=/dev/null",
      `${candidate.user}@${candidate.host}`,
      "printf 'user=%s host=%s uname=%s\\n' \"$(id -un 2>/dev/null || true)\" \"$(uname -n 2>/dev/null || true)\" \"$(uname -s 2>/dev/null || true)\"",
    ];
    const result = spawnSync("ssh", args, {
      encoding: "utf8",
      maxBuffer: 512 * 1024,
    });
    return {
      ...candidate,
      status: result.status === 0 ? "reachable" : "unreachable",
      exitCode: result.status,
      detail: (result.stdout || result.stderr || "").trim().slice(0, 1000),
    };
  });
}

function nextCommands(discovery, mode) {
  const commands = [];
  if (mode === "scan" && discovery.hosts.length > 0 && discovery.keys.length > 0) {
    commands.push("CONFIRM_REMOTE_ORACLE_DISCOVERY=I_UNDERSTAND_THIS_ONLY_PROBES_SSH_READONLY ops/local/discover-remote-oracle-credentials.sh probe ops/local/discover-remote-oracle-credentials.example.json");
    commands.push("REMOTE_ORACLE_HOST=<可达候选 host> REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> ops/local/discover-remote-oracle-credentials.sh render-push-config ops/local/discover-remote-oracle-credentials.example.json > runtime/push-remote-collector-credentials.json");
  } else {
    commands.push("cp ops/local/push-remote-collector-credentials.example.json runtime/push-remote-collector-credentials.json");
    commands.push("# 将可达候选的 host/user/port/keyPath 填入 runtime/push-remote-collector-credentials.json 的 remote.host、remote.user、remote.port、remote.sourceSshKeyPath");
  }
  commands.push("ops/local/push-remote-collector-credentials.sh plan runtime/push-remote-collector-credentials.json");
  commands.push("CONFIRM_PUSH_REMOTE_COLLECTOR_CREDENTIALS=I_UNDERSTAND_THIS_ONLY_PUSHES_REMOTE_COLLECTOR_CREDENTIALS_TO_TOM_RUNTIME ops/local/push-remote-collector-credentials.sh apply runtime/push-remote-collector-credentials.json");
  return commands;
}

function selectForRender(config, discovery) {
  const envHosts = (process.env.REMOTE_ORACLE_HOSTS || "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
  const host = selectedHostFromEnv || config.render.host || (envHosts.length === 1 ? envHosts[0] : undefined);
  const keyPath = selectedKeyFromEnv || config.render.sourceSshKeyPath;
  const user = selectedUserFromEnv || config.render.user || config.scan.defaultUser;
  const port = readOptionalInt(selectedPortFromEnv, "REMOTE_ORACLE_PORT") || config.render.port || config.scan.defaultPort;
  if (!host) throw new Error("render-push-config 必须通过 REMOTE_ORACLE_HOST 或 render.host 指定 host");
  if (!keyPath) {
    if (discovery.keys.length === 1) {
      return { host, user, port, keyPath: discovery.keys[0].path };
    }
    throw new Error("render-push-config 必须通过 REMOTE_ORACLE_KEY_PATH 或 render.sourceSshKeyPath 指定 key；当前候选 key 不唯一");
  }
  const resolvedKey = path.resolve(expandHome(keyPath));
  if (!fs.existsSync(resolvedKey)) throw new Error(`REMOTE_ORACLE_KEY_PATH 不存在：${resolvedKey}`);
  return { host, user, port, keyPath: resolvedKey };
}

function buildPushConfig(config, selected) {
  return {
    schemaVersion: 1,
    tom: {
      host: config.tom.host,
      user: config.tom.user,
      port: config.tom.port,
      ...(config.tom.sshKey ? { sshKey: config.tom.sshKey } : {}),
      deployDir: config.tom.deployDir,
      strictHostKeyChecking: config.tom.strictHostKeyChecking,
    },
    server: {
      ...config.server,
      host: selected.host,
    },
    remote: {
      host: selected.host,
      user: selected.user,
      port: selected.port,
      sourceSshKeyPath: selected.keyPath,
      targetSshKeyPath: config.remote.targetSshKeyPath,
      knownHostsFile: config.remote.knownHostsFile,
      strictHostKeyChecking: config.remote.strictHostKeyChecking,
      connectTimeoutSeconds: config.remote.connectTimeoutSeconds,
      deployDir: config.remote.deployDir,
    },
    collectorNode: config.collectorNode,
    instances: config.instances,
    outputConfigFile: path.join(config.tom.deployDir, "runtime", "remote-collector-onboarding.json"),
    overwrite: false,
  };
}

function statusFor(discovery, probes) {
  if (probes?.some((item) => item.status === "reachable")) return "reachable_candidate_found";
  if (discovery.hosts.length === 0) return "needs_remote_host";
  if (discovery.keys.length === 0) return "needs_source_ssh_key";
  if (discovery.probePlan.length === 0) return "needs_probe_candidate";
  return probes ? "no_reachable_candidate" : "candidates_found";
}

function formatError(error) {
  return error instanceof Error ? error.message : String(error);
}

let config;
let discovery;
try {
  config = normalizeConfig(readJsonFile(configFile));
  discovery = discover(config);
} catch (error) {
  fail(formatError(error));
}

let probes;
if (mode === "probe") {
  if (confirm !== "I_UNDERSTAND_THIS_ONLY_PROBES_SSH_READONLY") {
    fail("必须设置 CONFIRM_REMOTE_ORACLE_DISCOVERY=I_UNDERSTAND_THIS_ONLY_PROBES_SSH_READONLY");
  }
  probes = probeCandidates(discovery.probePlan, config.scan.connectTimeoutSeconds);
} else if (mode === "render-push-config") {
  try {
    const selected = selectForRender(config, discovery);
    console.log(JSON.stringify(buildPushConfig(config, selected), null, 2));
    process.exit(0);
  } catch (error) {
    fail(formatError(error));
  }
} else if (mode !== "scan") {
  fail(`未知模式：${mode}`);
}

console.log(JSON.stringify({
  schemaVersion: 1,
  status: statusFor(discovery, probes),
  mode,
  configFile,
  tom: config.tom,
  summary: {
    hosts: discovery.hosts.length,
    keys: discovery.keys.length,
    probeCombinations: discovery.probePlan.length,
    reachable: probes ? probes.filter((item) => item.status === "reachable").length : undefined,
  },
  hosts: discovery.hosts,
  keys: discovery.keys,
  probePlan: discovery.probePlan,
  probes,
  nextCommands: nextCommands(discovery, mode),
  safety: {
    readsLocalSshConfigOnly: mode === "scan",
    connectsSsh: mode === "probe",
    writesLocalFiles: false,
    writesTomRuntime: false,
    connectsTomSsh: false,
    connectsSecondOracle: mode === "probe",
    writesRemoteFiles: false,
    writesActiveRegistry: false,
    mutatesOpenClawInstance: false,
    callsLiveApi: false,
    outputsPrivateKeyContent: false,
  },
}, null, 2));
NODE
}

main() {
  require_command node
  case "${1:-scan}" in
    scan)
      run_node "scan" "${2:-$CONFIG_FILE}"
      ;;
    probe)
      require_command ssh
      run_node "probe" "${2:-$CONFIG_FILE}"
      ;;
    render-push-config)
      run_node "render-push-config" "${2:-$CONFIG_FILE}"
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
