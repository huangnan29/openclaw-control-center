#!/usr/bin/env bash
set -euo pipefail
set +x

# 实例影响快照：用于 live 演练前后留证。
# 只读取 gateway 健康、监听端口和控制中心容器边界，不修改任何 OpenClaw 实例目录。

DEPLOY_DIR="${DEPLOY_DIR:-/srv/openclaw-control-center-readonly}"
CONTAINER_NAME="${CONTAINER_NAME:-openclaw-control-center-readonly}"
BASE_URL="${BASE_URL:-http://127.0.0.1:4311}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-${DEPLOY_DIR}/runtime/impact-snapshots}"
GATEWAY_PORTS="${GATEWAY_PORTS:-18789 18791 18793 18795 18797}"
INSTANCE_MOUNTS="${INSTANCE_MOUNTS:-/instances/main/config /instances/main/workspace /instances/tom/config /instances/tom/workspace /instances/third/config /instances/third/workspace /instances/deepseek/config /instances/deepseek/workspace /instances/spark/config /instances/spark/workspace}"

timestamp() {
  date +"%Y-%m-%dT%H:%M:%S%z"
}

safe_timestamp() {
  date +"%Y%m%dT%H%M%S%z"
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

snapshot() {
  local label="${1:-snapshot}"
  local safe_label
  safe_label="$(printf '%s' "$label" | tr -c 'A-Za-z0-9_.-' '-')"
  local output="${SNAPSHOT_DIR}/${safe_label}-$(safe_timestamp).json"

  mkdir -p "$SNAPSHOT_DIR"
  log "生成实例影响快照：${output}"

  DEPLOY_DIR="$DEPLOY_DIR" \
    CONTAINER_NAME="$CONTAINER_NAME" \
    BASE_URL="$BASE_URL" \
    GATEWAY_PORTS="$GATEWAY_PORTS" \
    INSTANCE_MOUNTS="$INSTANCE_MOUNTS" \
    node - "$output" <<'NODE'
const fs = require("node:fs");
const { execFileSync } = require("node:child_process");

const outputPath = process.argv[2];

function run(command, args, options = {}) {
  try {
    return {
      ok: true,
      stdout: execFileSync(command, args, {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
        timeout: options.timeoutMs ?? 5000,
      }).trim(),
      stderr: "",
    };
  } catch (error) {
    return {
      ok: false,
      stdout: typeof error.stdout === "string" ? error.stdout.trim() : "",
      stderr: typeof error.stderr === "string" ? error.stderr.trim() : error instanceof Error ? error.message : String(error),
    };
  }
}

function parseJson(text) {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

function readContainerInspect(containerName) {
  const result = run("docker", ["inspect", containerName]);
  if (!result.ok) {
    return {
      ok: false,
      error: result.stderr || result.stdout || "docker inspect failed",
      privileged: undefined,
      env: {},
      mounts: [],
      instanceMounts: [],
      dockerSockMounted: false,
    };
  }

  const parsed = parseJson(result.stdout);
  const inspect = Array.isArray(parsed) ? parsed[0] : undefined;
  const env = {};
  for (const item of inspect?.Config?.Env ?? []) {
    const index = String(item).indexOf("=");
    if (index > 0) env[String(item).slice(0, index)] = String(item).slice(index + 1);
  }

  const mounts = (inspect?.Mounts ?? []).map((item) => ({
    destination: item.Destination,
    rw: Boolean(item.RW),
  }));
  const expectedMounts = String(process.env.INSTANCE_MOUNTS || "")
    .split(/\s+/)
    .map((item) => item.trim())
    .filter(Boolean);

  return {
    ok: true,
    privileged: Boolean(inspect?.HostConfig?.Privileged),
    env: {
      READONLY_MODE: env.READONLY_MODE ?? null,
      MANAGED_ACTIONS_LIVE_ENABLED: env.MANAGED_ACTIONS_LIVE_ENABLED ?? null,
      MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED: env.MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED ?? null,
      MANAGED_ACTIONS_LIVE_ALLOWED_ACTIONS: env.MANAGED_ACTIONS_LIVE_ALLOWED_ACTIONS ?? null,
      MANAGED_ACTIONS_LIVE_SKILL_RUN_ALLOWED_SKILLS: env.MANAGED_ACTIONS_LIVE_SKILL_RUN_ALLOWED_SKILLS ?? null,
      MANAGED_ACTIONS_LIVE_SKILL_RUN_ALLOWED_INSTANCES: env.MANAGED_ACTIONS_LIVE_SKILL_RUN_ALLOWED_INSTANCES ?? null,
    },
    mounts,
    instanceMounts: expectedMounts.map((destination) => {
      const mount = mounts.find((item) => item.destination === destination);
      return {
        destination,
        present: Boolean(mount),
        rw: mount ? Boolean(mount.rw) : null,
      };
    }),
    dockerSockMounted: mounts.some((item) => item.destination === "/var/run/docker.sock"),
  };
}

function readGateway(port) {
  const url = `http://127.0.0.1:${port}/health`;
  const health = run("curl", ["-fsS", "--max-time", "3", url], { timeoutMs: 5000 });
  const parsed = health.ok ? parseJson(health.stdout) : undefined;
  const listener = run("ss", ["-H", "-ltnp", `sport = :${port}`], { timeoutMs: 5000 });
  return {
    port,
    healthOk: Boolean(parsed?.ok === true),
    healthStatus: typeof parsed?.status === "string" ? parsed.status : null,
    healthRaw: health.stdout,
    healthError: health.ok ? null : health.stderr || health.stdout || "curl failed",
    listenerOk: listener.ok && listener.stdout.length > 0,
    listener: listener.stdout,
    listenerError: listener.ok ? null : listener.stderr || listener.stdout || "ss failed",
  };
}

function readReadiness(baseUrl) {
  const result = run("curl", ["-fsS", "--max-time", "3", `${baseUrl.replace(/\/$/, "")}/api/managed-actions/readiness`], {
    timeoutMs: 5000,
  });
  const parsed = result.ok ? parseJson(result.stdout) : undefined;
  return {
    ok: Boolean(result.ok && parsed),
    status: typeof parsed?.status === "string" ? parsed.status : null,
    liveExecutionAvailable: parsed?.liveExecutionAvailable === true,
    executorProductionWired: parsed?.executor?.productionWired === true,
    raw: result.stdout,
    error: result.ok ? null : result.stderr || result.stdout || "readiness failed",
  };
}

const gatewayPorts = String(process.env.GATEWAY_PORTS || "")
  .split(/\s+/)
  .map((item) => Number(item))
  .filter((item) => Number.isInteger(item) && item > 0);

const snapshot = {
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  host: run("hostname", []).stdout || null,
  repoCommit: run("git", ["-C", `${process.env.DEPLOY_DIR}/repo`, "rev-parse", "HEAD"]).stdout || null,
  controlCenter: readContainerInspect(process.env.CONTAINER_NAME),
  readiness: readReadiness(process.env.BASE_URL),
  gateways: gatewayPorts.map(readGateway),
};

fs.writeFileSync(outputPath, `${JSON.stringify(snapshot, null, 2)}\n`, "utf8");
process.stdout.write(`${outputPath}\n`);
NODE
}

compare_snapshots() {
  local before_path="${1:-}"
  local after_path="${2:-}"
  [ -f "$before_path" ] || fail "before 快照不存在：${before_path}"
  [ -f "$after_path" ] || fail "after 快照不存在：${after_path}"

  log "比较实例影响快照：${before_path} -> ${after_path}"
  node - "$before_path" "$after_path" <<'NODE'
const fs = require("node:fs");

const beforePath = process.argv[2];
const afterPath = process.argv[3];
const before = JSON.parse(fs.readFileSync(beforePath, "utf8"));
const after = JSON.parse(fs.readFileSync(afterPath, "utf8"));
const failures = [];

function fail(message) {
  failures.push(message);
}

function gatewayKey(item) {
  return String(item.port);
}

const beforeGateways = new Map((before.gateways ?? []).map((item) => [gatewayKey(item), item]));
const afterGateways = new Map((after.gateways ?? []).map((item) => [gatewayKey(item), item]));
for (const [port, item] of beforeGateways) {
  const next = afterGateways.get(port);
  if (!next) {
    fail(`after 快照缺少 gateway 端口：${port}`);
    continue;
  }
  if (item.healthOk !== true || next.healthOk !== true) fail(`gateway ${port} health 前后未保持 ok=true`);
  if (item.listenerOk !== true || next.listenerOk !== true) fail(`gateway ${port} 监听状态前后不可用`);
  if (String(item.listener || "") !== String(next.listener || "")) fail(`gateway ${port} 监听行发生变化`);
}

if (after.controlCenter?.ok !== true) fail("after 快照无法读取 control-center 容器");
if (after.controlCenter?.privileged !== false) fail("control-center 容器 privileged 非 false");
if (after.controlCenter?.dockerSockMounted === true) fail("control-center 容器挂载了 docker.sock");

for (const mount of after.controlCenter?.instanceMounts ?? []) {
  if (mount.present !== true) fail(`after 快照缺少实例挂载：${mount.destination}`);
  if (mount.rw !== false) fail(`after 快照实例挂载不是只读：${mount.destination}`);
}

if (after.controlCenter?.env?.READONLY_MODE !== "true") fail("after 快照 READONLY_MODE 未恢复为 true");
if (after.controlCenter?.env?.MANAGED_ACTIONS_LIVE_ENABLED === "true") fail("after 快照 live gate 仍为 true");
if (after.controlCenter?.env?.MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED === "true") fail("after 快照 live executor 仍为 true");

if (after.readiness?.ok !== true) fail("after 快照 readiness 不可用");
if (after.readiness?.liveExecutionAvailable !== false) fail("after 快照 liveExecutionAvailable 未恢复为 false");
if (after.readiness?.executorProductionWired !== false) fail("after 快照 executorProductionWired 未恢复为 false");

if (failures.length > 0) {
  for (const message of failures) console.error(`[失败] ${message}`);
  process.exit(2);
}

console.log(`实例影响比较通过：before=${beforePath} after=${afterPath}`);
NODE
}

compare_controlled_live_snapshots() {
  local before_path="${1:-}"
  local after_path="${2:-}"
  [ -f "$before_path" ] || fail "before 快照不存在：${before_path}"
  [ -f "$after_path" ] || fail "after 快照不存在：${after_path}"

  log "比较受控 live 实例影响快照：${before_path} -> ${after_path}"
  node - "$before_path" "$after_path" <<'NODE'
const fs = require("node:fs");

const beforePath = process.argv[2];
const afterPath = process.argv[3];
const before = JSON.parse(fs.readFileSync(beforePath, "utf8"));
const after = JSON.parse(fs.readFileSync(afterPath, "utf8"));
const failures = [];

function fail(message) {
  failures.push(message);
}

function gatewayKey(item) {
  return String(item.port);
}

const beforeGateways = new Map((before.gateways ?? []).map((item) => [gatewayKey(item), item]));
const afterGateways = new Map((after.gateways ?? []).map((item) => [gatewayKey(item), item]));
for (const [port, item] of beforeGateways) {
  const next = afterGateways.get(port);
  if (!next) {
    fail(`after 快照缺少 gateway 端口：${port}`);
    continue;
  }
  if (item.healthOk !== true || next.healthOk !== true) fail(`gateway ${port} health 前后未保持 ok=true`);
  if (item.listenerOk !== true || next.listenerOk !== true) fail(`gateway ${port} 监听状态前后不可用`);
  if (String(item.listener || "") !== String(next.listener || "")) fail(`gateway ${port} 监听行发生变化`);
}

if (after.controlCenter?.ok !== true) fail("after 快照无法读取 control-center 容器");
if (after.controlCenter?.privileged !== false) fail("control-center 容器 privileged 非 false");
if (after.controlCenter?.dockerSockMounted === true) fail("control-center 容器挂载了 docker.sock");

const beforeMounts = new Map((before.controlCenter?.instanceMounts ?? []).map((item) => [item.destination, item]));
for (const mount of after.controlCenter?.instanceMounts ?? []) {
  const previous = beforeMounts.get(mount.destination);
  if (!previous) {
    fail(`after 快照出现新增实例挂载：${mount.destination}`);
    continue;
  }
  if (mount.present !== true) fail(`after 快照缺少实例挂载：${mount.destination}`);
  if (mount.rw !== previous.rw) {
    fail(`实例挂载读写属性发生变化：${mount.destination} before=${previous.rw} after=${mount.rw}`);
  }
}

const env = after.controlCenter?.env ?? {};
if (env.READONLY_MODE !== "false") fail("受控 live 模式下 READONLY_MODE 应为 false");
if (env.MANAGED_ACTIONS_LIVE_ENABLED !== "true") fail("受控 live 模式下 live gate 应为 true");
if (env.MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED !== "true") fail("受控 live 模式下 live executor 应为 true");
const actions = String(env.MANAGED_ACTIONS_LIVE_ALLOWED_ACTIONS || "")
  .split(",")
  .map((item) => item.trim())
  .filter(Boolean);
const hasSkillRun = actions.includes("skill_run");
const unsafe = actions.filter((item) => !["healthcheck", "collector_refresh", "skill_run"].includes(item));
if (unsafe.length > 0) fail(`受控 live 白名单包含未知动作：${[...new Set(unsafe)].join(",")}`);
if (hasSkillRun) {
  if (env.MANAGED_ACTIONS_LIVE_SKILL_RUN_ALLOWED_SKILLS !== "zhihu-human-ops-writing") {
    fail(`skill_run live 技能 allowlist 超出边界：${env.MANAGED_ACTIONS_LIVE_SKILL_RUN_ALLOWED_SKILLS || "<unset>"}`);
  }
  if (env.MANAGED_ACTIONS_LIVE_SKILL_RUN_ALLOWED_INSTANCES !== "tom") {
    fail(`skill_run live 实例 allowlist 超出边界：${env.MANAGED_ACTIONS_LIVE_SKILL_RUN_ALLOWED_INSTANCES || "<unset>"}`);
  }
}

if (after.readiness?.ok !== true) fail("after 快照 readiness 不可用");
if (after.readiness?.liveExecutionAvailable !== true) fail("受控 live 模式下 liveExecutionAvailable 应为 true");
if (after.readiness?.executorProductionWired !== true) fail("受控 live 模式下 executorProductionWired 应为 true");

if (failures.length > 0) {
  for (const message of failures) console.error(`[失败] ${message}`);
  process.exit(2);
}

console.log(`受控 live 实例影响比较通过：before=${beforePath} after=${afterPath}`);
NODE
}

usage() {
  cat <<'TEXT'
用法：
  instance-impact-snapshot.sh snapshot [label]
  instance-impact-snapshot.sh compare <before.json> <after.json>
  instance-impact-snapshot.sh compare-controlled-live <before.json> <after.json>

说明：
  snapshot 只读取 gateway health、监听端口、control-center 容器挂载和 readiness。
  compare 要求 after 恢复为只读状态，且 gateway 健康与监听状态保持稳定。
  compare-controlled-live 用于长期受控 live 模式，要求 gateway 稳定、实例挂载读写属性不变、live 白名单仅包含低风险动作。
TEXT
}

main() {
  require_command node
  require_command curl
  require_command docker
  require_command ss

  case "${1:-snapshot}" in
    snapshot)
      snapshot "${2:-snapshot}"
      ;;
    compare)
      compare_snapshots "${2:-}" "${3:-}"
      ;;
    compare-controlled-live)
      compare_controlled_live_snapshots "${2:-}" "${3:-}"
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
