#!/usr/bin/env bash
set -euo pipefail
set +x

# 远端 Oracle collector 节点同步器。
# plan 只读取 Tom 本地 onboarding bundle，不联网、不写文件。
# sync 只把 onboarding bundle 复制到远端 collector deploy 目录，不修改任何 OpenClaw 实例目录。
# bootstrap-plan/bootstrap-write 只在远端 collector deploy 目录内执行接入包里的 bootstrap 脚本。
# snapshot/install-cron 分别显式确认后只运行远端 collector-only 快照和 cron 安装，不修改 OpenClaw 实例目录。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
BUNDLE_DIR="${BUNDLE_DIR:-${DEPLOY_DIR}/runtime/remote-onboarding/remote-oracle}"
CONFIRM_REMOTE_COLLECTOR_NODE_SYNC="${CONFIRM_REMOTE_COLLECTOR_NODE_SYNC:-}"
CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_PLAN="${CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_PLAN:-}"
CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_WRITE="${CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_WRITE:-}"
CONFIRM_REMOTE_COLLECTOR_NODE_SNAPSHOT="${CONFIRM_REMOTE_COLLECTOR_NODE_SNAPSHOT:-}"
CONFIRM_REMOTE_COLLECTOR_NODE_CRON="${CONFIRM_REMOTE_COLLECTOR_NODE_CRON:-}"
MAX_REMOTE_COLLECTOR_SYNC_BYTES="${MAX_REMOTE_COLLECTOR_SYNC_BYTES:-209715200}"

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
  remote-collector-node-sync.sh plan <bundle-dir>
  remote-collector-node-sync.sh sync <bundle-dir>
  remote-collector-node-sync.sh bootstrap-plan <bundle-dir>
  remote-collector-node-sync.sh bootstrap-write <bundle-dir>
  remote-collector-node-sync.sh snapshot <bundle-dir>
  remote-collector-node-sync.sh install-cron <bundle-dir>

说明：
  plan 只读取 Tom 本地 onboarding bundle，输出将同步的远端 collector 节点目标，不联网、不写文件。
  sync 通过 SSH+tar 把 bundle 复制到远端 collector deploy 目录；只写远端 collector 节点目录，不写任何 OpenClaw 实例目录。
  bootstrap-plan 通过 SSH 执行远端 ./bootstrap-collector-node.sh plan collector-node.json；不写文件、不启动容器。
  bootstrap-write 通过 SSH 执行远端 bootstrap write；只写远端 collector-only 部署文件，不启动容器、不修改 OpenClaw 实例目录。
  snapshot 通过 SSH 执行远端 ./collector-snapshot.sh；只启动/使用 collector-only 容器生成 snapshot，不修改 OpenClaw 实例目录。
  install-cron 通过 SSH 执行远端 ./install-collector-cron.sh；只安装当前用户 crontab 中的 collector 受控块。

安全确认：
  sync 必须设置：
    CONFIRM_REMOTE_COLLECTOR_NODE_SYNC=I_UNDERSTAND_THIS_ONLY_COPIES_COLLECTOR_BUNDLE_TO_REMOTE

  bootstrap-plan 必须设置：
    CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_PLAN=I_UNDERSTAND_THIS_ONLY_RUNS_REMOTE_BOOTSTRAP_PLAN

  bootstrap-write 必须设置：
    CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_WRITE=I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_COLLECTOR_NODE_FILES

  snapshot 必须设置：
    CONFIRM_REMOTE_COLLECTOR_NODE_SNAPSHOT=I_UNDERSTAND_THIS_RUNS_REMOTE_COLLECTOR_SNAPSHOT_ONLY

  install-cron 必须设置：
    CONFIRM_REMOTE_COLLECTOR_NODE_CRON=I_UNDERSTAND_THIS_ONLY_INSTALLS_REMOTE_COLLECTOR_CRON

不会执行：
  - 不修改远端 OpenClaw 实例目录。
  - 不重启 OpenClaw 实例。
  - 不启动或重启 OpenClaw 实例容器。
  - 不调用 managed-actions live API。
TEXT
}

