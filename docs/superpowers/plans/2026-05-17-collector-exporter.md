# Collector Exporter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在每台 Oracle 服务器本地提供一个只读 collector exporter，生成中央 control-center 已能读取的 collector JSON 快照。

**Architecture:** exporter 复用现有 `OpenClawReadonlyAdapter` 和实例 registry，只读取本机 OpenClaw 实例并写出一个 JSON 快照文件。输出文件落在控制中心 runtime/collector 目录；不写实例目录、不提供 HTTP 服务、不执行管理动作。

**Tech Stack:** TypeScript、Node.js test runner、`APP_COMMAND=collector-snapshot` CLI、Tom 运维 shell 脚本。

---

### Task 1: Exporter runtime

**Files:**
- Create: `src/runtime/collector-exporter.ts`
- Test: `test/collector-exporter.test.ts`

- [x] **Step 1: Write the failing tests**

创建 `test/collector-exporter.test.ts`，覆盖：

```ts
test("buildCollectorSnapshot exports connected and failed instances", async () => {
  const snapshot = await buildCollectorSnapshot({
    instances: [instance("main"), instance("broken")],
    serverId: "tom-oracle",
    generatedAt: "2026-05-17T05:00:00.000Z",
    async createSnapshot(current) {
      if (current.id === "broken") throw new Error("gateway down");
      return readModelSnapshot({
        sessions: [{ sessionKey: "main-session", state: "running", lastMessageAt: "2026-05-17T05:00:00.000Z" }],
      });
    },
  });

  assert.equal(snapshot.schemaVersion, 1);
  assert.equal(snapshot.serverId, "tom-oracle");
  assert.equal(snapshot.instances[0]?.status, "connected");
  assert.equal(snapshot.instances[1]?.status, "not_connected");
  assert.equal(snapshot.instances[1]?.detail, "gateway down");
});
```

并覆盖 `writeCollectorSnapshotFile` 写文件后能被 `loadCollectorSnapshotFile` 读回。

- [x] **Step 2: Run test to verify it fails**

Run: `npm test -- test/collector-exporter.test.ts`

Expected: FAIL because `src/runtime/collector-exporter.ts` does not exist yet.

- [x] **Step 3: Write minimal implementation**

实现：

```ts
export async function buildCollectorSnapshot(input: CollectorExportInput): Promise<CollectorSnapshotFile>
export async function writeCollectorSnapshotFile(snapshot: CollectorSnapshotFile, outputPath: string): Promise<{ path: string; instances: number }>
export function selectCollectorExportScope(result: OpenClawInstanceConfigLoadResult, serverId?: string): CollectorExportScope
```

失败实例写入 `status: "not_connected"` 与 `emptySnapshot()`，成功实例写入真实 `ReadModelSnapshot`。

- [x] **Step 4: Run test to verify it passes**

Run: `npm test -- test/collector-exporter.test.ts`

Expected: PASS.

### Task 2: CLI command

**Files:**
- Modify: `src/index.ts`
- Modify: `package.json`
- Test: `test/collector-exporter.test.ts`

- [x] **Step 1: Write the failing command contract test**

在 `test/collector-exporter.test.ts` 追加 `selectCollectorExportScope` 测试：server id 可筛选指定服务器；未传 server id 且只有一个服务器时自动选中。

- [x] **Step 2: Run test to verify it fails**

Run: `npm test -- test/collector-exporter.test.ts`

Expected: FAIL because selector does not exist.

- [x] **Step 3: Implement command**

在 `src/index.ts` 新增命令 `collector-snapshot`：

```bash
node dist/index.js collector-snapshot /app/runtime/collectors/tom-oracle/snapshot.json
```

支持：

- `COMMAND_ARG` 或第一个命令参数作为输出文件。
- `OPENCLAW_COLLECTOR_OUTPUT` 作为输出文件 fallback。
- `OPENCLAW_COLLECTOR_SERVER_ID` 筛选服务器。

在 `package.json` 增加：

```json
"collector:snapshot": "cross-env APP_COMMAND=collector-snapshot node --import tsx src/index.ts"
```

- [x] **Step 4: Run focused verification**

Run:

```bash
npm test -- test/collector-exporter.test.ts
npm run build
```

Expected: PASS.

### Task 3: Tom operator script and docs

**Files:**
- Create: `ops/tom-readonly/collector-snapshot.sh`
- Modify: `ops/tom-readonly/README.md`
- Modify: `docs/MULTI_INSTANCE_READONLY.md`
- Modify: `.env.example`
- Modify: `task.md`
- Test: `test/oss-readiness.test.ts`

- [x] **Step 1: Write the failing doc/script assertion**

在 `test/oss-readiness.test.ts` 增加：

```ts
assert(doc.includes("collector:snapshot"));
assert(existsSync(path.join(ROOT, "ops", "tom-readonly", "collector-snapshot.sh")));
```

- [x] **Step 2: Run test to verify it fails**

Run: `npm test -- test/oss-readiness.test.ts`

Expected: FAIL because script/docs do not exist yet.

- [x] **Step 3: Implement script and docs**

`ops/tom-readonly/collector-snapshot.sh` 执行：

```bash
docker exec "$CONTAINER_NAME" node dist/index.js collector-snapshot "$OUTPUT_PATH"
docker exec "$CONTAINER_NAME" test -s "$OUTPUT_PATH"
```

默认输出 `/app/runtime/collectors/tom-oracle/snapshot.json`。文档明确这是本地只读导出，不切换中央读取路径。

- [x] **Step 4: Run final verification**

Run:

```bash
npm test -- test/collector-exporter.test.ts
npm test -- test/collector-snapshot.test.ts
npm test -- test/instance-config.test.ts
npm test -- test/multi-instance-readonly.test.ts
npm test -- test/oss-readiness.test.ts
npm test -- test/readonly-multi-instance-safety.test.ts
npm run build
```

Expected: all PASS.

- [x] **Step 5: Commit**

```bash
git add -f docs/superpowers/plans/2026-05-17-collector-exporter.md
git add .env.example docs/MULTI_INSTANCE_READONLY.md ops/tom-readonly/README.md ops/tom-readonly/collector-snapshot.sh package.json src/index.ts src/runtime/collector-exporter.ts task.md test/collector-exporter.test.ts test/oss-readiness.test.ts
git commit -m "feat: export readonly collector snapshots"
```

### Self-Review

- Spec coverage: 覆盖本地 exporter、CLI、Tom 运维脚本、文档和只读边界。
- Placeholder scan: 无 TBD/TODO/implement later。
- Type consistency: exporter 输出兼容 `loadCollectorSnapshotFile` 的 collector snapshot schema。
