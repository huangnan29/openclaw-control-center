#!/usr/bin/env bash
set -euo pipefail
set +x

# 远端 Oracle 只读 collector 接入包生成器。
# plan 只校验配置并输出将生成的接入包，不写文件。
# write 只写 Tom control-center runtime/onboarding 下的接入包，不 SSH、不修改 registry、不修改任何 OpenClaw 实例目录。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
CONFIG_FILE="${CONFIG_FILE:-${DEPLOY_DIR}/runtime/remote-collector-onboarding.json}"
CONFIRM_REMOTE_COLLECTOR_ONBOARDING="${CONFIRM_REMOTE_COLLECTOR_ONBOARDING:-}"

timestamp() {
  date +"%Y-%m-%dT%H:%M:%S%z"
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
  remote-collector-onboarding.sh plan [onboarding.json]
  remote-collector-onboarding.sh write [onboarding.json]

说明：
  plan 只校验配置并输出将生成的远端 collector 接入包，不写文件。
  write 只写 Tom control-center runtime/remote-onboarding/<serverId> 下的接入包。
  接入包包含 collector-node.json、bootstrap-collector-node.sh、remote-collector-pull.sources.json、register-remote-collector.json、RUNBOOK.md，并可默认携带远端 Docker build-context。
  本脚本不会 SSH，不会修改 Tom config/instances.json，不会修改任何 OpenClaw 实例目录，不会调用 managed-actions live API。

安全确认：
  write 必须设置：
    CONFIRM_REMOTE_COLLECTOR_ONBOARDING=I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_ONBOARDING_BUNDLE

配置样板：
  repo/ops/tom-readonly/remote-collector-onboarding.example.json
TEXT
}

