# 只读多实例控制中心 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `openclaw-control-center` 升级为严格只读的多实例控制台，支持总览 Oracle Tom 上多套 OpenClaw 实例，并进入每个实例的完整详情页。

**Architecture:** 新增多实例配置层、scoped OpenClaw client、multi-instance adapter 和 UI 实例选择器。现有 `ReadModelSnapshot` 保持不变，多实例层只包裹多个单实例 snapshot，以降低对现有 dashboard 渲染逻辑的冲击。

**Tech Stack:** TypeScript、Node.js 内置 `node:test`、现有 OpenClaw CLI 读取路径、现有 UI server HTML 渲染。

---

## 文件结构

- Create: `src/runtime/instance-config.ts`  
  解析 `OPENCLAW_INSTANCES_FILE`、`OPENCLAW_INSTANCES_JSON` 和单实例 fallback。
- Create: `src/runtime/multi-instance-summary.ts`  
  聚合多实例状态卡和全局总览计数。
- Create: `src/adapters/multi-instance-readonly.ts`  
  按实例生成 `ReadModelSnapshot`，单实例失败不拖垮全局。
- Modify: `src/types.ts`  
  增加 `OpenClawInstanceConfig`、`InstanceSnapshot`、`MultiInstanceSnapshot` 等类型。
- Modify: `src/runtime/current-agent-catalog.ts`  
  允许按实例传入 `openclawHome` 和 `configPath`，保留现有无参数调用。
- Modify: `src/clients/openclaw-live-client.ts`  
  增加 scoped constructor，读指定实例的 OpenClaw home/config/workspace，保持默认单实例行为。
- Modify: `src/clients/factory.ts`  
  提供默认 client 和 scoped client 的工厂函数。
- Modify: `src/ui/server.ts`  
  增加多实例总览、实例切换、按 `?instance=` 读取详情 snapshot，并在只读模式隐藏或拒绝写入口。
- Modify: `src/config.ts`  
  暴露多实例配置环境变量名和只读安全 gate。
- Modify: `.env.example`  
  增加多实例配置示例和只读部署推荐。
- Modify: `docker-compose.example.yml`  
  增加 Tom 多实例只读挂载示例。
- Create: `test/instance-config.test.ts`
- Create: `test/multi-instance-summary.test.ts`
- Create: `test/multi-instance-readonly.test.ts`
- Modify: `test/agent-roster.test.ts`
- Modify: `test/ui-render-smoke.test.ts`
- Modify: `test/oss-readiness.test.ts`

## 预备任务：建立真实 git 工作区

当前本地源码来自 GitHub zip，用于读代码和写文档。实施代码前必须建立真实 git 工作区，避免后续提交变成孤立历史。

- [ ] **Step 1: 创建或修复真实 git 工作区**

Run:

```bash
cd /Users/anan
rm -rf /Users/anan/openclaw-control-center-git
git clone --filter=blob:none --depth=1 --branch multi-instance-readonly-control-center https://github.com/huangnan29/openclaw-control-center.git /Users/anan/openclaw-control-center-git
cd /Users/anan/openclaw-control-center-git
git remote add upstream https://github.com/TianyiDataScience/openclaw-control-center.git || true
git status --short
```

Expected: `git status --short` 无输出，当前分支为 `multi-instance-readonly-control-center`。

- [ ] **Step 2: 如果 git clone 继续卡住，使用 GitHub API 拉取分支源码并初始化本地 git**

Run:

```bash
cd /Users/anan
rm -rf /Users/anan/openclaw-control-center-git /tmp/openclaw-control-center-branch.zip /tmp/openclaw-control-center-branch
curl -L -o /tmp/openclaw-control-center-branch.zip https://codeload.github.com/huangnan29/openclaw-control-center/zip/refs/heads/multi-instance-readonly-control-center
unzip -q /tmp/openclaw-control-center-branch.zip -d /tmp/openclaw-control-center-branch
mv /tmp/openclaw-control-center-branch/openclaw-control-center-multi-instance-readonly-control-center /Users/anan/openclaw-control-center-git
cd /Users/anan/openclaw-control-center-git
git init
git remote add origin https://github.com/huangnan29/openclaw-control-center.git
git checkout -b multi-instance-readonly-control-center
git add .
git commit -m "chore: initialize branch workspace from fork snapshot"
```

Expected: 本地可产生普通 git commit。最终提交仍优先用正常 `git push`；如果 push 失败，再用 GitHub API 提交补丁。

- [ ] **Step 3: 安装依赖并确认基线**

Run:

```bash
cd /Users/anan/openclaw-control-center-git
npm install
npm test
npm run build
```

Expected: 基线测试和构建通过。如果失败，先记录失败测试名称和错误，再判断是否为上游既有问题。

## Task 1: 多实例配置解析

**Files:**
- Create: `src/runtime/instance-config.ts`
- Modify: `src/types.ts`
- Modify: `src/config.ts`
- Create: `test/instance-config.test.ts`

- [ ] **Step 1: 写失败测试**

Create `test/instance-config.test.ts`:

