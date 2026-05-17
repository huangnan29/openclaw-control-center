# 真实 Runtime 日志接入 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把多实例只读控制中心的 `最近日志` 从纯快照合成事件流，升级为真实 runtime 日志优先、无真实日志时 fallback 到合成事件流。

**Architecture:** 新增只读 runtime 日志扫描器，按实例 `workspaceRoot/openclawHome/openclawConfigPath` 推导候选日志目录。`ReadModelSnapshot` 增加可选 `runtimeLogs`，UI 渲染时每个实例优先使用 `runtimeLogs.entries`，没有真实日志时才使用现有合成事件。

**Tech Stack:** TypeScript、Node.js `fs/promises`、Node.js 内置 `node:test`、现有 server-side HTML 渲染、Tom Docker Compose 灰度部署。

---

## 文件结构

- Create: `src/runtime/runtime-logs.ts`  
  只读扫描实例候选日志目录，解析 `.log` 和 `.jsonl` 最近行。
- Modify: `src/types.ts`  
  增加 `RuntimeLogEntry`、`RuntimeLogSnapshot`，并在 `ReadModelSnapshot` 加可选 `runtimeLogs`。
- Modify: `src/adapters/openclaw-readonly.ts`  
  snapshot 中读取实例级 runtime 日志。
- Modify: `src/adapters/multi-instance-readonly.ts`  
  空快照增加 `runtimeLogs` fallback。
- Modify: `src/ui/server.ts`  
  最近日志优先展示真实日志，缺失时展示合成事件。
- Create: `test/runtime-logs.test.ts`  
  覆盖文本日志和 JSONL 日志解析。
- Modify: `test/multi-instance-readonly.test.ts`  
  覆盖 adapter snapshot 携带真实 runtime 日志。
- Modify: `test/ui-render-smoke.test.ts`  
  覆盖 UI 显示真实 runtime 日志优先的来源说明。
- Modify: `task.md`  
  完成后把下一步更新为跨服务器 registry 设计。

## Task 1: Runtime 日志扫描器

- [ ] **Step 1: 写失败测试**

创建 `test/runtime-logs.test.ts`，构造临时 `workspace/runtime/logs/control.log` 和 `workspace/logs/events.jsonl`，断言 `loadRuntimeLogs` 能返回排序后的日志条目。

- [ ] **Step 2: 实现扫描器**

创建 `src/runtime/runtime-logs.ts`，实现：

- 候选目录：`workspaceRoot/runtime/logs`、`workspaceRoot/logs`、`workspaceRoot/runtime`、`openclawHome/runtime/logs`、`openclawHome/logs`。
- 文件类型：`.log`、`.jsonl`。
- 单文件只读最后 64KB。
- JSONL 优先解析 `timestamp/level/message`。
- 文本日志解析行首 ISO 时间；缺失时间时使用文件 mtime。

- [ ] **Step 3: 验证**

Run:

```bash
npm test -- test/runtime-logs.test.ts
```

Expected: PASS。

## Task 2: Snapshot 和 UI 接入

- [ ] **Step 1: 写失败测试**

在 `test/multi-instance-readonly.test.ts` 里增加 adapter snapshot 的 `runtimeLogs` 断言。  
在 `test/ui-render-smoke.test.ts` 中增加“真实 runtime 日志优先”和真实日志消息断言。

- [ ] **Step 2: 实现接入**

修改 adapter 和 UI，确保：

- 有真实日志时显示真实日志。
- 无真实日志时仍显示合成事件流。
- 来源标注说明真实日志优先。

- [ ] **Step 3: 验证**

Run:

```bash
npm test -- test/runtime-logs.test.ts
npm test -- test/multi-instance-readonly.test.ts
npm test -- test/ui-render-smoke.test.ts
npm test -- test/readonly-multi-instance-safety.test.ts
npm run build
```

Expected: 全部通过。

## Task 3: 部署和下一步

- [ ] **Step 1: 提交推送**

Run:

```bash
git add src/types.ts src/runtime/runtime-logs.ts src/adapters/openclaw-readonly.ts src/adapters/multi-instance-readonly.ts src/ui/server.ts test/runtime-logs.test.ts test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts task.md
git add -f docs/superpowers/plans/2026-05-17-runtime-log-ingestion.md
git commit -m "feat: prefer real runtime logs in readonly monitoring"
git push origin multi-instance-readonly-control-center
```

- [ ] **Step 2: 部署 Tom**

Run:

```bash
ssh -i /Users/anan/.ssh/oracle-oracle.key ubuntu@146.235.226.66 'cd /srv/openclaw-control-center-readonly && ./update.sh'
```

- [ ] **Step 3: 更新下一步**

把 `task.md` 的当前下一步改为：跨服务器 registry 设计。

