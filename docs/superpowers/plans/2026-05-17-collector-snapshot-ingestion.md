# Collector Snapshot Ingestion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让中央 control-center 能从只读 collector 快照文件读取远端服务器实例状态，为后续每台 Oracle 本地 collector 上报做第一步数据通道。

**Architecture:** 继续保留现有本地只读扫描路径；当 registry 中某个 server 声明 `collectorSnapshotPath` 时，该 server 下的实例优先从该 JSON 快照文件加载 `ReadModelSnapshot`。快照文件只传监控数据，中央不需要挂载远端实例目录，也不提供任何写操作。

**Tech Stack:** TypeScript、Node.js test runner、服务端只读 adapter、JSON collector snapshot file。

---

### Task 1: Registry 支持 collector 快照路径

**Files:**
- Modify: `src/types.ts`
- Modify: `src/runtime/instance-config.ts`
- Test: `test/instance-config.test.ts`

- [x] **Step 1: Write the failing test**

在 `test/instance-config.test.ts` 追加：

```ts
test("parseOpenClawInstanceConfigText attaches server collector snapshot path", () => {
  const result = parseOpenClawInstanceConfigText(
    JSON.stringify({
      servers: [
        {
          id: "remote-oracle",
          name: "Remote Oracle",
          collectorSnapshotPath: "/collectors/remote-oracle/snapshot.json",
          instances: [
            {
              id: "remote-main",
              name: "Remote Main",
              openclawHome: "/remote/main/config",
              workspaceRoot: "/remote/main/workspace",
            },
          ],
        },
      ],
    }),
    "inline",
  );

  assert.equal(result.issues.length, 0);
  assert.equal(result.servers?.[0]?.collectorSnapshotPath, "/collectors/remote-oracle/snapshot.json");
  assert.equal(result.instances[0]?.collectorSnapshotPath, "/collectors/remote-oracle/snapshot.json");
});
```

- [x] **Step 2: Run test to verify it fails**

Run: `npm test -- test/instance-config.test.ts`

Expected: FAIL because `collectorSnapshotPath` is not parsed yet.

- [x] **Step 3: Write minimal implementation**

在 `src/types.ts` 的 `OpenClawServerConfig` 与 `OpenClawInstanceConfig` 增加可选字段：

```ts
collectorSnapshotPath?: string;
```

在 `src/runtime/instance-config.ts` 的 server 解析中读取并校验 `collectorSnapshotPath`，再复制到该 server 的实例上。

- [x] **Step 4: Run test to verify it passes**

Run: `npm test -- test/instance-config.test.ts`

Expected: PASS.

### Task 2: Collector 快照文件解析

**Files:**
- Create: `src/runtime/collector-snapshot.ts`
- Test: `test/collector-snapshot.test.ts`

- [x] **Step 1: Write the failing test**

创建 `test/collector-snapshot.test.ts`，覆盖：

```ts
test("loadCollectorSnapshotFile reads readonly collector snapshots", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-collector-"));
  const file = join(dir, "snapshot.json");
  await writeFile(file, JSON.stringify({
    schemaVersion: 1,
    serverId: "remote-oracle",
    generatedAt: "2026-05-17T04:00:00.000Z",
    instances: [
      {
        id: "remote-main",
        status: "connected",
        detail: "collector ok",
        snapshot: readModelSnapshot({
          sessions: [{ sessionKey: "remote-session", state: "running", lastMessageAt: "2026-05-17T04:00:00.000Z" }],
        }),
      },
    ],
  }), "utf8");

  const snapshot = await loadCollectorSnapshotFile(file);

  assert.equal(snapshot.status, "connected");
  assert.equal(snapshot.serverId, "remote-oracle");
  assert.equal(snapshot.instances[0]?.id, "remote-main");
  assert.equal(snapshot.instances[0]?.snapshot.sessions[0]?.sessionKey, "remote-session");
});
```

- [x] **Step 2: Run test to verify it fails**

Run: `npm test -- test/collector-snapshot.test.ts`

Expected: FAIL because `src/runtime/collector-snapshot.ts` does not exist yet.

- [x] **Step 3: Write minimal implementation**

实现 `loadCollectorSnapshotFile(path)`：

```ts
export async function loadCollectorSnapshotFile(path: string): Promise<CollectorSnapshotLoadResult>
```

读取 JSON，校验 `instances` 数组、实例 id、status/detail/snapshot 基本字段；读不到或 JSON 无效时返回 `status: "not_connected"` 与 `detail`，不抛出到 UI 层。

- [x] **Step 4: Run test to verify it passes**

Run: `npm test -- test/collector-snapshot.test.ts`

Expected: PASS.

### Task 3: 多实例 adapter 使用 collector 快照

