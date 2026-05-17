# 跨服务器 Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让只读控制中心的 `OPENCLAW_INSTANCES_FILE` 同时支持旧版 `instances` 和新版 `servers[].instances`，并在 UI 中显示服务器维度的筛选与健康汇总。

**Architecture:** 配置加载层继续输出扁平实例列表，给每个由服务器 registry 声明的实例附加 `serverId/serverName/serverHost/serverRegion` 元数据；旧版 `instances` 保持兼容。UI 不新增写接口，只基于快照中的实例元数据做服务器汇总、筛选和详情展示。

**Tech Stack:** TypeScript、Node.js test runner、服务端渲染 HTML、只读 Docker/Tom 灰度脚本。

---

### Task 1: Registry 解析模型

**Files:**
- Modify: `src/types.ts`
- Modify: `src/runtime/instance-config.ts`
- Test: `test/instance-config.test.ts`

- [x] **Step 1: Write the failing test**

在 `test/instance-config.test.ts` 追加：

```ts
test("parseOpenClawInstanceConfigText accepts cross-server registry", () => {
  const result = parseOpenClawInstanceConfigText(
    JSON.stringify({
      servers: [
        {
          id: "tom-oracle",
          name: "Tom Oracle",
          host: "146.235.226.66",
          region: "oracle-us",
          instances: [
            {
              id: "tom-main",
              name: "Tom Main",
              gatewayUrl: "ws://127.0.0.1:18789",
              openclawHome: "/instances/main/config",
              workspaceRoot: "/instances/main/workspace",
            },
          ],
        },
      ],
    }),
    "inline",
  );

  assert.equal(result.issues.length, 0);
  assert.equal(result.servers?.[0]?.id, "tom-oracle");
  assert.equal(result.instances[0]?.serverId, "tom-oracle");
  assert.equal(result.instances[0]?.serverName, "Tom Oracle");
  assert.equal(result.instances[0]?.serverHost, "146.235.226.66");
  assert.equal(result.instances[0]?.serverRegion, "oracle-us");
});
```

- [x] **Step 2: Run test to verify it fails**

Run: `npm test -- test/instance-config.test.ts`

Expected: FAIL because `servers` is not parsed yet.

- [x] **Step 3: Write minimal implementation**

在 `src/types.ts` 新增 `OpenClawServerConfig`，并给 `OpenClawInstanceConfig` 添加可选服务器字段：

```ts
export interface OpenClawServerConfig {
  id: string;
  name: string;
  host?: string;
  region?: string;
  description?: string;
}
```

在 `src/runtime/instance-config.ts` 中：

```ts
const SERVER_ID_PATTERN = INSTANCE_ID_PATTERN;
```

新增解析 `servers[].instances` 的分支，并把服务器元数据复制到实例上。顶层 `instances` 的旧格式继续走原逻辑，不强制补服务器字段。

- [x] **Step 4: Run test to verify it passes**

Run: `npm test -- test/instance-config.test.ts`

Expected: PASS.

### Task 2: 服务器维度 UI 汇总和筛选

**Files:**
- Modify: `src/ui/server.ts`
- Test: `test/ui-render-smoke.test.ts`

- [x] **Step 1: Write the failing tests**

在 `test/ui-render-smoke.test.ts` 的多实例渲染用例中，让 `tom` 和 `jerry` 带不同 `serverId/serverName`，并断言：

```ts
assert(html.includes("服务器健康"));
assert(html.includes("Tom Oracle"));
assert(html.includes("Jerry Oracle"));
assert(html.includes('href="/?server=tom-oracle&amp;section=overview&amp;lang=zh"'));
```

在 route 用例中把 `OPENCLAW_INSTANCES_JSON` 改为新版 `servers` 配置，并请求：

```ts
const serverResponse = await fetch(`${baseUrl}/?server=tom-oracle&section=overview&lang=zh`);
assert.equal(serverResponse.status, 200);
const serverHtml = await serverResponse.text();
assert(serverHtml.includes("当前服务器：Tom Oracle"));
assert(serverHtml.includes("Tom Workspace"));
assert(!serverHtml.includes("Jerry Workspace"));
```

- [x] **Step 2: Run test to verify it fails**

Run: `npm test -- test/ui-render-smoke.test.ts`

Expected: FAIL because UI has no server summary/filter yet.

- [x] **Step 3: Write minimal implementation**

在 `src/ui/server.ts` 中新增只读 helper：

```ts
function instanceServerId(instance: OpenClawInstanceConfig): string {
  return instance.serverId?.trim() || "local";
}
```

新增服务器汇总、筛选链接、过滤后的 view snapshot。`startUiServer` 读取 `server` query 参数；总览页有 `server` 时只展示该服务器下的实例，详情页继续按 instance 参数优先。

- [x] **Step 4: Run test to verify it passes**

Run: `npm test -- test/ui-render-smoke.test.ts`

Expected: PASS.

### Task 3: 文档和 Tom 灰度健康检查

**Files:**
- Modify: `docs/MULTI_INSTANCE_READONLY.md`
- Modify: `.env.example`
- Modify: `ops/tom-readonly/healthcheck.sh`
- Modify: `task.md`
- Test: `test/oss-readiness.test.ts`

- [x] **Step 1: Write the failing test**

在 `test/oss-readiness.test.ts` 增加断言，确认文档包含 `servers`、`serverId`、`服务器健康` 或 `server=`。

- [x] **Step 2: Run test to verify it fails**

Run: `npm test -- test/oss-readiness.test.ts`

Expected: FAIL because docs do not describe cross-server registry yet.

- [x] **Step 3: Update docs and healthcheck**

文档增加新版 registry 示例：

```json
{
  "servers": [
    {
      "id": "tom-oracle",
      "name": "Tom Oracle",
      "host": "146.235.226.66",
      "instances": [
        {
          "id": "main",
          "name": "Main",
          "openclawHome": "/instances/main/config",
          "workspaceRoot": "/instances/main/workspace"
        }
      ]
    }
  ]
}
```

`ops/tom-readonly/healthcheck.sh` 检查总览包含 `服务器健康`，并保留原来的实例详情检查。

- [x] **Step 4: Run final verification**

Run:

```bash
npm test -- test/instance-config.test.ts
npm test -- test/ui-render-smoke.test.ts
npm test -- test/oss-readiness.test.ts
npm test -- test/readonly-multi-instance-safety.test.ts
npm run build
```

Expected: all PASS.

- [x] **Step 5: Commit**

```bash
git add -f docs/superpowers/plans/2026-05-17-cross-server-registry.md
git add src/types.ts src/runtime/instance-config.ts src/ui/server.ts test/instance-config.test.ts test/ui-render-smoke.test.ts test/oss-readiness.test.ts docs/MULTI_INSTANCE_READONLY.md .env.example ops/tom-readonly/healthcheck.sh task.md
git commit -m "feat: add cross-server readonly registry"
```

### Self-Review

- Spec coverage: 本计划覆盖跨服务器 registry 配置、旧配置兼容、UI 服务器筛选与健康汇总、文档和 Tom 健康检查。
- Placeholder scan: 无 TBD/TODO/implement later。
- Type consistency: 统一使用 `serverId/serverName/serverHost/serverRegion`，URL 查询参数统一使用 `server`。