run_node() {
  local mode="$1"
  local config="${2:-$CONFIG_FILE}"
  MODE="$mode" \
    DEPLOY_DIR="$DEPLOY_DIR" \
    CONFIG_FILE="$config" \
    CONFIRM_REMOTE_COLLECTOR_ONBOARDING="$CONFIRM_REMOTE_COLLECTOR_ONBOARDING" \
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" \
    node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const mode = process.env.MODE || "plan";
const deployDir = path.resolve(process.env.DEPLOY_DIR || "/srv/openclaw-control-center-readonly");
const configFile = path.resolve(process.env.CONFIG_FILE || path.join(deployDir, "runtime", "remote-collector-onboarding.json"));
const confirm = process.env.CONFIRM_REMOTE_COLLECTOR_ONBOARDING || "";
const scriptDir = path.resolve(process.env.SCRIPT_DIR || path.join(deployDir, "repo", "ops", "tom-readonly"));
const repoRoot = path.resolve(scriptDir, "..", "..");
const collectorBootstrapScript = path.join(repoRoot, "ops", "collector-node", "bootstrap-collector-node.sh");
const idPattern = /^[a-z0-9_-]+$/;

function fail(message) {
  console.error(`[失败] ${message}`);
  process.exit(2);
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

function readPort(value, fallback) {
  const raw = value === undefined ? fallback : value;
  const parsed = Number.parseInt(String(raw), 10);
  if (!Number.isFinite(parsed) || parsed < 1 || parsed > 65535) {
    throw new Error("remote.port 必须在 1-65535 之间");
  }
  return parsed;
}

function readOutputDir(value, serverId) {
  const base = path.join(deployDir, "runtime", "remote-onboarding");
  const raw = readString(value) || path.join(base, serverId);
  const resolved = path.resolve(path.isAbsolute(raw) ? raw : path.join(deployDir, raw));
  const allowedRoot = `${path.resolve(base)}${path.sep}`;
  if (!resolved.startsWith(allowedRoot)) {
    throw new Error(`outputDir 必须位于 ${base} 之下`);
  }
  return resolved;
}

function toContainerCollectorPath(serverId) {
  return `/app/runtime/collectors/${serverId}/snapshot.json`;
}

function toHostCollectorPath(serverId) {
  return path.join(deployDir, "runtime", "collectors", serverId, "snapshot.json");
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function readBoolean(value, fallback) {
  if (value === undefined) return fallback;
  if (value === true || value === "true") return true;
  if (value === false || value === "false") return false;
  throw new Error("布尔配置只能是 true 或 false");
}

function normalizeConfig(raw) {
  const config = asRecord(raw);
  if (!config) throw new Error("配置必须是 JSON object");
  if (config.schemaVersion !== 1) throw new Error("schemaVersion 必须为 1");

  const server = asRecord(config.server);
  if (!server) throw new Error("server 必须是 object");
  const serverId = readId(server.id, "server.id");
  const serverName = readName(server.name, "server.name");
  const collectorSnapshotPath = toContainerCollectorPath(serverId);

  const remote = asRecord(config.remote);
  if (!remote) throw new Error("remote 必须是 object");
  const remoteHost = readName(remote.host, "remote.host");
  const remoteUser = readName(remote.user || "ubuntu", "remote.user");
  const remotePort = readPort(remote.port, 22);
  const remoteDeployDir = readAbsolutePath(remote.deployDir || "/srv/openclaw-collector-node", "remote.deployDir");
  const remoteSnapshotPath = readAbsolutePath(
    remote.snapshotPath || path.join(remoteDeployDir, "runtime", "collectors", serverId, "snapshot.json"),
    "remote.snapshotPath",
  );
  const sshKey = readOptionalAbsolutePath(remote.sshKey, "remote.sshKey");
  const knownHostsFile = readOptionalAbsolutePath(remote.knownHostsFile, "remote.knownHostsFile") ||
    path.join(deployDir, "runtime", "ssh", "known_hosts");
  const strictHostKeyChecking = readString(remote.strictHostKeyChecking) || "accept-new";
  if (!["yes", "accept-new", "no"].includes(strictHostKeyChecking)) {
    throw new Error("remote.strictHostKeyChecking 只能是 yes、accept-new 或 no");
  }
  const connectTimeoutSeconds = Number.parseInt(String(remote.connectTimeoutSeconds || 10), 10);
  if (!Number.isFinite(connectTimeoutSeconds) || connectTimeoutSeconds < 1 || connectTimeoutSeconds > 120) {
    throw new Error("remote.connectTimeoutSeconds 必须在 1-120 之间");
  }

  const collectorNode = asRecord(config.collectorNode) || {};
  const cronSchedule = readName(collectorNode.cronSchedule || "*/2 * * * *", "collectorNode.cronSchedule");
  const collectorImage = readName(collectorNode.image || "openclaw-control-center:collector-node", "collectorNode.image");
  const collectorContainerName = readName(
    collectorNode.collectorContainerName || `openclaw-collector-${serverId}`,
    "collectorNode.collectorContainerName",
  );
  const buildContext = readOptionalAbsolutePath(collectorNode.buildContext, "collectorNode.buildContext");
  const bundleBuildContext = !buildContext && readBoolean(collectorNode.bundleBuildContext, true);
  const bundledRemoteBuildContext = path.join(remoteDeployDir, "build-context");
  const effectiveBuildContext = buildContext || (bundleBuildContext ? bundledRemoteBuildContext : undefined);
  const warnings = [];
  if (!effectiveBuildContext) {
    warnings.push("collectorNode.buildContext 未设置；远端 Oracle 必须已经有 collector image，或在配置中填入远端可用的源码目录作为 buildContext。");
  }

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

  const outputDir = readOutputDir(config.outputDir, serverId);
  return {
    server: {
      id: serverId,
      name: serverName,
      ...(readOptionalName(server.host, "server.host") ? { host: readOptionalName(server.host, "server.host") } : {}),
      ...(readOptionalName(server.region, "server.region") ? { region: readOptionalName(server.region, "server.region") } : {}),
      ...(readOptionalName(server.description, "server.description") ? {
        description: readOptionalName(server.description, "server.description"),
      } : {}),
    },
    remote: {
      host: remoteHost,
      user: remoteUser,
      port: remotePort,
      deployDir: remoteDeployDir,
      snapshotPath: remoteSnapshotPath,
      ...(sshKey ? { sshKey } : {}),
      knownHostsFile,
      strictHostKeyChecking,
      connectTimeoutSeconds,
    },
    collectorNode: {
      deployDir: remoteDeployDir,
      image: collectorImage,
      ...(effectiveBuildContext ? { buildContext: effectiveBuildContext } : {}),
      collectorContainerName,
      snapshotOutputPath: collectorSnapshotPath,
      cronSchedule,
    },
    bundleBuildContext,
    bundledRemoteBuildContext,
    outputDir,
    collectorSnapshotPath,
    localSnapshotPath: toHostCollectorPath(serverId),
    instances,
    warnings,
  };
}

function buildCollectorNodeConfig(config) {
  return {
    schemaVersion: 1,
    server: {
      ...config.server,
      collectorSnapshotPath: config.collectorSnapshotPath,
    },
    ...config.collectorNode,
    instances: config.instances,
  };
}

function buildPullConfig(config) {
  return {
    schemaVersion: 1,
    sources: [
      {
        serverId: config.server.id,
        name: config.server.name,
        enabled: true,
        host: config.remote.host,
        user: config.remote.user,
        port: config.remote.port,
        ...(config.remote.sshKey ? { sshKey: config.remote.sshKey } : {}),
        knownHostsFile: config.remote.knownHostsFile,
        strictHostKeyChecking: config.remote.strictHostKeyChecking,
        connectTimeoutSeconds: config.remote.connectTimeoutSeconds,
        remoteSnapshotPath: config.remote.snapshotPath,
        localSnapshotPath: config.localSnapshotPath,
      },
    ],
  };
}

function buildRegisterConfig(config) {
  return {
    schemaVersion: 1,
    server: config.server,
    collectorSnapshotPath: config.collectorSnapshotPath,
    replaceExisting: false,
    instances: config.instances.map((instance) => ({
      id: instance.id,
      name: instance.name,
    })),
  };
}

function listBuildContextFiles() {
  const roots = [
    "Dockerfile",
    ".dockerignore",
    "package.json",
    "package-lock.json",
    "tsconfig.json",
    ".env.example",
    "README.md",
    "README.zh-CN.md",
    "HALL.md",
    "src",
    "scripts",
    "docs",
  ];
  const ignoredNames = new Set(["node_modules", "dist", "runtime", ".git", ".npm-cache", "tmp"]);
  const files = [];
  function walk(relativePath) {
    const fullPath = path.join(repoRoot, relativePath);
    if (!fs.existsSync(fullPath)) return;
    const stat = fs.statSync(fullPath);
    if (stat.isDirectory()) {
      if (ignoredNames.has(path.basename(relativePath))) return;
      for (const child of fs.readdirSync(fullPath).sort()) {
        walk(path.join(relativePath, child));
      }
      return;
    }
    if (stat.isFile()) files.push(relativePath);
  }
  for (const root of roots) walk(root);
  return files;
}

function addBuildContextFiles(files, config) {
  if (!config.bundleBuildContext) return [];
  const relativeFiles = listBuildContextFiles();
  if (!relativeFiles.includes("Dockerfile")) throw new Error("构建上下文缺少 Dockerfile");
  if (!relativeFiles.includes("package.json")) throw new Error("构建上下文缺少 package.json");
  if (!relativeFiles.includes("package-lock.json")) throw new Error("构建上下文缺少 package-lock.json");
  for (const relativePath of relativeFiles) {
    files[path.join(config.outputDir, "build-context", relativePath)] = fs.readFileSync(path.join(repoRoot, relativePath));
  }
  files[path.join(config.outputDir, "build-context-manifest.json")] = `${JSON.stringify({
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    sourceRepo: repoRoot,
    remoteBuildContext: config.bundledRemoteBuildContext,
    files: relativeFiles,
  }, null, 2)}\n`;
  return relativeFiles;
}

function buildRunbook(config) {
  const remoteTarget = `${config.remote.user}@${config.remote.host}`;
  const sshBase = [
    "ssh",
    "-p",
    String(config.remote.port),
    ...(config.remote.sshKey ? ["-i", config.remote.sshKey] : []),
    remoteTarget,
  ].map(shellQuote).join(" ");
  const scpBase = [
    "scp",
    "-r",
    "-P",
    String(config.remote.port),
    ...(config.remote.sshKey ? ["-i", config.remote.sshKey] : []),
  ].map(shellQuote).join(" ");
  const scpItems = [
    path.join(config.outputDir, "collector-node.json"),
    path.join(config.outputDir, "bootstrap-collector-node.sh"),
    ...(config.bundleBuildContext ? [path.join(config.outputDir, "build-context")] : []),
  ].map(shellQuote).join(" ");
  const buildContextPrep = config.bundleBuildContext
    ? `mkdir -p ${shellQuote(config.remote.deployDir)}
rm -rf ${shellQuote(config.bundledRemoteBuildContext)}
cp -a /tmp/build-context ${shellQuote(config.bundledRemoteBuildContext)}`
    : `# collector-node.json 未携带 build-context；执行前请确认远端已有 ${config.collectorNode.image} 镜像。`;

  return `# ${config.server.name} 只读 collector 接入包

## 安全边界

- 本接入包只用于跨服务器只读监控。
- Tom 只通过 SSH 读取远端已经生成好的 snapshot JSON。
- 远端 collector 只读挂载实例目录，不暴露端口，不挂载 docker.sock。
- Tom 注册阶段只更新 control-center registry，并会先备份。
- 全流程不修改任何 OpenClaw 实例目录，不重启实例，不调用 managed action live API。

## 1. 复制接入包到远端 Oracle

\`\`\`bash
${scpBase} ${scpItems} ${shellQuote(`${remoteTarget}:/tmp/`)}
\`\`\`

## 2. 在远端 Oracle 上生成 collector-only 部署文件

如果 collector-node.json 未配置 collectorNode.buildContext，请先确认远端已经存在 ${config.collectorNode.image} 镜像；否则需要把 control-center 仓库放到远端，并在 onboarding 配置里把 collectorNode.buildContext 指向该目录。

\`\`\`bash
${sshBase} <<'REMOTE_OPENCLAW'
set -euo pipefail
${buildContextPrep}
cd /tmp
./bootstrap-collector-node.sh plan collector-node.json
CONFIRM_COLLECTOR_NODE_WRITE=I_UNDERSTAND_THIS_ONLY_WRITES_COLLECTOR_NODE_FILES ./bootstrap-collector-node.sh write collector-node.json
cd ${shellQuote(config.remote.deployDir)}
./collector-snapshot.sh
./install-collector-cron.sh
REMOTE_OPENCLAW
\`\`\`

## 3. 在 Tom 上只读拉取远端 snapshot

\`\`\`bash
cd ${shellQuote(deployDir)}
repo/ops/tom-readonly/remote-collector-pull.sh plan ${shellQuote(path.join(config.outputDir, "remote-collector-pull.sources.json"))}
CONFIRM_REMOTE_COLLECTOR_PULL=I_UNDERSTAND_THIS_ONLY_READS_REMOTE_COLLECTOR_SNAPSHOTS \\
  repo/ops/tom-readonly/remote-collector-pull.sh pull ${shellQuote(path.join(config.outputDir, "remote-collector-pull.sources.json"))}
\`\`\`

## 4. 在 Tom 上注册到中央 registry

\`\`\`bash
cd ${shellQuote(deployDir)}
repo/ops/tom-readonly/register-remote-collector.sh plan ${shellQuote(path.join(config.outputDir, "register-remote-collector.json"))}
CONFIRM_REMOTE_COLLECTOR_REGISTER=I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_REGISTRY \\
  repo/ops/tom-readonly/register-remote-collector.sh apply ${shellQuote(path.join(config.outputDir, "register-remote-collector.json"))}
./healthcheck.sh
\`\`\`
`;
}

function buildFiles(config) {
  const bootstrap = fs.readFileSync(collectorBootstrapScript, "utf8");
  const files = {
    [path.join(config.outputDir, "collector-node.json")]: `${JSON.stringify(buildCollectorNodeConfig(config), null, 2)}\n`,
    [path.join(config.outputDir, "remote-collector-pull.sources.json")]: `${JSON.stringify(buildPullConfig(config), null, 2)}\n`,
    [path.join(config.outputDir, "register-remote-collector.json")]: `${JSON.stringify(buildRegisterConfig(config), null, 2)}\n`,
    [path.join(config.outputDir, "bootstrap-collector-node.sh")]: bootstrap,
    [path.join(config.outputDir, "RUNBOOK.md")]: buildRunbook(config),
    [path.join(config.outputDir, "safety.json")]: `${JSON.stringify({
      schemaVersion: 1,
      serverId: config.server.id,
      generatedAt: new Date().toISOString(),
      bundlesBuildContext: config.bundleBuildContext,
      remoteBuildContext: config.bundleBuildContext ? config.bundledRemoteBuildContext : undefined,
      writesOnboardingBundleOnly: true,
      writesActiveRegistry: false,
      connectsSsh: false,
      mutatesOpenClawInstance: false,
      restartsOpenClawInstance: false,
      callsLiveApi: false,
      outputDir: config.outputDir,
    }, null, 2)}\n`,
  };
  const buildContextFiles = addBuildContextFiles(files, config);
  const combined = Object.entries(files)
    .filter(([file]) => !file.endsWith("bootstrap-collector-node.sh"))
    .filter(([file]) => !file.includes(`${path.sep}build-context${path.sep}`))
    .map(([, content]) => content)
    .join("\n");
  if (combined.includes("/var/run/docker.sock")) throw new Error("接入包不能包含 docker.sock 挂载");
  if (/privileged\s*:\s*true/.test(combined)) throw new Error("接入包不能启用 privileged");
  const liveApiPattern = new RegExp(["api", "managed-actions", "live"].join("\\/"));
  if (liveApiPattern.test(combined)) throw new Error("接入包不能调用 managed action live API");
  return { files, buildContextFiles };
}

function summarizeFiles(config) {
  const files = [
    path.join(config.outputDir, "collector-node.json"),
    path.join(config.outputDir, "remote-collector-pull.sources.json"),
    path.join(config.outputDir, "register-remote-collector.json"),
    path.join(config.outputDir, "bootstrap-collector-node.sh"),
    path.join(config.outputDir, "RUNBOOK.md"),
    path.join(config.outputDir, "safety.json"),
  ];
  if (config.bundleBuildContext) {
    files.push(path.join(config.outputDir, "build-context"));
    files.push(path.join(config.outputDir, "build-context-manifest.json"));
  }
  return files;
}

function writeFiles(files) {
  for (const [file, content] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, content, "utf8");
    if (file.endsWith(".sh")) fs.chmodSync(file, 0o755);
  }
}

function formatError(error) {
  return error instanceof Error ? error.message : String(error);
}

let config;
let files;
let buildContextFiles;
try {
  config = normalizeConfig(readJsonFile(configFile, "onboarding 配置"));
  const built = buildFiles(config);
  files = built.files;
  buildContextFiles = built.buildContextFiles;
} catch (error) {
  fail(formatError(error));
}

const summary = {
  configFile,
  deployDir,
  serverId: config.server.id,
  warnings: config.warnings,
  bundlesBuildContext: config.bundleBuildContext,
  remoteBuildContext: config.bundleBuildContext ? config.bundledRemoteBuildContext : undefined,
  buildContextFiles: buildContextFiles.length,
  outputDir: config.outputDir,
  remote: {
    host: config.remote.host,
    user: config.remote.user,
    port: config.remote.port,
    deployDir: config.remote.deployDir,
    snapshotPath: config.remote.snapshotPath,
  },
  localSnapshotPath: config.localSnapshotPath,
  files: summarizeFiles(config),
  safety: {
    writesOnboardingBundleOnly: true,
    writesActiveRegistry: false,
    connectsSsh: false,
    mutatesOpenClawInstance: false,
    restartsOpenClawInstance: false,
    callsLiveApi: false,
  },
};

if (mode === "plan") {
  console.log(JSON.stringify({ status: "planned", ...summary }, null, 2));
} else if (mode === "write") {
  if (confirm !== "I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_ONBOARDING_BUNDLE") {
    fail("必须设置 CONFIRM_REMOTE_COLLECTOR_ONBOARDING=I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_ONBOARDING_BUNDLE");
  }
  writeFiles(files);
  console.log(JSON.stringify({
    status: "written",
    ...summary,
    nextActions: [
      `审查 ${path.join(config.outputDir, "RUNBOOK.md")}`,
      `把 ${path.join(config.outputDir, "collector-node.json")} 和 bootstrap-collector-node.sh 复制到远端 Oracle`,
      "远端生成 snapshot 后，在 Tom 执行 pull -> register -> healthcheck",
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
    write)
      run_node "write" "${2:-$CONFIG_FILE}"
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