**Files:**
- Modify: `src/adapters/multi-instance-readonly.ts`
- Test: `test/multi-instance-readonly.test.ts`

- [x] **Step 1: Write the failing test**

在 `test/multi-instance-readonly.test.ts` 追加：

```ts
test("MultiInstanceReadonlyAdapter 优先使用 collector 快照文件", async () => {
  const root = await mkdtemp(join(tmpdir(), "openclaw-collector-adapter-"));
  const snapshotPath = join(root, "snapshot.json");
  await writeFile(snapshotPath, JSON.stringify({
    schemaVersion: 1,
    serverId: "remote-oracle",
    generatedAt: "2026-05-17T04:05:00.000Z",
    instances: [
      {
        id: "remote-main",
        status: "connected",
        detail: "collector supplied",
        snapshot: readModelSnapshot({
          sessions: [{ sessionKey: "collector-session", state: "running", lastMessageAt: "2026-05-17T04:05:00.000Z" }],
        }),
      },
    ],
  }), "utf8");

  const adapter = new MultiInstanceReadonlyAdapter(
    [{ ...instance("remote-main"), serverId: "remote-oracle", serverName: "Remote Oracle", collectorSnapshotPath: snapshotPath }],
    {
      async createSnapshot() {
        throw new Error("local scan should not run");
      },
    },
  );

  const snapshot = await adapter.snapshot("remote-main");

  assert.equal(snapshot.instances[0]?.status, "connected");
  assert.equal(snapshot.instances[0]?.detail, "collector supplied");
  assert.equal(snapshot.instances[0]?.snapshot.sessions[0]?.sessionKey, "collector-session");
  assert.equal(snapshot.totals.running, 1);
});
```

- [x] **Step 2: Run test to verify it fails**

Run: `npm test -- test/multi-instance-readonly.test.ts`

Expected: FAIL because adapter still calls local scan.

- [x] **Step 3: Write minimal implementation**

在 `MultiInstanceReadonlyAdapter.snapshot()` 中按 `collectorSnapshotPath` 缓存加载 collector 文件。存在 collector 快照的实例使用 collector entry；找不到 entry 时返回 `not_connected` 空快照；没有 `collectorSnapshotPath` 的实例继续使用本地只读扫描。

- [x] **Step 4: Run test to verify it passes**

Run: `npm test -- test/multi-instance-readonly.test.ts`

Expected: PASS.

### Task 4: 文档、任务锚点和 Tom 灰度验证

**Files:**
- Modify: `docs/MULTI_INSTANCE_READONLY.md`
- Modify: `.env.example`
- Modify: `task.md`
- Modify: `implementation_plan.md`
- Test: `test/oss-readiness.test.ts`

- [x] **Step 1: Write the failing doc assertion**

在 `test/oss-readiness.test.ts` 增加：

```ts
assert(doc.includes("collectorSnapshotPath"));
assert(env.includes("collectorSnapshotPath"));
```

- [x] **Step 2: Run doc test to verify it fails**

Run: `npm test -- test/oss-readiness.test.ts`

Expected: FAIL because docs do not mention collector snapshot path yet.

- [x] **Step 3: Update docs and task anchors**

文档说明 `collectorSnapshotPath` 是中央读取快照文件的第一步，只读、无写动作、无远端目录挂载。`task.md` 下一步更新为“实现服务器本地 collector exporter”，不是继续扩 UI。

- [x] **Step 4: Run final verification**

Run:

```bash
npm test -- test/instance-config.test.ts
npm test -- test/collector-snapshot.test.ts
npm test -- test/multi-instance-readonly.test.ts
npm test -- test/ui-render-smoke.test.ts
npm test -- test/oss-readiness.test.ts
npm test -- test/readonly-multi-instance-safety.test.ts
npm run build
```

Expected: all PASS.

- [x] **Step 5: Commit**

```bash
git add -f docs/superpowers/plans/2026-05-17-collector-snapshot-ingestion.md
git add .env.example docs/MULTI_INSTANCE_READONLY.md implementation_plan.md task.md src/types.ts src/runtime/instance-config.ts src/runtime/collector-snapshot.ts src/adapters/multi-instance-readonly.ts test/instance-config.test.ts test/collector-snapshot.test.ts test/multi-instance-readonly.test.ts test/oss-readiness.test.ts
git commit -m "feat: ingest readonly collector snapshots"
```

### Self-Review

- Spec coverage: 覆盖 collector 快照路径配置、collector JSON 解析、中央 adapter 汇总、文档和只读边界。
- Placeholder scan: 无 TBD/TODO/implement later。
- Type consistency: 统一使用 `collectorSnapshotPath`，collector 文件中的实例主键统一为 `id`。
