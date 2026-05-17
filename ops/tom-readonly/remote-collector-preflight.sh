#!/usr/bin/env bash
set -euo pipefail
set +x

# 远端 Oracle collector-only 接入前只读预检。
# plan 只读取 onboarding bundle 并输出检查计划，不联网。
# check 通过 SSH 执行只读检查命令，不写远端文件、不启动容器、不修改任何 OpenClaw 实例目录。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
BUNDLE_DIR="${BUNDLE_DIR:-${DEPLOY_DIR}/runtime/remote-onboarding/remote-oracle}"
CONFIRM_REMOTE_COLLECTOR_PREFLIGHT="${CONFIRM_REMOTE_COLLECTOR_PREFLIGHT:-}"

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
  remote-collector-preflight.sh plan <bundle-dir>
  remote-collector-preflight.sh check <bundle-dir>

说明：
  plan 只读取 onboarding bundle，输出将检查的远端 SSH、docker、crontab、实例目录和 gateway 端口，不联网。
  check 通过 SSH 执行只读检查命令；不会写远端文件，不会启动容器，不会修改任何 OpenClaw 实例目录，不会调用 managed-actions live API。

安全确认：
  check 必须设置：
    CONFIRM_REMOTE_COLLECTOR_PREFLIGHT=I_UNDERSTAND_THIS_ONLY_READS_REMOTE_PREREQUISITES
TEXT
}

