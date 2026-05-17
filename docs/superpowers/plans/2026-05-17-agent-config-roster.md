# Agent 配置名录接入 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让多实例只读控制中心的 Agent 名录优先读取每个实例的真实 `openclaw.json` Agent 配置，推导来源仅作为补充和异常提示。

**Architecture:** 保持现有只读 adapter 和 UI 路由不变，在 `ReadModelSnapshot` 中增加可选 `agentRoster`。`OpenClawReadonlyAdapter` 使用实例级 `openclawHome/openclawConfigPath` 读取配置名录，UI 的 Agent 名录先渲染配置 Agent，再合并会话、任务 owner、审批和预算范围。

**Tech Stack:** TypeScript、Node.js 内置 `node:test`、现有 server-side HTML 渲染、Tom Docker Compose 灰度部署。

---

## 文件结构

- Modify: `src/types.ts`  
  增加通用 `AgentRosterEntry`、`AgentRosterSnapshot` 类型，并在 `ReadModelSnapshot` 中增加可选 `agentRoster`。
- Modify: `src/runtime/agent-roster.ts`  
  支持传入实例级 `openclawHome/configPath`，并继续保留默认环境变量行为。
- Modify: `src/adapters/openclaw-readonly.ts`  
  在 snapshot 中读取实例级 Agent 配置名录。
- Modify: `src/adapters/multi-instance-readonly.ts`  
  创建单实例 adapter 时传入实例配置。
- Modify: `src/ui/server.ts`  
  Agent 名录优先展示配置 Agent，推导 Agent 作为补充。
- Modify: `test/agent-roster.test.ts`  
  覆盖 scoped roster。
- Modify: `test/multi-instance-readonly.test.ts`  
  覆盖 adapter snapshot 中的实例级 agentRoster。
- Modify: `test/ui-render-smoke.test.ts`  
  覆盖配置中存在但暂无会话的 Agent 仍可见。
- Modify: `task.md`  
  完成后把下一步更新为真实日志接入。

## Task 1: Agent 配置名录进入 snapshot

- [ ] **Step 1: 写失败测试**

在 `test/multi-instance-readonly.test.ts` 增加测试：创建临时 `openclaw.json`，用 `OpenClawReadonlyAdapter(new ReadonlyToolClient(), instance)` 生成 snapshot，断言 `snapshot.agentRoster.entries` 包含配置中的 Agent。

- [ ] **Step 2: 运行失败测试**

Run:

```bash
npm test -- test/multi-instance-readonly.test.ts
```

Expected: FAIL，`agentRoster` 不存在或 adapter 构造函数不支持实例参数。

- [ ] **Step 3: 实现 snapshot 字段**

修改 `src/types.ts`、`src/runtime/agent-roster.ts`、`src/adapters/openclaw-readonly.ts`、`src/adapters/multi-instance-readonly.ts`。

- [ ] **Step 4: 运行测试通过**

Run:

```bash
npm test -- test/multi-instance-readonly.test.ts
```

Expected: PASS。

## Task 2: UI 配置优先展示

- [ ] **Step 1: 写失败测试**

在 `test/ui-render-smoke.test.ts` 的多实例 smoke snapshot 中设置 `agentRoster`，断言配置中但没有会话的 Agent 显示出来，并断言来源文案包含“实例配置优先”。

- [ ] **Step 2: 实现 UI 合并逻辑**

修改 `src/ui/server.ts`，先用 `snapshot.agentRoster.entries` 建立 Agent 行，再合并会话、任务 owner、审批和预算范围。

- [ ] **Step 3: 验证**

Run:

```bash
npm test -- test/ui-render-smoke.test.ts
npm test -- test/readonly-multi-instance-safety.test.ts
npm run build
```

Expected: 全部通过。

## Task 3: 部署和下一步

- [ ] **Step 1: 提交推送**

Run:

```bash
git add src/types.ts src/runtime/agent-roster.ts src/adapters/openclaw-readonly.ts src/adapters/multi-instance-readonly.ts src/ui/server.ts test/agent-roster.test.ts test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts task.md docs/superpowers/plans/2026-05-17-agent-config-roster.md
git commit -m "feat: load configured agents per readonly instance"
git push origin multi-instance-readonly-control-center
```

- [ ] **Step 2: 部署 Tom**

Run:

```bash
ssh -i /Users/anan/.ssh/oracle-oracle.key ubuntu@146.235.226.66 'cd /srv/openclaw-control-center-readonly && ./update.sh'
```

- [ ] **Step 3: 更新下一步**

把 `task.md` 的当前下一步改为：真实日志接入。