```ts
import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  loadOpenClawInstanceConfigs,
  parseOpenClawInstanceConfigText,
} from "../src/runtime/instance-config";

test("parseOpenClawInstanceConfigText accepts multiple readonly instances", () => {
  const parsed = parseOpenClawInstanceConfigText(JSON.stringify({
    instances: [
      {
        id: "main",
        name: "Main",
        openclawHome: "/instances/main/config",
        workspaceRoot: "/instances/main/workspace",
        gatewayUrl: "ws://127.0.0.1:18789",
      },
      {
        id: "tom",
        name: "Tom / Work",
        openclawHome: "/instances/tom/config",
        workspaceRoot: "/instances/tom/workspace",
      },
    ],
  }), "inline");

  assert.equal(parsed.issues.length, 0);
  assert.equal(parsed.instances.length, 2);
  assert.deepEqual(parsed.instances.map((item) => item.id), ["main", "tom"]);
  assert.equal(parsed.instances[0].openclawConfigPath, "/instances/main/config/openclaw.json");
});

test("parseOpenClawInstanceConfigText rejects duplicate and unsafe ids", () => {
  const parsed = parseOpenClawInstanceConfigText(JSON.stringify({
    instances: [
      { id: "tom", name: "Tom", openclawHome: "/instances/tom/config" },
      { id: "tom", name: "Duplicate", openclawHome: "/instances/dupe/config" },
      { id: "../bad", name: "Bad", openclawHome: "/instances/bad/config" },
    ],
  }), "inline");

  assert.equal(parsed.instances.length, 1);
  assert(parsed.issues.some((issue) => issue.includes("duplicate id: tom")));
  assert(parsed.issues.some((issue) => issue.includes("invalid id: ../bad")));
});

test("loadOpenClawInstanceConfigs falls back to default single instance", async () => {
  const loaded = await loadOpenClawInstanceConfigs({
    env: {
      GATEWAY_URL: "ws://127.0.0.1:19999",
      OPENCLAW_HOME: "/tmp/openclaw-home",
      OPENCLAW_WORKSPACE_ROOT: "/tmp/openclaw-workspace",
    },
  });

  assert.equal(loaded.instances.length, 1);
  assert.equal(loaded.instances[0].id, "default");
  assert.equal(loaded.instances[0].gatewayUrl, "ws://127.0.0.1:19999");
  assert.equal(loaded.instances[0].openclawHome, "/tmp/openclaw-home");
  assert.equal(loaded.instances[0].workspaceRoot, "/tmp/openclaw-workspace");
});

test("loadOpenClawInstanceConfigs reads OPENCLAW_INSTANCES_FILE", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-instances-"));
  const file = join(dir, "instances.json");
  await writeFile(file, JSON.stringify({
    instances: [
      { id: "spark", name: "Spark", openclawHome: "/instances/spark/config" },
    ],
  }), "utf8");

  const loaded = await loadOpenClawInstanceConfigs({
    env: { OPENCLAW_INSTANCES_FILE: file },
  });

  assert.equal(loaded.instances.length, 1);
  assert.equal(loaded.instances[0].id, "spark");
  assert.equal(loaded.source, file);
});
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```bash
npm test -- test/instance-config.test.ts
```

Expected: FAIL，提示找不到 `../src/runtime/instance-config` 或导出函数不存在。

- [ ] **Step 3: 增加类型**

Modify `src/types.ts` near `ReadModelSnapshot`:

```ts
export type InstanceConnectionStatus = "connected" | "partial" | "not_connected";

export interface OpenClawInstanceConfig {
  id: string;
  name: string;
  gatewayUrl?: string;
  openclawHome: string;
  openclawConfigPath: string;
  workspaceRoot?: string;
}

export interface OpenClawInstanceConfigLoadResult {
  source: string;
  instances: OpenClawInstanceConfig[];
  issues: string[];
}

export interface InstanceSnapshot {
  instance: OpenClawInstanceConfig;
  status: InstanceConnectionStatus;
  detail: string;
  snapshot: ReadModelSnapshot;
}

export interface MultiInstanceSnapshot {
  generatedAt: string;
  selectedInstanceId: string;
  instances: InstanceSnapshot[];
  totals: {
    instances: number;
    connected: number;
    partial: number;
    notConnected: number;
    sessions: number;
    running: number;
    blocked: number;
    errors: number;
    pendingApprovals: number;
    cronJobs: number;
  };
}
```

- [ ] **Step 4: 增加配置环境变量导出**

Modify `src/config.ts` after `OPENCLAW_CONTROL_UI_URL`:

```ts
export const OPENCLAW_INSTANCES_FILE = readOptionalStringEnv(process.env.OPENCLAW_INSTANCES_FILE);
export const OPENCLAW_INSTANCES_JSON = readOptionalStringEnv(process.env.OPENCLAW_INSTANCES_JSON);
```

- [ ] **Step 5: 实现配置解析**

Create `src/runtime/instance-config.ts`:

```ts
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import type { OpenClawInstanceConfig, OpenClawInstanceConfigLoadResult } from "../types";

interface LoadInput {
  env?: NodeJS.ProcessEnv;
}

const SAFE_INSTANCE_ID = /^[a-z0-9_-]+$/;