run_node() {
  local mode="$1"
  local bundle="${2:-$BUNDLE_DIR}"
  MODE="$mode" \
    DEPLOY_DIR="$DEPLOY_DIR" \
    BUNDLE_DIR="$bundle" \
    CONFIRM_REMOTE_COLLECTOR_PREFLIGHT="$CONFIRM_REMOTE_COLLECTOR_PREFLIGHT" \
    node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const mode = process.env.MODE || "plan";
const deployDir = path.resolve(process.env.DEPLOY_DIR || "/srv/openclaw-control-center-readonly");
const bundleDir = resolveBundleDir(process.env.BUNDLE_DIR || path.join(deployDir, "runtime", "remote-onboarding", "remote-oracle"));
const confirm = process.env.CONFIRM_REMOTE_COLLECTOR_PREFLIGHT || "";
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

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function normalizeBundle() {
  const collectorNodeFile = path.join(bundleDir, "collector-node.json");
  const pullConfigFile = path.join(bundleDir, "remote-collector-pull.sources.json");
  const safetyFile = path.join(bundleDir, "safety.json");
  const collectorNode = readJson(collectorNodeFile, "collector-node.json");
  const pullConfig = readJson(pullConfigFile, "remote-collector-pull.sources.json");
  const safety = fs.existsSync(safetyFile) ? readJson(safetyFile, "safety.json") : undefined;
  if (!asRecord(collectorNode) || collectorNode.schemaVersion !== 1) throw new Error("collector-node.json schemaVersion 必须为 1");
  if (!asRecord(pullConfig) || pullConfig.schemaVersion !== 1) throw new Error("remote-collector-pull.sources.json schemaVersion 必须为 1");
  const serverId = readId(asRecord(collectorNode.server)?.id, "collectorNode.server.id");
  const source = Array.isArray(pullConfig.sources) ? asRecord(pullConfig.sources[0]) : undefined;
  if (!source) throw new Error("remote-collector-pull.sources.json 必须包含 sources[0]");
  if (source.serverId !== serverId) throw new Error("pull source serverId 与 collector-node 不一致");
  const instances = Array.isArray(collectorNode.instances) ? collectorNode.instances.map((entry, index) => {
    const item = asRecord(entry);
    if (!item) throw new Error(`instances[${index}] 必须是 object`);
    return {
      id: readId(item.id, `instances[${index}].id`),
      name: readString(item.name) || String(item.id),
      gatewayUrl: readString(item.gatewayUrl) || "",
      configDir: readString(item.configDir) || "",
      workspaceDir: readString(item.workspaceDir) || "",
      codexDir: readString(item.codexDir),
    };
  }) : [];
  if (instances.length === 0) throw new Error("collector-node.json instances 必须是非空数组");
  const deployDirRemote = readString(collectorNode.deployDir);
  if (!deployDirRemote || !deployDirRemote.startsWith("/")) throw new Error("collector-node deployDir 必须是绝对路径");
  return { collectorNodeFile, pullConfigFile, safetyFile, collectorNode, pullSource: source, safety, serverId, instances, deployDirRemote };
}

function sshArgs(source, command) {
  const user = readString(source.user) || "ubuntu";
  const host = readString(source.host);
  if (!host) throw new Error("pull source host 必须填写");
  const port = Number.parseInt(String(source.port || 22), 10);
  if (!Number.isFinite(port) || port < 1 || port > 65535) throw new Error("pull source port 必须在 1-65535 之间");
  const knownHostsFile = readString(source.knownHostsFile) || path.join(deployDir, "runtime", "ssh", "known_hosts");
  const strictHostKeyChecking = readString(source.strictHostKeyChecking) || "accept-new";
  const connectTimeoutSeconds = Number.parseInt(String(source.connectTimeoutSeconds || 10), 10);
  const args = [
    "-p",
    String(port),
    "-o",
    "BatchMode=yes",
    "-o",
    `ConnectTimeout=${connectTimeoutSeconds}`,
    "-o",
    `StrictHostKeyChecking=${strictHostKeyChecking}`,
    "-o",
    `UserKnownHostsFile=${knownHostsFile}`,
  ];
  const sshKey = readString(source.sshKey);
  if (sshKey) args.push("-i", sshKey);
  args.push(`${user}@${host}`, command);
  fs.mkdirSync(path.dirname(knownHostsFile), { recursive: true });
  return args;
}

function runSshCheck(bundle, check) {
  const result = spawnSync("ssh", sshArgs(bundle.pullSource, check.command), {
    encoding: "utf8",
    maxBuffer: 2 * 1024 * 1024,
  });
  const detail = (result.stdout || result.stderr || "").trim();
  if (result.status === 0) {
    return { ...check, status: "pass", detail: detail || check.passDetail || "ok" };
  }
  if (check.optional === true) {
    return { ...check, status: "warn", detail: detail || `exit=${result.status}` };
  }
  return { ...check, status: "fail", detail: detail || `exit=${result.status}` };
}

function gatewayHostForPreflight(gatewayUrl) {
  try {
    const parsed = new URL(gatewayUrl);
    const port = parsed.port || (parsed.protocol === "wss:" ? "443" : "80");
    const host = parsed.hostname === "host.docker.internal" ? "127.0.0.1" : parsed.hostname;
    return { host, port };
  } catch {
    return undefined;
  }
}

function buildChecks(bundle) {
  const deployParent = path.dirname(bundle.deployDirRemote);
  const checks = [
    {
      id: "ssh_identity",
      label: "SSH 身份与基础系统信息",
      command: "printf 'user=%s host=%s\\n' \"$(id -un 2>/dev/null || true)\" \"$(uname -n 2>/dev/null || true)\"",
      required: true,
    },
    {
      id: "docker",
      label: "docker 命令可用",
      command: "command -v docker >/dev/null 2>&1 && docker --version",
      required: true,
    },
    {
      id: "docker_compose",
      label: "docker compose 可用",
      command: "docker compose version >/dev/null 2>&1 || docker-compose version >/dev/null 2>&1",
      required: true,
    },
    {
      id: "deploy_parent_writable",
      label: "collector deploy 目录或父目录可写",
      command: `if [ -d ${shellQuote(bundle.deployDirRemote)} ]; then test -w ${shellQuote(bundle.deployDirRemote)}; else test -d ${shellQuote(deployParent)} && test -w ${shellQuote(deployParent)}; fi`,
      required: true,
    },
    {
      id: "crontab",
      label: "crontab 可用",
      command: "command -v crontab >/dev/null 2>&1",
      required: false,
      optional: true,
    },
  ];
  for (const instance of bundle.instances) {
    checks.push({
      id: `config_dir_${instance.id}`,
      label: `实例 ${instance.id} configDir 可读`,
      command: `test -d ${shellQuote(instance.configDir)} && test -r ${shellQuote(instance.configDir)}`,
      required: true,
      instanceId: instance.id,
    });
    checks.push({
      id: `workspace_dir_${instance.id}`,
      label: `实例 ${instance.id} workspaceDir 可读`,
      command: `test -d ${shellQuote(instance.workspaceDir)} && test -r ${shellQuote(instance.workspaceDir)}`,
      required: true,
      instanceId: instance.id,
    });
    if (instance.codexDir) {
      checks.push({
        id: `codex_dir_${instance.id}`,
        label: `实例 ${instance.id} codexDir 可读`,
        command: `test -d ${shellQuote(instance.codexDir)} && test -r ${shellQuote(instance.codexDir)}`,
        required: false,
        optional: true,
        instanceId: instance.id,
      });
    }
    const gateway = gatewayHostForPreflight(instance.gatewayUrl);
    if (gateway) {
      checks.push({
        id: `gateway_${instance.id}`,
        label: `实例 ${instance.id} gateway 端口可连`,
        command: `if command -v timeout >/dev/null 2>&1 && command -v bash >/dev/null 2>&1; then timeout 3 bash -lc ': >/dev/tcp/${gateway.host}/${gateway.port}'; elif command -v nc >/dev/null 2>&1; then nc -z -w 3 ${shellQuote(gateway.host)} ${shellQuote(gateway.port)}; else exit 3; fi`,
        required: true,
        instanceId: instance.id,
      });
    } else {
      checks.push({
        id: `gateway_${instance.id}`,
        label: `实例 ${instance.id} gateway URL 可解析`,
        command: "false",
        required: true,
        instanceId: instance.id,
        planOnlyError: `gatewayUrl 无法解析：${instance.gatewayUrl}`,
      });
    }
  }
  return checks;
}

function safety(connectsSsh) {
  return {
    readsRemotePrerequisitesOnly: true,
    writesRemoteFiles: false,
    startsContainers: false,
    mutatesOpenClawInstance: false,
    restartsOpenClawInstance: false,
    callsLiveApi: false,
    connectsSsh,
  };
}

function formatError(error) {
  return error instanceof Error ? error.message : String(error);
}

let bundle;
let checks;
try {
  bundle = normalizeBundle();
  checks = buildChecks(bundle);
} catch (error) {
  fail(formatError(error));
}

if (mode === "plan") {
  console.log(JSON.stringify({
    status: "planned",
    bundleDir,
    serverId: bundle.serverId,
    remote: {
      host: bundle.pullSource.host,
      user: bundle.pullSource.user,
      port: bundle.pullSource.port || 22,
      deployDir: bundle.deployDirRemote,
    },
    checks: checks.map(({ command, ...check }) => check),
    safety: safety(false),
  }, null, 2));
} else if (mode === "check") {
  if (confirm !== "I_UNDERSTAND_THIS_ONLY_READS_REMOTE_PREREQUISITES") {
    fail("必须设置 CONFIRM_REMOTE_COLLECTOR_PREFLIGHT=I_UNDERSTAND_THIS_ONLY_READS_REMOTE_PREREQUISITES");
  }
  const results = checks.map((check) => {
    if (check.planOnlyError) return { ...check, status: "fail", detail: check.planOnlyError };
    return runSshCheck(bundle, check);
  });
  const failed = results.filter((item) => item.status === "fail");
  const warned = results.filter((item) => item.status === "warn");
  const status = failed.length > 0 ? "blocked" : warned.length > 0 ? "warning" : "ready";
  console.log(JSON.stringify({
    status,
    bundleDir,
    serverId: bundle.serverId,
    checkedAt: new Date().toISOString(),
    results: results.map(({ command, passDetail, planOnlyError, optional, ...result }) => result),
    safety: safety(true),
  }, null, 2));
  if (failed.length > 0) process.exit(2);
} else {
  fail(`未知模式：${mode}`);
}
NODE
}

main() {
  require_command node
  case "${1:-plan}" in
    plan)
      run_node "plan" "${2:-$BUNDLE_DIR}"
      ;;
    check)
      require_command ssh
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