run_node() {
  local mode="$1"
  local bundle="${2:-$BUNDLE_DIR}"
  MODE="$mode" \
    DEPLOY_DIR="$DEPLOY_DIR" \
    BUNDLE_DIR="$bundle" \
    CONFIRM_REMOTE_COLLECTOR_NODE_SYNC="$CONFIRM_REMOTE_COLLECTOR_NODE_SYNC" \
    CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_PLAN="$CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_PLAN" \
    CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_WRITE="$CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_WRITE" \
    CONFIRM_REMOTE_COLLECTOR_NODE_SNAPSHOT="$CONFIRM_REMOTE_COLLECTOR_NODE_SNAPSHOT" \
    CONFIRM_REMOTE_COLLECTOR_NODE_CRON="$CONFIRM_REMOTE_COLLECTOR_NODE_CRON" \
    MAX_REMOTE_COLLECTOR_SYNC_BYTES="$MAX_REMOTE_COLLECTOR_SYNC_BYTES" \
    node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const mode = process.env.MODE || "plan";
const deployDir = path.resolve(process.env.DEPLOY_DIR || "/srv/openclaw-control-center-readonly");
const bundleDir = resolveBundleDir(process.env.BUNDLE_DIR || path.join(deployDir, "runtime", "remote-onboarding", "remote-oracle"));
const confirmSync = process.env.CONFIRM_REMOTE_COLLECTOR_NODE_SYNC || "";
const confirmBootstrapPlan = process.env.CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_PLAN || "";
const confirmBootstrapWrite = process.env.CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_WRITE || "";
const confirmSnapshot = process.env.CONFIRM_REMOTE_COLLECTOR_NODE_SNAPSHOT || "";
const confirmCron = process.env.CONFIRM_REMOTE_COLLECTOR_NODE_CRON || "";
const configuredMaxSyncBytes = Number.parseInt(process.env.MAX_REMOTE_COLLECTOR_SYNC_BYTES || "209715200", 10);
const maxSyncBytes = Number.isFinite(configuredMaxSyncBytes) && configuredMaxSyncBytes > 0
  ? configuredMaxSyncBytes
  : 209715200;
const idPattern = /^[a-z0-9_-]+$/;

function fail(message) {
  console.error(`[失败] ${message}`);
  process.exit(2);
}

function asRecord(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : undefined;
}

function readJson(file, label) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    throw new Error(`无法读取 ${label}：${file}：${formatError(error)}`);
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

function readAbsolutePath(value, label) {
  const text = readString(value);
  if (!text) throw new Error(`${label} 必须填写`);
  if (!path.isAbsolute(text)) throw new Error(`${label} 必须是绝对路径`);
  if (/[\r\n\0]/.test(text)) throw new Error(`${label} 包含非法字符`);
  return path.resolve(text);
}

function readRemotePath(value, label) {
  const text = readString(value);
  if (!text) throw new Error(`${label} 必须填写`);
  if (!text.startsWith("/")) throw new Error(`${label} 必须是绝对路径`);
  if (/[\r\n\0]/.test(text)) throw new Error(`${label} 包含非法字符`);
  return path.posix.normalize(text);
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

function requireExecutable(name) {
  const result = spawnSync("sh", ["-lc", `command -v ${shellQuote(name)}`], { encoding: "utf8" });
  if (result.status !== 0) throw new Error(`缺少命令：${name}`);
}

function walkFiles(dir) {
  const files = [];
  function walk(current) {
    for (const child of fs.readdirSync(current).sort()) {
      const full = path.join(current, child);
      const stat = fs.statSync(full);
      if (stat.isDirectory()) {
        walk(full);
        continue;
      }
      if (!stat.isFile()) continue;
      const relativePath = path.relative(dir, full);
      if (relativePath.startsWith("..") || path.isAbsolute(relativePath)) {
        throw new Error(`bundle 文件越界：${relativePath}`);
      }
      files.push({
        path: relativePath,
        size: stat.size,
        executable: Boolean(stat.mode & 0o111),
      });
    }
  }
  walk(dir);
  return files;
}

function loadBundle() {
  const requiredFiles = {
    collectorNodeFile: path.join(bundleDir, "collector-node.json"),
    pullConfigFile: path.join(bundleDir, "remote-collector-pull.sources.json"),
    safetyFile: path.join(bundleDir, "safety.json"),
    bootstrapFile: path.join(bundleDir, "bootstrap-collector-node.sh"),
    runbookFile: path.join(bundleDir, "RUNBOOK.md"),
  };
  const missingFiles = Object.values(requiredFiles).filter((file) => !fs.existsSync(file));
  if (missingFiles.length > 0) {
    throw new Error(`接入包缺少文件：${missingFiles.join(", ")}`);
  }

  const collectorNode = readJson(requiredFiles.collectorNodeFile, "collector-node.json");
  const pullConfig = readJson(requiredFiles.pullConfigFile, "remote-collector-pull.sources.json");
  const safety = readJson(requiredFiles.safetyFile, "safety.json");
  if (!asRecord(collectorNode) || collectorNode.schemaVersion !== 1) throw new Error("collector-node.json schemaVersion 必须为 1");
  if (!asRecord(pullConfig) || pullConfig.schemaVersion !== 1) throw new Error("remote-collector-pull.sources.json schemaVersion 必须为 1");
  if (!asRecord(safety) || safety.schemaVersion !== 1) throw new Error("safety.json schemaVersion 必须为 1");

  const serverId = readId(asRecord(collectorNode.server)?.id, "collectorNode.server.id");
  if (safety.serverId !== serverId) throw new Error("safety serverId 与 collector-node 不一致");
  const source = Array.isArray(pullConfig.sources) ? asRecord(pullConfig.sources[0]) : undefined;
  if (!source) throw new Error("remote-collector-pull.sources.json 必须包含 sources[0]");
  if (source.serverId !== serverId) throw new Error("pull source serverId 与 collector-node 不一致");

  const remoteDeployDir = readRemotePath(collectorNode.deployDir, "collectorNode.deployDir");
  const sourceUser = readString(source.user) || "ubuntu";
  const sourceHost = readString(source.host);
  if (!sourceHost) throw new Error("pull source host 必须填写");
  if (/[\r\n\0]/.test(sourceHost) || /[\r\n\0]/.test(sourceUser)) throw new Error("远端 SSH host/user 包含非法字符");
  const sourcePort = Number.parseInt(String(source.port || 22), 10);
  if (!Number.isFinite(sourcePort) || sourcePort < 1 || sourcePort > 65535) throw new Error("pull source port 必须在 1-65535 之间");
  const sshKey = readString(source.sshKey) ? readAbsolutePath(source.sshKey, "pull source sshKey") : undefined;
  const knownHostsFile = readString(source.knownHostsFile)
    ? readAbsolutePath(source.knownHostsFile, "pull source knownHostsFile")
    : path.join(deployDir, "runtime", "ssh", "known_hosts");
  const strictHostKeyChecking = readString(source.strictHostKeyChecking) || "accept-new";
  if (!["yes", "accept-new", "no"].includes(strictHostKeyChecking)) {
    throw new Error("strictHostKeyChecking 只能是 yes、accept-new 或 no");
  }
  const connectTimeoutSeconds = Number.parseInt(String(source.connectTimeoutSeconds || 10), 10);
  if (!Number.isFinite(connectTimeoutSeconds) || connectTimeoutSeconds < 1 || connectTimeoutSeconds > 120) {
    throw new Error("connectTimeoutSeconds 必须在 1-120 之间");
  }
  const files = walkFiles(bundleDir);
  const totalBytes = files.reduce((sum, file) => sum + file.size, 0);
  if (Number.isFinite(maxSyncBytes) && maxSyncBytes > 0 && totalBytes > maxSyncBytes) {
    throw new Error(`bundle 大小超过 MAX_REMOTE_COLLECTOR_SYNC_BYTES：${totalBytes} > ${maxSyncBytes}`);
  }
  if (safety.mutatesOpenClawInstance !== false || safety.callsLiveApi !== false || safety.restartsOpenClawInstance !== false) {
    throw new Error("接入包 safety 声明不安全，拒绝同步");
  }
  if (files.some((file) => file.path.includes(".."))) {
    throw new Error("bundle 文件路径不能包含 ..");
  }
  return {
    serverId,
    serverName: readString(asRecord(collectorNode.server)?.name) || serverId,
    bundleDir,
    remoteDeployDir,
    files,
    totalBytes,
    source: {
      host: sourceHost,
      user: sourceUser,
      port: sourcePort,
      sshKey,
      knownHostsFile,
      strictHostKeyChecking,
      connectTimeoutSeconds,
    },
    safety,
  };
}

function sshArgs(bundle, command) {
  const source = bundle.source;
  fs.mkdirSync(path.dirname(source.knownHostsFile), { recursive: true });
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
  args.push(`${source.user}@${source.host}`, command);
  return args;
}

function assertSshKeyReady(bundle) {
  const sshKey = bundle.source.sshKey;
  if (!sshKey) return;
  if (!fs.existsSync(sshKey)) throw new Error(`Tom 上缺少远端只读 SSH key：${sshKey}`);
  try {
    fs.accessSync(sshKey, fs.constants.R_OK);
  } catch {
    throw new Error(`Tom 无法读取远端只读 SSH key：${sshKey}`);
  }
}

function runSsh(bundle, remoteCommand, input) {
  requireExecutable("ssh");
  assertSshKeyReady(bundle);
  const result = spawnSync("ssh", sshArgs(bundle, remoteCommand), {
    input,
    encoding: input ? undefined : "utf8",
    maxBuffer: 20 * 1024 * 1024,
  });
  if (result.status !== 0) {
    const detail = Buffer.isBuffer(result.stderr) ? result.stderr.toString("utf8") : String(result.stderr || result.stdout || "");
    throw new Error(`远端 SSH 命令失败：${detail.trim() || `exit=${result.status}`}`);
  }
  return {
    stdout: Buffer.isBuffer(result.stdout) ? result.stdout.toString("utf8") : String(result.stdout || ""),
    stderr: Buffer.isBuffer(result.stderr) ? result.stderr.toString("utf8") : String(result.stderr || ""),
  };
}

function runSync(bundle) {
  if (confirmSync !== "I_UNDERSTAND_THIS_ONLY_COPIES_COLLECTOR_BUNDLE_TO_REMOTE") {
    fail("必须设置 CONFIRM_REMOTE_COLLECTOR_NODE_SYNC=I_UNDERSTAND_THIS_ONLY_COPIES_COLLECTOR_BUNDLE_TO_REMOTE");
  }
  requireExecutable("tar");
  const tar = spawnSync("tar", ["-C", bundle.bundleDir, "-cf", "-", "."], {
    maxBuffer: Math.max(maxSyncBytes, 20 * 1024 * 1024),
  });
  if (tar.status !== 0) {
    const detail = Buffer.isBuffer(tar.stderr) ? tar.stderr.toString("utf8") : String(tar.stderr || "");
    throw new Error(`打包 onboarding bundle 失败：${detail.trim() || `exit=${tar.status}`}`);
  }
  const remoteScript = [
    "set -euo pipefail",
    "umask 077",
    `mkdir -p ${shellQuote(bundle.remoteDeployDir)}`,
    `tar -C ${shellQuote(bundle.remoteDeployDir)} -xf -`,
    `chmod +x ${shellQuote(path.posix.join(bundle.remoteDeployDir, "bootstrap-collector-node.sh"))}`,
    `test -s ${shellQuote(path.posix.join(bundle.remoteDeployDir, "collector-node.json"))}`,
    `test -s ${shellQuote(path.posix.join(bundle.remoteDeployDir, "remote-collector-pull.sources.json"))}`,
  ].join("\n");
  const result = runSsh(bundle, `bash -lc ${shellQuote(remoteScript)}`, tar.stdout);
  return {
    status: "synced",
    syncedAt: new Date().toISOString(),
    remoteStdout: result.stdout.trim(),
    remoteStderr: result.stderr.trim(),
  };
}

function runBootstrap(bundle, bootstrapMode) {
  if (bootstrapMode === "plan" && confirmBootstrapPlan !== "I_UNDERSTAND_THIS_ONLY_RUNS_REMOTE_BOOTSTRAP_PLAN") {
    fail("必须设置 CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_PLAN=I_UNDERSTAND_THIS_ONLY_RUNS_REMOTE_BOOTSTRAP_PLAN");
  }
  if (bootstrapMode === "write" && confirmBootstrapWrite !== "I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_COLLECTOR_NODE_FILES") {
    fail("必须设置 CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_WRITE=I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_COLLECTOR_NODE_FILES");
  }
  const command = bootstrapMode === "plan"
    ? "./bootstrap-collector-node.sh plan collector-node.json"
    : "CONFIRM_COLLECTOR_NODE_WRITE=I_UNDERSTAND_THIS_ONLY_WRITES_COLLECTOR_NODE_FILES ./bootstrap-collector-node.sh write collector-node.json";
  const remoteScript = [
    "set -euo pipefail",
    `cd ${shellQuote(bundle.remoteDeployDir)}`,
    command,
  ].join("\n");
  const result = runSsh(bundle, `bash -lc ${shellQuote(remoteScript)}`);
  let remoteJson;
  try {
    remoteJson = JSON.parse(result.stdout);
  } catch {
    remoteJson = undefined;
  }
  return {
    status: bootstrapMode === "plan" ? "bootstrap_plan_completed" : "bootstrap_written",
    completedAt: new Date().toISOString(),
    remoteResult: remoteJson,
    remoteStdout: result.stdout.trim(),
    remoteStderr: result.stderr.trim(),
  };
}

function parseLastJsonLine(text) {
  const lines = String(text || "").trim().split(/\r?\n/).filter(Boolean).reverse();
  for (const line of lines) {
    try {
      return JSON.parse(line);
    } catch {
      // 远端脚本可能先输出 docker compose 日志；只解析最后的 JSON 行。
    }
  }
  return undefined;
}

function runSnapshot(bundle) {
  if (confirmSnapshot !== "I_UNDERSTAND_THIS_RUNS_REMOTE_COLLECTOR_SNAPSHOT_ONLY") {
    fail("必须设置 CONFIRM_REMOTE_COLLECTOR_NODE_SNAPSHOT=I_UNDERSTAND_THIS_RUNS_REMOTE_COLLECTOR_SNAPSHOT_ONLY");
  }
  const remoteScript = [
    "set -euo pipefail",
    `cd ${shellQuote(bundle.remoteDeployDir)}`,
    "./collector-snapshot.sh",
  ].join("\n");
  const result = runSsh(bundle, `bash -lc ${shellQuote(remoteScript)}`);
  return {
    status: "snapshot_completed",
    completedAt: new Date().toISOString(),
    remoteResult: parseLastJsonLine(result.stdout),
    remoteStdout: result.stdout.trim(),
    remoteStderr: result.stderr.trim(),
  };
}

function runInstallCron(bundle) {
  if (confirmCron !== "I_UNDERSTAND_THIS_ONLY_INSTALLS_REMOTE_COLLECTOR_CRON") {
    fail("必须设置 CONFIRM_REMOTE_COLLECTOR_NODE_CRON=I_UNDERSTAND_THIS_ONLY_INSTALLS_REMOTE_COLLECTOR_CRON");
  }
  const remoteScript = [
    "set -euo pipefail",
    `cd ${shellQuote(bundle.remoteDeployDir)}`,
    "./install-collector-cron.sh",
  ].join("\n");
  const result = runSsh(bundle, `bash -lc ${shellQuote(remoteScript)}`);
  return {
    status: "cron_installed",
    completedAt: new Date().toISOString(),
    remoteStdout: result.stdout.trim(),
    remoteStderr: result.stderr.trim(),
  };
}

function safetyFor(modeName) {
  return {
    planOnly: modeName === "plan",
    connectsSsh: modeName !== "plan",
    writesTomRegistry: false,
    writesRemoteBundle: modeName === "sync",
    writesRemoteCollectorNode: modeName === "sync" || modeName === "bootstrap-write",
    writesRemoteCollectorRuntime: modeName === "snapshot",
    startsCollectorContainer: modeName === "snapshot",
    writesOpenClawInstanceDirs: false,
    startsContainers: modeName === "snapshot",
    installsCron: modeName === "install-cron",
    mutatesOpenClawInstance: false,
    restartsOpenClawInstance: false,
    callsLiveApi: false,
  };
}

function buildBaseOutput(bundle, modeName) {
  return {
    mode: modeName,
    bundleDir: bundle.bundleDir,
    serverId: bundle.serverId,
    serverName: bundle.serverName,
    remoteTarget: {
      host: bundle.source.host,
      user: bundle.source.user,
      port: bundle.source.port,
      deployDir: bundle.remoteDeployDir,
      sshKey: bundle.source.sshKey || "",
      knownHostsFile: bundle.source.knownHostsFile,
      strictHostKeyChecking: bundle.source.strictHostKeyChecking,
    },
    bundle: {
      files: bundle.files.length,
      bytes: bundle.totalBytes,
      required: [
        "collector-node.json",
        "bootstrap-collector-node.sh",
        "remote-collector-pull.sources.json",
        "register-remote-collector.json",
        "RUNBOOK.md",
        "safety.json",
      ],
      hasBuildContext: bundle.files.some((file) => file.path.startsWith("build-context/")),
    },
    nextActions: [
      `CONFIRM_REMOTE_COLLECTOR_NODE_SYNC=I_UNDERSTAND_THIS_ONLY_COPIES_COLLECTOR_BUNDLE_TO_REMOTE repo/ops/tom-readonly/remote-collector-node-sync.sh sync ${path.relative(deployDir, bundle.bundleDir)}`,
      `CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_PLAN=I_UNDERSTAND_THIS_ONLY_RUNS_REMOTE_BOOTSTRAP_PLAN repo/ops/tom-readonly/remote-collector-node-sync.sh bootstrap-plan ${path.relative(deployDir, bundle.bundleDir)}`,
      `CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_WRITE=I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_COLLECTOR_NODE_FILES repo/ops/tom-readonly/remote-collector-node-sync.sh bootstrap-write ${path.relative(deployDir, bundle.bundleDir)}`,
      `CONFIRM_REMOTE_COLLECTOR_NODE_SNAPSHOT=I_UNDERSTAND_THIS_RUNS_REMOTE_COLLECTOR_SNAPSHOT_ONLY repo/ops/tom-readonly/remote-collector-node-sync.sh snapshot ${path.relative(deployDir, bundle.bundleDir)}`,
      `CONFIRM_REMOTE_COLLECTOR_NODE_CRON=I_UNDERSTAND_THIS_ONLY_INSTALLS_REMOTE_COLLECTOR_CRON repo/ops/tom-readonly/remote-collector-node-sync.sh install-cron ${path.relative(deployDir, bundle.bundleDir)}`,
      "# 然后回到 Tom 执行 remote-collector-pull.sh pull。",
    ],
    safety: safetyFor(modeName),
  };
}

function formatError(error) {
  return error instanceof Error ? error.message : String(error);
}

let bundle;
try {
  bundle = loadBundle();
  if (mode === "plan") {
    console.log(JSON.stringify({
      status: "planned",
      ...buildBaseOutput(bundle, mode),
    }, null, 2));
  } else if (mode === "sync") {
    const result = runSync(bundle);
    console.log(JSON.stringify({
      ...result,
      ...buildBaseOutput(bundle, mode),
    }, null, 2));
  } else if (mode === "bootstrap-plan") {
    const result = runBootstrap(bundle, "plan");
    console.log(JSON.stringify({
      ...result,
      ...buildBaseOutput(bundle, mode),
    }, null, 2));
  } else if (mode === "bootstrap-write") {
    const result = runBootstrap(bundle, "write");
    console.log(JSON.stringify({
      ...result,
      ...buildBaseOutput(bundle, mode),
    }, null, 2));
  } else if (mode === "snapshot") {
    const result = runSnapshot(bundle);
    console.log(JSON.stringify({
      ...result,
      ...buildBaseOutput(bundle, mode),
    }, null, 2));
  } else if (mode === "install-cron") {
    const result = runInstallCron(bundle);
    console.log(JSON.stringify({
      ...result,
      ...buildBaseOutput(bundle, mode),
    }, null, 2));
  } else {
    fail(`未知模式：${mode}`);
  }
} catch (error) {
  fail(formatError(error));
}
NODE
}

main() {
  require_command node
  case "${1:-plan}" in
    plan|sync|bootstrap-plan|bootstrap-write|snapshot|install-cron)
      run_node "${1:-plan}" "${2:-$BUNDLE_DIR}"
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
