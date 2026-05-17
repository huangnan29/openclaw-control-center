#!/usr/bin/env bash
set -euo pipefail
set +x

# 远端 Oracle collector-only 节点引导器。
# plan 只校验配置并输出将要生成的文件，不写入、不启动容器。
# write 只写 collector-only 部署文件，不启动容器、不修改任何 OpenClaw 实例目录。

CONFIG_FILE="${CONFIG_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/collector-node.example.json}"
CONFIRM_COLLECTOR_NODE_WRITE="${CONFIRM_COLLECTOR_NODE_WRITE:-}"

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
  bootstrap-collector-node.sh plan [collector-node.json]
  bootstrap-collector-node.sh write [collector-node.json]

说明：
  plan 只校验配置并输出将要生成的 collector-only 部署文件。
  write 只写 docker-compose、instances.json、collector-snapshot.sh 和 cron 安装脚本。
  write 不会启动容器，不会执行 collector，不会修改任何 OpenClaw 实例目录。

安全确认：
  write 必须设置：
    CONFIRM_COLLECTOR_NODE_WRITE=I_UNDERSTAND_THIS_ONLY_WRITES_COLLECTOR_NODE_FILES

配置样板：
  ops/collector-node/collector-node.example.json
TEXT
}

run_node() {
  local mode="$1"
  local config="${2:-$CONFIG_FILE}"
  MODE="$mode" \
    CONFIG_FILE="$config" \
    CONFIRM_COLLECTOR_NODE_WRITE="$CONFIRM_COLLECTOR_NODE_WRITE" \
    node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const mode = process.env.MODE || "plan";
const configFile = path.resolve(process.env.CONFIG_FILE || "");
const confirm = process.env.CONFIRM_COLLECTOR_NODE_WRITE || "";
const idPattern = /^[a-z0-9_-]+$/;

function fail(message) {
  console.error(`[失败] ${message}`);
  process.exit(2);
}

function readJson(file) {
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

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function yamlQuote(value) {
  return `"${String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

function loadConfig() {
  const raw = readJson(configFile);
  const config = asRecord(raw);
  if (!config) fail("配置必须是 JSON object");
  if (config.schemaVersion !== 1) fail("schemaVersion 必须为 1");

  const server = asRecord(config.server);
  if (!server) fail("server 必须是 object");
  const serverId = readId(server.id, "server.id");
  const serverName = readName(server.name, "server.name");
  const deployDir = readAbsolutePath(config.deployDir || "/srv/openclaw-collector-node", "deployDir");
  const buildContext = readOptionalAbsolutePath(config.buildContext, "buildContext");
  const image = readName(config.image || "openclaw-control-center:collector-node", "image");
  const collectorContainerName = readName(config.collectorContainerName || `openclaw-collector-${serverId}`, "collectorContainerName");
  const snapshotOutputPath = readString(config.snapshotOutputPath) ||
    `/app/runtime/collectors/${serverId}/snapshot.json`;
  if (!snapshotOutputPath.startsWith("/app/runtime/collectors/")) {
    fail("snapshotOutputPath 必须位于 /app/runtime/collectors/ 之下");
  }
  const cronSchedule = readName(config.cronSchedule || "*/2 * * * *", "cronSchedule");

  const instanceEntries = Array.isArray(config.instances) ? config.instances : undefined;
  if (!instanceEntries || instanceEntries.length === 0) fail("instances 必须是非空数组");

  const seen = new Set();
  const instances = instanceEntries.map((entry, index) => {
    const item = asRecord(entry);
    if (!item) throw new Error(`instances[${index}] 必须是 object`);
    const id = readId(item.id, `instances[${index}].id`);
    if (seen.has(id)) throw new Error(`重复实例 id：${id}`);
    seen.add(id);
    const name = readName(item.name || id, `instances[${index}].name`);
    const gatewayUrl = readName(item.gatewayUrl, `instances[${index}].gatewayUrl`);
    const configDir = readAbsolutePath(item.configDir, `instances[${index}].configDir`);
    const workspaceDir = readAbsolutePath(item.workspaceDir, `instances[${index}].workspaceDir`);
    const codexDir = readOptionalAbsolutePath(item.codexDir, `instances[${index}].codexDir`);
    return { id, name, gatewayUrl, configDir, workspaceDir, ...(codexDir ? { codexDir } : {}) };
  });

  return {
    schemaVersion: 1,
    server: {
      id: serverId,
      name: serverName,
      ...(readOptionalName(server.host, "server.host") ? { host: readOptionalName(server.host, "server.host") } : {}),
      ...(readOptionalName(server.region, "server.region") ? { region: readOptionalName(server.region, "server.region") } : {}),
      collectorSnapshotPath: snapshotOutputPath,
    },
    deployDir,
    image,
    buildContext,
    collectorContainerName,
    snapshotOutputPath,
    cronSchedule,
    instances,
  };
}

function buildInstancesJson(config) {
  return {
    servers: [
      {
        ...config.server,
        instances: config.instances.map((instance) => ({
          id: instance.id,
          name: instance.name,
          gatewayUrl: instance.gatewayUrl,
          openclawHome: `/instances/${instance.id}/config`,
          workspaceRoot: `/instances/${instance.id}/workspace`,
          readonly: true,
        })),
      },
    ],
  };
}

function buildCompose(config) {
  const lines = [];
  lines.push("services:");
  lines.push("  collector:");
  lines.push(`    image: ${yamlQuote(config.image)}`);
  if (config.buildContext) {
    lines.push("    build:");
    lines.push(`      context: ${yamlQuote(config.buildContext)}`);
    lines.push('      dockerfile: "Dockerfile"');
  }
  lines.push(`    container_name: ${yamlQuote(config.collectorContainerName)}`);
  lines.push('    restart: "unless-stopped"');
  lines.push('    command: ["sh", "-lc", "while sleep 3600; do :; done"]');
  lines.push("    extra_hosts:");
  lines.push('      - "host.docker.internal:host-gateway"');
  lines.push("    environment:");
  lines.push('      UI_MODE: "false"');
  lines.push('      READONLY_MODE: "true"');
  lines.push('      APPROVAL_ACTIONS_ENABLED: "false"');
  lines.push('      APPROVAL_ACTIONS_DRY_RUN: "true"');
  lines.push('      IMPORT_MUTATION_ENABLED: "false"');
  lines.push('      IMPORT_MUTATION_DRY_RUN: "true"');
  lines.push('      TASK_HEARTBEAT_ENABLED: "false"');
  lines.push('      HALL_RUNTIME_DISPATCH_ENABLED: "false"');
  lines.push('      HALL_RUNTIME_DIRECT_STREAM_ENABLED: "false"');
  lines.push('      LOCAL_TOKEN_AUTH_REQUIRED: "true"');
  lines.push('      OPENCLAW_INSTANCES_FILE: "/app/config/instances.json"');
  lines.push(`      OPENCLAW_COLLECTOR_SERVER_ID: ${yamlQuote(config.server.id)}`);
  lines.push("    volumes:");
  lines.push('      - "./runtime:/app/runtime"');
  lines.push('      - "./config/instances.json:/app/config/instances.json:ro"');
  for (const instance of config.instances) {
    lines.push(`      - ${yamlQuote(`${instance.configDir}:/instances/${instance.id}/config:ro`)}`);
    lines.push(`      - ${yamlQuote(`${instance.workspaceDir}:/instances/${instance.id}/workspace:ro`)}`);
    if (instance.codexDir) {
      lines.push(`      - ${yamlQuote(`${instance.codexDir}:/instances/${instance.id}/codex:ro`)}`);
    }
  }
  return `${lines.join("\n")}\n`;
}

function buildCollectorScript(config) {
  const composeFile = path.join(config.deployDir, "docker-compose.collector.yml");
  return `#!/usr/bin/env bash
set -euo pipefail

# collector-only 快照生成脚本。只读取只读挂载的数据，并写入本机 runtime。

DEPLOY_DIR=${shellQuote(config.deployDir)}
COMPOSE_FILE=${shellQuote(composeFile)}
SERVICE_NAME="collector"
SERVER_ID=${shellQuote(config.server.id)}
OUTPUT_PATH=${shellQuote(config.snapshotOutputPath)}

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    printf '[失败] 缺少 docker compose 或 docker-compose\\n' >&2
    exit 1
  fi
}

cd "$DEPLOY_DIR"
compose -f "$COMPOSE_FILE" up -d --build "$SERVICE_NAME"
compose -f "$COMPOSE_FILE" exec -T \\
  -e OPENCLAW_COLLECTOR_SERVER_ID="$SERVER_ID" \\
  "$SERVICE_NAME" \\
  node dist/index.js collector-snapshot "$OUTPUT_PATH"
compose -f "$COMPOSE_FILE" exec -T "$SERVICE_NAME" test -s "$OUTPUT_PATH"
compose -f "$COMPOSE_FILE" exec -T "$SERVICE_NAME" node -e 'const fs=require("fs"); const s=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); if (s.serverId !== process.argv[2]) process.exit(2); if (!Array.isArray(s.instances) || s.instances.length === 0) process.exit(3); console.log(JSON.stringify({serverId:s.serverId, instances:s.instances.length, generatedAt:s.generatedAt}))' "$OUTPUT_PATH" "$SERVER_ID"
`;
}

function buildCronScript(config) {
  return `#!/usr/bin/env bash
set -euo pipefail

# collector-only cron 安装器。只更新当前用户 crontab 中的受控标记块。

DEPLOY_DIR=${shellQuote(config.deployDir)}
LOG_PATH="$DEPLOY_DIR/runtime/collector-snapshot-cron.log"
CRON_SCHEDULE=${shellQuote(config.cronSchedule)}

command -v crontab >/dev/null 2>&1 || { printf '[失败] 缺少 crontab\\n' >&2; exit 1; }
mkdir -p "$(dirname "$LOG_PATH")"

existing="$(crontab -l 2>/dev/null || true)"
cleaned="$(printf '%s\\n' "$existing" | awk '
  $0 == "# OPENCLAW_COLLECTOR_NODE_CRON_BEGIN" { skip = 1; next }
  $0 == "# OPENCLAW_COLLECTOR_NODE_CRON_END" { skip = 0; next }
  skip != 1 { print }
')"

{
  if [ -n "$cleaned" ]; then
    printf '%s\\n' "$cleaned"
  fi
  printf '# OPENCLAW_COLLECTOR_NODE_CRON_BEGIN\\n'
  printf 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\\n'
  printf '%s cd %s && ./collector-snapshot.sh >> %s 2>&1\\n' "$CRON_SCHEDULE" ${shellQuote(config.deployDir)} "$LOG_PATH"
  printf '# OPENCLAW_COLLECTOR_NODE_CRON_END\\n'
} | crontab -

printf '[完成] 已安装 collector-only cron：%s\\n' "$CRON_SCHEDULE"
`;
}

function assertGeneratedFilesAreSafe(files) {
  const combined = Object.values(files).join("\n");
  if (combined.includes("/var/run/docker.sock")) throw new Error("生成文件不能挂载 docker.sock");
  if (/privileged\s*:\s*true/.test(combined)) throw new Error("生成文件不能启用 privileged");
  if (/ports\s*:/.test(combined)) throw new Error("collector-only compose 不能暴露端口");
  for (const mount of combined.matchAll(/:(rw)(?:["\n]|$)/g)) {
    throw new Error(`生成文件存在可写挂载：${mount[0]}`);
  }
}

function buildFiles(config) {
  const files = {
    [path.join(config.deployDir, "config", "instances.json")]: `${JSON.stringify(buildInstancesJson(config), null, 2)}\n`,
    [path.join(config.deployDir, "docker-compose.collector.yml")]: buildCompose(config),
    [path.join(config.deployDir, "collector-snapshot.sh")]: buildCollectorScript(config),
    [path.join(config.deployDir, "install-collector-cron.sh")]: buildCronScript(config),
  };
  assertGeneratedFilesAreSafe(files);
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
try {
  config = loadConfig();
} catch (error) {
  fail(formatError(error));
}
const files = buildFiles(config);

if (mode === "plan") {
  console.log(JSON.stringify({
    status: "planned",
    configFile,
    deployDir: config.deployDir,
    serverId: config.server.id,
    instances: config.instances.map((instance) => ({
      id: instance.id,
      name: instance.name,
      gatewayUrl: instance.gatewayUrl,
      configDir: instance.configDir,
      workspaceDir: instance.workspaceDir,
    })),
    files: Object.keys(files),
    safety: {
      writesFilesOnly: true,
      startsContainers: false,
      mutatesOpenClawInstance: false,
      exposesPorts: false,
      mountsDockerSock: false,
    },
  }, null, 2));
} else if (mode === "write") {
  if (confirm !== "I_UNDERSTAND_THIS_ONLY_WRITES_COLLECTOR_NODE_FILES") {
    fail("必须设置 CONFIRM_COLLECTOR_NODE_WRITE=I_UNDERSTAND_THIS_ONLY_WRITES_COLLECTOR_NODE_FILES");
  }
  writeFiles(files);
  console.log(JSON.stringify({
    status: "written",
    deployDir: config.deployDir,
    serverId: config.server.id,
    files: Object.keys(files),
    nextActions: [
      `cd ${config.deployDir} && ./collector-snapshot.sh`,
      `cd ${config.deployDir} && ./install-collector-cron.sh`,
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