export function parseOpenClawInstanceConfigText(
  text: string,
  source: string,
): OpenClawInstanceConfigLoadResult {
  const issues: string[] = [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch (error) {
    return {
      source,
      instances: [],
      issues: [`invalid JSON in ${source}: ${error instanceof Error ? error.message : String(error)}`],
    };
  }

  const root = asObject(parsed);
  const rows = Array.isArray(root?.instances) ? root.instances : [];
  if (rows.length === 0) {
    return { source, instances: [], issues: [`${source} has no instances array`] };
  }

  const seen = new Set<string>();
  const instances: OpenClawInstanceConfig[] = [];
  for (const row of rows) {
    const obj = asObject(row);
    const id = asString(obj?.id)?.trim();
    const name = asString(obj?.name)?.trim();
    const openclawHome = asString(obj?.openclawHome)?.trim();
    const workspaceRoot = asString(obj?.workspaceRoot)?.trim();
    const gatewayUrl = asString(obj?.gatewayUrl)?.trim();
    if (!id || !SAFE_INSTANCE_ID.test(id)) {
      issues.push(`invalid id: ${id ?? ""}`);
      continue;
    }
    if (seen.has(id)) {
      issues.push(`duplicate id: ${id}`);
      continue;
    }
    if (!name) {
      issues.push(`missing name for instance: ${id}`);
      continue;
    }
    if (!openclawHome) {
      issues.push(`missing openclawHome for instance: ${id}`);
      continue;
    }
    seen.add(id);
    instances.push({
      id,
      name,
      gatewayUrl: gatewayUrl || undefined,
      openclawHome,
      openclawConfigPath: join(openclawHome, "openclaw.json"),
      workspaceRoot: workspaceRoot || undefined,
    });
  }

  return { source, instances, issues };
}

export async function loadOpenClawInstanceConfigs(
  input: LoadInput = {},
): Promise<OpenClawInstanceConfigLoadResult> {
  const env = input.env ?? process.env;
  const inline = env.OPENCLAW_INSTANCES_JSON?.trim();
  if (inline) return parseOpenClawInstanceConfigText(inline, "OPENCLAW_INSTANCES_JSON");

  const file = env.OPENCLAW_INSTANCES_FILE?.trim();
  if (file) {
    try {
      return parseOpenClawInstanceConfigText(await readFile(file, "utf8"), file);
    } catch (error) {
      return {
        source: file,
        instances: [],
        issues: [`cannot read ${file}: ${error instanceof Error ? error.message : String(error)}`],
      };
    }
  }

  const openclawHome = env.OPENCLAW_HOME?.trim() || join(homedir(), ".openclaw");
  const workspaceRoot = env.OPENCLAW_WORKSPACE_ROOT?.trim();
  return {
    source: "single-instance-fallback",
    issues: [],
    instances: [{
      id: "default",
      name: "Default",
      gatewayUrl: env.GATEWAY_URL?.trim() || "ws://127.0.0.1:18789",
      openclawHome,
      openclawConfigPath: env.OPENCLAW_CONFIG_PATH?.trim() || join(openclawHome, "openclaw.json"),
      workspaceRoot: workspaceRoot || undefined,
    }],
  };
}

function asObject(input: unknown): Record<string, unknown> | undefined {
  return input !== null && typeof input === "object" && !Array.isArray(input)
    ? input as Record<string, unknown>
    : undefined;
}

function asString(input: unknown): string | undefined {
  return typeof input === "string" ? input : undefined;
}
```

- [ ] **Step 6: 运行测试确认通过**

Run:

```bash
npm test -- test/instance-config.test.ts
npm run build
```

Expected: PASS。

- [ ] **Step 7: 提交**

Run:

```bash
git add src/types.ts src/config.ts src/runtime/instance-config.ts test/instance-config.test.ts
git commit -m "feat: add multi-instance config parser"
```

## Task 2: scoped OpenClaw client 与 agent catalog

**Files:**
- Modify: `src/runtime/current-agent-catalog.ts`
- Modify: `src/clients/openclaw-live-client.ts`
- Modify: `src/clients/factory.ts`
- Modify: `test/agent-roster.test.ts`
- Create: `test/openclaw-live-client-scope.test.ts`

- [ ] **Step 1: 写 current-agent-catalog scoped 测试**

Append to `test/agent-roster.test.ts`:

```ts
test("current agent catalog can load from explicit scoped paths", async () => {
  const { mkdtemp, writeFile } = await import("node:fs/promises");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const { loadCurrentAgentCatalog } = await import("../src/runtime/current-agent-catalog");
  const home = await mkdtemp(join(tmpdir(), "openclaw-catalog-scope-"));
  const configPath = join(home, "openclaw.json");
  await writeFile(configPath, JSON.stringify({
    agents: {
      list: [
        { id: "main", name: "Main Agent" },
        { id: "qa", name: "QA Agent" },
      ],
    },
  }), "utf8");

  const catalog = await loadCurrentAgentCatalog({ openclawHome: home, configPath });

  assert.equal(catalog.status, "connected");
  assert.deepEqual(catalog.entries.map((entry) => entry.agentId), ["main", "qa"]);
  assert.equal(catalog.sourcePath, configPath);
});
```

- [ ] **Step 2: 写 OpenClawLiveClient scoped 源码测试**

Create `test/openclaw-live-client-scope.test.ts`:

```ts
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("OpenClawLiveClient exposes scoped constructor and uses instance home helpers", async () => {
  const source = await readFile("src/clients/openclaw-live-client.ts", "utf8");

  assert(source.includes("interface OpenClawLiveClientScope"));
  assert(source.includes("constructor(private readonly scope: OpenClawLiveClientScope = {})"));
  assert(source.includes("private resolveOpenClawHomePath(): string"));
  assert(source.includes("private buildScopedCommandEnv"));
  assert(source.includes("OPENCLAW_HOME"));
  assert(source.includes("OPENCLAW_CONFIG_PATH"));
});

test("factory exports scoped client creator", async () => {
  const source = await readFile("src/clients/factory.ts", "utf8");

  assert(source.includes("createScopedToolClient"));
  assert(source.includes("new OpenClawLiveClient(scope)"));
});
```

- [ ] **Step 3: 运行测试确认失败**

Run:

```bash
npm test -- test/agent-roster.test.ts test/openclaw-live-client-scope.test.ts
```

Expected: FAIL，`loadCurrentAgentCatalog` 不接受参数，`OpenClawLiveClient` 未实现 scoped constructor。

- [ ] **Step 4: 修改 current-agent-catalog**

Modify `src/runtime/current-agent-catalog.ts`:

```ts
export interface CurrentAgentCatalogInput {
  openclawHome?: string;
  configPath?: string;
}

export async function loadCurrentAgentCatalog(
  input: CurrentAgentCatalogInput = {},
): Promise<CurrentAgentCatalog> {
  const sourcePath = resolveOpenClawConfigPath(input);
  ...
}

export function resolveOpenClawHomePath(input: CurrentAgentCatalogInput = {}): string {
  return input.openclawHome?.trim() || process.env.OPENCLAW_HOME?.trim() || join(homedir(), ".openclaw");
}

export function resolveOpenClawConfigPath(input: CurrentAgentCatalogInput = {}): string {
  const explicit = input.configPath?.trim() || process.env.OPENCLAW_CONFIG_PATH?.trim();
  if (explicit) return explicit;
  return join(resolveOpenClawHomePath(input), "openclaw.json");
}
```

Keep the rest of the parser unchanged.

- [ ] **Step 5: 修改 OpenClawLiveClient scope**

Modify top of `src/clients/openclaw-live-client.ts`:

```ts
interface OpenClawLiveClientScope {
  openclawHome?: string;
  openclawConfigPath?: string;
  workspaceRoot?: string;
  gatewayUrl?: string;
}
```

Modify class header:

```ts
export class OpenClawLiveClient implements ToolClient {
  private sessionCache = new Map<string, SessionCacheItem>();
  private sessionFileCache = new Map<string, string>();

  constructor(private readonly scope: OpenClawLiveClientScope = {}) {}

  private resolveOpenClawHomePath(): string {
    return resolveOpenClawHomePath({
      openclawHome: this.scope.openclawHome,
      configPath: this.scope.openclawConfigPath,
    });
  }

  private buildScopedCommandEnv(base: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
    return {
      ...base,
      ...(this.scope.openclawHome ? { OPENCLAW_HOME: this.scope.openclawHome } : {}),
      ...(this.scope.openclawConfigPath ? { OPENCLAW_CONFIG_PATH: this.scope.openclawConfigPath } : {}),
      ...(this.scope.workspaceRoot ? { OPENCLAW_WORKSPACE_ROOT: this.scope.workspaceRoot } : {}),
      ...(this.scope.gatewayUrl ? { GATEWAY_URL: this.scope.gatewayUrl } : {}),
    };
  }
}
```

Then replace in class methods:

```ts
const openclawHome = resolveOpenClawHomePath();
```

with:

```ts
const openclawHome = this.resolveOpenClawHomePath();
```

Modify CLI calls inside instance methods:

```ts
data = await runJson<{ sessions?: Array<Record<string, unknown>> }>([
  "sessions",
  "--json",
], { env: this.buildScopedCommandEnv() });
```

Apply the same `env: this.buildScopedCommandEnv()` to `cronList`, `approvalsGet`, `approvalsApprove`, `approvalsReject`, `agentRun`, and `agentRunStream`.

Modify `loadConfiguredAgentKeys`:

```ts
private async loadConfiguredAgentKeys(): Promise<Set<string>> {
  const catalog = await loadCurrentAgentCatalog({
    openclawHome: this.scope.openclawHome,
    configPath: this.scope.openclawConfigPath,
  });
  return new Set(catalog.entries.map((entry) => normalizeAgentKey(entry.agentId)));
}
```

- [ ] **Step 6: 修改 factory**

Modify `src/clients/factory.ts`:

```ts
import { OpenClawLiveClient } from "./openclaw-live-client";
import type { OpenClawInstanceConfig } from "../types";
import type { ToolClient } from "./tool-client";

export function createToolClient(): ToolClient {
  return new OpenClawLiveClient();
}

export function createScopedToolClient(instance: OpenClawInstanceConfig): ToolClient {
  return new OpenClawLiveClient({
    openclawHome: instance.openclawHome,
    openclawConfigPath: instance.openclawConfigPath,
    workspaceRoot: instance.workspaceRoot,
    gatewayUrl: instance.gatewayUrl,
  });
}
```

- [ ] **Step 7: 运行测试确认通过**

Run:

```bash
npm test -- test/agent-roster.test.ts test/openclaw-live-client-scope.test.ts
npm run build
```

Expected: PASS。

- [ ] **Step 8: 提交**

Run:

```bash
git add src/runtime/current-agent-catalog.ts src/clients/openclaw-live-client.ts src/clients/factory.ts test/agent-roster.test.ts test/openclaw-live-client-scope.test.ts
git commit -m "feat: scope OpenClaw client by instance"
```

## Task 3: 多实例聚合 adapter

**Files:**
- Create: `src/runtime/multi-instance-summary.ts`
- Create: `src/adapters/multi-instance-readonly.ts`
- Create: `test/multi-instance-summary.test.ts`
- Create: `test/multi-instance-readonly.test.ts`

- [ ] **Step 1: 写 summary 失败测试**

Create `test/multi-instance-summary.test.ts`:

```ts
import assert from "node:assert/strict";
import test from "node:test";
import { summarizeMultiInstanceSnapshot } from "../src/runtime/multi-instance-summary";
import type { InstanceSnapshot, ReadModelSnapshot } from "../src/types";

test("summarizeMultiInstanceSnapshot aggregates instance health and runtime counts", () => {
  const snapshots: InstanceSnapshot[] = [
    makeInstance("main", "connected", makeSnapshot({
      running: 2,
      blocked: 1,
      errors: 0,
      approvals: 1,
      cronJobs: 3,
    })),
    makeInstance("tom", "partial", makeSnapshot({
      running: 1,
      blocked: 0,
      errors: 1,
      approvals: 0,
      cronJobs: 2,
    })),
  ];

  const summary = summarizeMultiInstanceSnapshot(snapshots, "tom");

  assert.equal(summary.selectedInstanceId, "tom");
  assert.equal(summary.totals.instances, 2);
  assert.equal(summary.totals.connected, 1);
  assert.equal(summary.totals.partial, 1);
  assert.equal(summary.totals.sessions, 5);
  assert.equal(summary.totals.running, 3);
  assert.equal(summary.totals.blocked, 1);
  assert.equal(summary.totals.errors, 1);
  assert.equal(summary.totals.pendingApprovals, 1);
  assert.equal(summary.totals.cronJobs, 5);
});

function makeInstance(id: string, status: InstanceSnapshot["status"], snapshot: ReadModelSnapshot): InstanceSnapshot {
  return {
    instance: {
      id,
      name: id,
      openclawHome: `/instances/${id}/config`,
      openclawConfigPath: `/instances/${id}/config/openclaw.json`,
    },
    status,
    detail: status,
    snapshot,
  };
}

function makeSnapshot(input: {
  running: number;
  blocked: number;
  errors: number;
  approvals: number;
  cronJobs: number;
}): ReadModelSnapshot {
  return {
    sessions: [
      ...Array.from({ length: input.running }, (_, idx) => ({ sessionKey: `run-${idx}`, state: "running" as const })),
      ...Array.from({ length: input.blocked }, (_, idx) => ({ sessionKey: `block-${idx}`, state: "blocked" as const })),
      ...Array.from({ length: input.errors }, (_, idx) => ({ sessionKey: `err-${idx}`, state: "error" as const })),
    ],
    statuses: [],
    cronJobs: Array.from({ length: input.cronJobs }, (_, idx) => ({ jobId: `job-${idx}`, enabled: true })),
    approvals: Array.from({ length: input.approvals }, (_, idx) => ({ approvalId: `approval-${idx}`, status: "pending" as const })),
    projects: { projects: [], updatedAt: "2026-05-16T00:00:00.000Z" },
    projectSummaries: [],
    tasks: { tasks: [], updatedAt: "2026-05-16T00:00:00.000Z" },
    tasksSummary: { tasks: 0, todo: 0, inProgress: 0, blocked: 0, done: 0, projects: 0 },
    budgetSummary: { total: 0, ok: 0, warn: 0, over: 0, evaluations: [] },
    generatedAt: "2026-05-16T00:00:00.000Z",
  };
}
```

- [ ] **Step 2: 写 adapter 失败测试**

Create `test/multi-instance-readonly.test.ts`:

```ts
import assert from "node:assert/strict";
import test from "node:test";
import { MultiInstanceReadonlyAdapter } from "../src/adapters/multi-instance-readonly";
import type { OpenClawInstanceConfig } from "../src/types";

test("MultiInstanceReadonlyAdapter keeps healthy instances when one instance fails", async () => {
  const instances: OpenClawInstanceConfig[] = [
    { id: "main", name: "Main", openclawHome: "/instances/main/config", openclawConfigPath: "/instances/main/config/openclaw.json" },
    { id: "broken", name: "Broken", openclawHome: "/instances/broken/config", openclawConfigPath: "/instances/broken/config/openclaw.json" },
  ];
  const adapter = new MultiInstanceReadonlyAdapter(instances, {
    createSnapshot: async (instance) => {
      if (instance.id === "broken") throw new Error("permission denied");
      return {
        sessions: [{ sessionKey: "main-session", state: "running" }],
        statuses: [],
        cronJobs: [],
        approvals: [],
        projects: { projects: [], updatedAt: "2026-05-16T00:00:00.000Z" },
        projectSummaries: [],
        tasks: { tasks: [], updatedAt: "2026-05-16T00:00:00.000Z" },
        tasksSummary: { tasks: 0, todo: 0, inProgress: 0, blocked: 0, done: 0, projects: 0 },
        budgetSummary: { total: 0, ok: 0, warn: 0, over: 0, evaluations: [] },
        generatedAt: "2026-05-16T00:00:00.000Z",
      };
    },
  });

  const snapshot = await adapter.snapshot("main");

  assert.equal(snapshot.instances.length, 2);
  assert.equal(snapshot.instances[0].status, "connected");
  assert.equal(snapshot.instances[1].status, "not_connected");
  assert.match(snapshot.instances[1].detail, /permission denied/);
  assert.equal(snapshot.totals.running, 1);
});
```

- [ ] **Step 3: 运行测试确认失败**

Run:

```bash
npm test -- test/multi-instance-summary.test.ts test/multi-instance-readonly.test.ts
```

Expected: FAIL，模块不存在。

- [ ] **Step 4: 实现 summary**

Create `src/runtime/multi-instance-summary.ts`:

```ts
import type { InstanceSnapshot, MultiInstanceSnapshot } from "../types";

export function summarizeMultiInstanceSnapshot(
  instances: InstanceSnapshot[],
  selectedInstanceId?: string,
): MultiInstanceSnapshot {
  const totals = {
    instances: instances.length,
    connected: instances.filter((item) => item.status === "connected").length,
    partial: instances.filter((item) => item.status === "partial").length,
    notConnected: instances.filter((item) => item.status === "not_connected").length,
    sessions: 0,
    running: 0,
    blocked: 0,
    errors: 0,
    pendingApprovals: 0,
    cronJobs: 0,
  };

  for (const item of instances) {
    totals.sessions += item.snapshot.sessions.length;
    totals.running += item.snapshot.sessions.filter((session) => session.state === "running").length;
    totals.blocked += item.snapshot.sessions.filter((session) => session.state === "blocked" || session.state === "waiting_approval").length;
    totals.errors += item.snapshot.sessions.filter((session) => session.state === "error").length;
    totals.pendingApprovals += item.snapshot.approvals.filter((approval) => approval.status === "pending").length;
    totals.cronJobs += item.snapshot.cronJobs.length;
  }

  return {
    generatedAt: new Date().toISOString(),
    selectedInstanceId: selectedInstanceId ?? instances[0]?.instance.id ?? "default",
    instances,
    totals,
  };
}
```

- [ ] **Step 5: 实现 adapter**

Create `src/adapters/multi-instance-readonly.ts`:

```ts
import { OpenClawReadonlyAdapter } from "./openclaw-readonly";
import { createScopedToolClient } from "../clients/factory";
import { summarizeMultiInstanceSnapshot } from "../runtime/multi-instance-summary";
import type {
  MultiInstanceSnapshot,
  OpenClawInstanceConfig,
  ReadModelSnapshot,
} from "../types";

interface MultiInstanceReadonlyAdapterOptions {
  createSnapshot?: (instance: OpenClawInstanceConfig) => Promise<ReadModelSnapshot>;
}

export class MultiInstanceReadonlyAdapter {
  constructor(
    private readonly instances: OpenClawInstanceConfig[],
    private readonly options: MultiInstanceReadonlyAdapterOptions = {},
  ) {}

  async snapshot(selectedInstanceId?: string): Promise<MultiInstanceSnapshot> {
    const rows = await Promise.all(
      this.instances.map(async (instance) => {
        try {
          const snapshot = await this.createSnapshot(instance);
          return {
            instance,
            status: "connected" as const,
            detail: "snapshot loaded",
            snapshot,
          };
        } catch (error) {
          return {
            instance,
            status: "not_connected" as const,
            detail: error instanceof Error ? error.message : String(error),
            snapshot: emptySnapshot(),
          };
        }
      }),
    );

    return summarizeMultiInstanceSnapshot(rows, selectedInstanceId);
  }

  private async createSnapshot(instance: OpenClawInstanceConfig): Promise<ReadModelSnapshot> {
    if (this.options.createSnapshot) return this.options.createSnapshot(instance);
    return new OpenClawReadonlyAdapter(createScopedToolClient(instance)).snapshot();
  }
}

function emptySnapshot(): ReadModelSnapshot {
  const now = new Date().toISOString();
  return {
    sessions: [],
    statuses: [],
    cronJobs: [],
    approvals: [],
    projects: { projects: [], updatedAt: now },
    projectSummaries: [],
    tasks: { tasks: [], updatedAt: now },
    tasksSummary: { tasks: 0, todo: 0, inProgress: 0, blocked: 0, done: 0, projects: 0 },
    budgetSummary: { total: 0, ok: 0, warn: 0, over: 0, evaluations: [] },
    generatedAt: now,
  };
}
```

- [ ] **Step 6: 运行测试确认通过**

Run:

```bash
npm test -- test/multi-instance-summary.test.ts test/multi-instance-readonly.test.ts
npm run build
```

Expected: PASS。

- [ ] **Step 7: 提交**

Run:

```bash
git add src/runtime/multi-instance-summary.ts src/adapters/multi-instance-readonly.ts test/multi-instance-summary.test.ts test/multi-instance-readonly.test.ts
git commit -m "feat: aggregate readonly multi-instance snapshots"
```

## Task 4: UI 多实例总览与实例详情切换

**Files:**
- Modify: `src/ui/server.ts`
- Modify: `test/ui-render-smoke.test.ts`

- [ ] **Step 1: 写 UI smoke 失败测试**

Append to `test/ui-render-smoke.test.ts`:

```ts
test("multi-instance overview renders instance cards and detail links", async () => {
  const { renderMultiInstanceOverviewForSmoke } = await import("../src/ui/server");

  const html = renderMultiInstanceOverviewForSmoke({
    generatedAt: "2026-05-16T00:00:00.000Z",
    selectedInstanceId: "tom",
    totals: {
      instances: 2,
      connected: 1,
      partial: 1,
      notConnected: 0,
      sessions: 3,
      running: 1,
      blocked: 1,
      errors: 0,
      pendingApprovals: 1,
      cronJobs: 4,
    },
    instances: [
      {
        instance: { id: "main", name: "Main", openclawHome: "/instances/main/config", openclawConfigPath: "/instances/main/config/openclaw.json" },
        status: "connected",
        detail: "snapshot loaded",
        snapshot: makeSmokeSnapshot("main-session"),
      },
      {
        instance: { id: "tom", name: "Tom / Work", openclawHome: "/instances/tom/config", openclawConfigPath: "/instances/tom/config/openclaw.json" },
        status: "partial",
        detail: "config readable, runtime partial",
        snapshot: makeSmokeSnapshot("tom-session"),
      },
    ],
  }, "zh");

  assert(html.includes("多实例总览"));
  assert(html.includes("Tom / Work"));
  assert(html.includes("?instance=tom&amp;section=overview"));
  assert(html.includes("运行中"));
  assert(html.includes("待审批"));
});
```

Add helper near existing smoke helpers:

```ts
function makeSmokeSnapshot(sessionKey: string): ReadModelSnapshot {
  return {
    sessions: [{ sessionKey, state: "running" }],
    statuses: [],
    cronJobs: [{ jobId: `${sessionKey}-cron`, enabled: true }],
    approvals: [],
    projects: { projects: [], updatedAt: "2026-05-16T00:00:00.000Z" },
    projectSummaries: [],
    tasks: { tasks: [], updatedAt: "2026-05-16T00:00:00.000Z" },
    tasksSummary: { tasks: 0, todo: 0, inProgress: 0, blocked: 0, done: 0, projects: 0 },
    budgetSummary: { total: 0, ok: 0, warn: 0, over: 0, evaluations: [] },
    generatedAt: "2026-05-16T00:00:00.000Z",
  };
}
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```bash
npm test -- test/ui-render-smoke.test.ts
```

Expected: FAIL，`renderMultiInstanceOverviewForSmoke` 未导出。

- [ ] **Step 3: 在 server.ts 增加渲染函数**

Modify `src/ui/server.ts` imports to include `MultiInstanceSnapshot`.

Add near smoke exports:

```ts
export function renderMultiInstanceOverviewForSmoke(
  multi: MultiInstanceSnapshot,
  language: UiLanguage = "en",
): string {
  return renderMultiInstanceOverview(multi, language);
}
```

Add renderer near dashboard render helpers:

```ts
function renderMultiInstanceOverview(
  multi: MultiInstanceSnapshot,
  language: UiLanguage,
): string {
  const t = createTranslator(language);
  const cards = multi.instances.map((item) => {
    const running = item.snapshot.sessions.filter((session) => session.state === "running").length;
    const blocked = item.snapshot.sessions.filter((session) => session.state === "blocked" || session.state === "waiting_approval").length;
    const errors = item.snapshot.sessions.filter((session) => session.state === "error").length;
    const pending = item.snapshot.approvals.filter((approval) => approval.status === "pending").length;
    const href = `/?instance=${encodeURIComponent(item.instance.id)}&section=overview`;
    return `
      <article class="card instance-card">
        <div class="card-kicker">${escapeHtml(item.status)}</div>
        <h3>${escapeHtml(item.instance.name)}</h3>
        <p>${escapeHtml(item.detail)}</p>
        <div class="metric-grid">
          <span>${t("Running", "运行中")}: ${running}</span>
          <span>${t("Blocked", "阻塞")}: ${blocked}</span>
          <span>${t("Errors", "错误")}: ${errors}</span>
          <span>${t("Pending approvals", "待审批")}: ${pending}</span>
          <span>Cron: ${item.snapshot.cronJobs.length}</span>
        </div>
        <a class="button-link" href="${escapeHtml(href)}">${t("Open details", "进入详情")}</a>
      </article>
    `;
  }).join("");

  return `
    <section class="dashboard-section" id="multi-instance-overview">
      <div class="section-heading">
        <p class="eyebrow">${t("Control Center", "控制中心")}</p>
        <h2>${t("Multi-instance overview", "多实例总览")}</h2>
        <p>${t("Readonly view across configured OpenClaw instances.", "跨已配置 OpenClaw 实例的只读视图。")}</p>
      </div>
      <div class="metric-grid">
        <span>${t("Instances", "实例")}: ${multi.totals.instances}</span>
        <span>${t("Connected", "已连接")}: ${multi.totals.connected}</span>
        <span>${t("Running", "运行中")}: ${multi.totals.running}</span>
        <span>${t("Pending approvals", "待审批")}: ${multi.totals.pendingApprovals}</span>
      </div>
      <div class="card-grid">${cards}</div>
    </section>
  `;
}
```

- [ ] **Step 4: 接入 URL instance 选择**

Modify `startUiServer` request handling:

```ts
const multiInstances = await loadOpenClawInstanceConfigs();
const isMultiInstanceMode = multiInstances.instances.length > 1 || multiInstances.source !== "single-instance-fallback";
```

For main dashboard route:

```ts
const instanceId = url.searchParams.get("instance")?.trim();
if (isMultiInstanceMode && !instanceId) {
  const multi = await new MultiInstanceReadonlyAdapter(multiInstances.instances).snapshot();
  html = renderDashboardShell(renderMultiInstanceOverview(multi, language), { language, activeSection: "overview" });
  sendHtml(response, html);
  return;
}
```

For selected details:

```ts
const selectedInstance = multiInstances.instances.find((item) => item.id === instanceId) ?? multiInstances.instances[0];
```

Use `selectedInstance` to create scoped tool client and detail snapshot. Keep existing single-instance flow when `isMultiInstanceMode` is false.

- [ ] **Step 5: 加实例切换器**

Add helper:

```ts
function renderInstanceSwitcher(
  instances: OpenClawInstanceConfig[],
  selectedInstanceId: string,
  section: DashboardSection,
  language: UiLanguage,
): string {
  if (instances.length <= 1) return "";
  const t = createTranslator(language);
  const options = instances.map((instance) => {
    const href = `/?instance=${encodeURIComponent(instance.id)}&section=${encodeURIComponent(section)}`;
    const current = instance.id === selectedInstanceId ? ' aria-current="true"' : "";
    return `<a class="instance-switcher-link" href="${escapeHtml(href)}"${current}>${escapeHtml(instance.name)}</a>`;
  }).join("");
  return `<nav class="instance-switcher" aria-label="${t("Instances", "实例")}">${options}</nav>`;
}
```

Insert it near dashboard section navigation.

- [ ] **Step 6: 运行 UI 测试和构建**

Run:

```bash
npm test -- test/ui-render-smoke.test.ts
npm run build
```

Expected: PASS。

- [ ] **Step 7: 提交**

Run:

```bash
git add src/ui/server.ts test/ui-render-smoke.test.ts
git commit -m "feat: render readonly multi-instance dashboard"
```

## Task 5: 只读安全边界

**Files:**
- Modify: `src/ui/server.ts`
- Modify: `src/config.ts`
- Modify: `test/oss-readiness.test.ts`
- Create: `test/readonly-multi-instance-safety.test.ts`

- [ ] **Step 1: 写安全测试**

Create `test/readonly-multi-instance-safety.test.ts`:

```ts
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("multi-instance implementation keeps mutation gates disabled by default", async () => {
  const config = await readFile("src/config.ts", "utf8");
  const server = await readFile("src/ui/server.ts", "utf8");

  assert(config.includes('READONLY_MODE = process.env.READONLY_MODE !== "false"'));
  assert(config.includes('APPROVAL_ACTIONS_ENABLED = process.env.APPROVAL_ACTIONS_ENABLED === "true"'));
  assert(config.includes('TASK_HEARTBEAT_ENABLED = process.env.TASK_HEARTBEAT_ENABLED !== "false"'));
  assert(server.includes("readonly"));
  assert(server.includes("READONLY_MODE"));
});
```

- [ ] **Step 2: 运行测试确认当前安全文字不足**

Run:

```bash
npm test -- test/readonly-multi-instance-safety.test.ts
```

Expected: 可能 PASS，也可能 FAIL。若 PASS，继续 Step 3 加明确只读 guard，避免测试只验证现状。

- [ ] **Step 3: 增加多实例只读 guard**

In `src/ui/server.ts`, add helper:

```ts
function isReadonlyMultiInstanceMode(instanceCount: number): boolean {
  return READONLY_MODE || instanceCount > 1;
}

function readonlyMutationError(language: UiLanguage): string {
  return createTranslator(language)(
    "This control center is running in readonly multi-instance mode. Mutation endpoints are disabled.",
    "控制中心正以只读多实例模式运行，修改类接口已禁用。",
  );
}
```

Use this helper in mutation routes before existing handlers for:

- approvals action routes
- task update routes
- import live mutation
- editable documents save routes
- memory save routes

Return `403` JSON:

```ts
sendJson(response, 403, { ok: false, error: readonlyMutationError(language) });
return;
```

- [ ] **Step 4: 扩充安全测试**

Update `test/readonly-multi-instance-safety.test.ts`:

```ts
assert(server.includes("isReadonlyMultiInstanceMode"));
assert(server.includes("readonlyMutationError"));
assert(server.includes("修改类接口已禁用"));
```

- [ ] **Step 5: 运行测试**

Run:

```bash
npm test -- test/readonly-multi-instance-safety.test.ts test/oss-readiness.test.ts
npm run build
```

Expected: PASS。

- [ ] **Step 6: 提交**

Run:

```bash
git add src/ui/server.ts src/config.ts test/readonly-multi-instance-safety.test.ts test/oss-readiness.test.ts
git commit -m "feat: enforce readonly multi-instance safety gates"
```

## Task 6: 部署文档与示例配置

**Files:**
- Modify: `.env.example`
- Modify: `docker-compose.example.yml`
- Create: `docs/MULTI_INSTANCE_READONLY.md`
- Modify: `README.zh-CN.md`
- Modify: `README.md`

- [ ] **Step 1: 写文档存在性测试**

Append to `test/oss-readiness.test.ts`:

```ts
test("multi-instance readonly docs describe safe Oracle deployment", async () => {
  const { readFile } = await import("node:fs/promises");
  const doc = await readFile("docs/MULTI_INSTANCE_READONLY.md", "utf8");
  const compose = await readFile("docker-compose.example.yml", "utf8");
  const env = await readFile(".env.example", "utf8");

  assert(doc.includes("OPENCLAW_INSTANCES_FILE"));
  assert(doc.includes("/srv/openclaw-work"));
  assert(doc.includes(":ro"));
  assert(doc.includes("不挂载 /var/run/docker.sock"));
  assert(compose.includes("OPENCLAW_INSTANCES_FILE"));
  assert(env.includes("OPENCLAW_INSTANCES_JSON"));
});
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```bash
npm test -- test/oss-readiness.test.ts
```

Expected: FAIL，文档不存在或示例缺失。

- [ ] **Step 3: 创建部署文档**

Create `docs/MULTI_INSTANCE_READONLY.md`:

```md
# 多实例只读部署

本模式用于一个 OpenClaw Control Center 查看多套 OpenClaw 实例。第一版严格只读，只观察，不执行修改。

## 安全原则

- 所有 OpenClaw 实例目录只读挂载。
- 不挂载 /var/run/docker.sock。
- 不使用 privileged: true。
- 不开启 approve/reject、agent run、import mutation、task heartbeat 或 hall runtime dispatch。
- UI 先放在内网、SSH tunnel 或带鉴权的反向代理后面。

## Tom 示例

Tom 上建议把实例挂载到 /instances：

```yaml
volumes:
  - /srv/openclaw/config:/instances/main/config:ro
  - /srv/openclaw/workspace:/instances/main/workspace:ro
  - /srv/openclaw-work/config:/instances/tom/config:ro
  - /srv/openclaw-work/workspace:/instances/tom/workspace:ro
  - /srv/openclaw-third/config:/instances/third/config:ro
  - /srv/openclaw-third/workspace:/instances/third/workspace:ro
  - /srv/openclaw-spark/config:/instances/spark/config:ro
  - /srv/openclaw-spark/workspace:/instances/spark/workspace:ro
  - /srv/openclaw-deepseek/config:/instances/deepseek/config:ro
  - /srv/openclaw-deepseek/workspace:/instances/deepseek/workspace:ro
```

## instances.json

```json
{
  "instances": [
    { "id": "main", "name": "Main", "openclawHome": "/instances/main/config", "workspaceRoot": "/instances/main/workspace" },
    { "id": "tom", "name": "Tom / Work", "openclawHome": "/instances/tom/config", "workspaceRoot": "/instances/tom/workspace" },
    { "id": "third", "name": "Third", "openclawHome": "/instances/third/config", "workspaceRoot": "/instances/third/workspace" },
    { "id": "spark", "name": "Spark", "openclawHome": "/instances/spark/config", "workspaceRoot": "/instances/spark/workspace" },
    { "id": "deepseek", "name": "DeepSeek", "openclawHome": "/instances/deepseek/config", "workspaceRoot": "/instances/deepseek/workspace" }
  ]
}
```

## 推荐环境变量

```env
OPENCLAW_INSTANCES_FILE=/app/config/instances.json
READONLY_MODE=true
APPROVAL_ACTIONS_ENABLED=false
APPROVAL_ACTIONS_DRY_RUN=true
IMPORT_MUTATION_ENABLED=false
IMPORT_MUTATION_DRY_RUN=true
TASK_HEARTBEAT_ENABLED=false
HALL_RUNTIME_DISPATCH_ENABLED=false
HALL_RUNTIME_DIRECT_STREAM_ENABLED=false
LOCAL_TOKEN_AUTH_REQUIRED=true
```
```

- [ ] **Step 4: 更新示例 env 和 compose**

Append to `.env.example`:

```env
# Multi-instance readonly mode
# OPENCLAW_INSTANCES_FILE=/app/config/instances.json
# OPENCLAW_INSTANCES_JSON={"instances":[{"id":"tom","name":"Tom / Work","openclawHome":"/instances/tom/config","workspaceRoot":"/instances/tom/workspace"}]}
```

Update `docker-compose.example.yml` with a commented service block or comments that include `OPENCLAW_INSTANCES_FILE` and read-only `/instances/*` mounts.

- [ ] **Step 5: 更新 README 入口**

Add a short section to `README.zh-CN.md`:

```md
## 多实例只读模式

如果你有多套 OpenClaw 实例，可以使用 `OPENCLAW_INSTANCES_FILE` 启用只读多实例总览。部署前请先阅读 [多实例只读部署](docs/MULTI_INSTANCE_READONLY.md)。
```

Add equivalent English note to `README.md`.

- [ ] **Step 6: 运行测试**

Run:

```bash
npm test -- test/oss-readiness.test.ts
npm run build
```

Expected: PASS。

- [ ] **Step 7: 提交**

Run:

```bash
git add .env.example docker-compose.example.yml docs/MULTI_INSTANCE_READONLY.md README.zh-CN.md README.md test/oss-readiness.test.ts
git commit -m "docs: document readonly multi-instance deployment"
```

## Task 7: 全量验证与分支推送

**Files:**
- No production file changes unless previous verification exposes failures.

- [ ] **Step 1: 运行全量测试**

Run:

```bash
npm test
npm run build
```

Expected: PASS。

- [ ] **Step 2: 运行 UI smoke**

Run:

```bash
npm run smoke:ui
```

Expected: PASS，或输出可解释的本地浏览器依赖问题。如果是依赖问题，运行：

```bash
node scripts/ensure-playwright.js
npm run smoke:ui
```

- [ ] **Step 3: 查看提交历史**

Run:

```bash
git log --oneline --decorate -8
git status --short
```

Expected: 分支包含本计划中的多个小提交，工作区干净。

- [ ] **Step 4: 推送到 fork**

Run:

```bash
git push -u origin multi-instance-readonly-control-center
```

Expected: push 成功，分支更新到 `huangnan29/openclaw-control-center`。

- [ ] **Step 5: 准备后续 Tom 只读 POC**

Create a local deployment note in final response with:

```bash
docker build -t openclaw-control-center:multi-instance-readonly .
```

Do not deploy to Tom until Anan explicitly approves.

## 自检

- Spec 覆盖：计划覆盖多实例配置、聚合、UI 总览、实例详情切换、只读安全和部署文档。
- 占位符扫描：计划不包含 TBD/TODO/待定。
- 类型一致性：所有新增类型以 `src/types.ts` 为来源，后续模块只引用这些类型。
- 安全边界：第一版没有启用写操作，也不要求 Docker socket 或 privileged。
