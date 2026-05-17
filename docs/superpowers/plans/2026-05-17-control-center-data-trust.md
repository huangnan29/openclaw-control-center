# 控制中心数据可信度 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给多实例只读控制中心增加数据来源标注，让每个监控模块明确说明自己来自真实读取、只读挂载、session status、推导还是合成事件流。

**Architecture:** 保持现有 `MultiInstanceSnapshot` 和只读 adapter 不变，仅在 UI 渲染层增加来源说明。总览页和单实例详情页复用同一组渲染函数，避免两个页面口径分裂。

**Tech Stack:** TypeScript、Node.js 内置 `node:test`、现有 HTML server-side rendering、Tom 上 Docker Compose 灰度部署。

---

## 文件结构

- Modify: `test/ui-render-smoke.test.ts`  
  增加来源标注断言，覆盖总览和单实例详情。
- Modify: `src/ui/server.ts`  
  为 `实例健康`、`Agent 名录`、`用量`、`最近任务`、`最近日志` 增加来源标注。
- Modify: `task.md`  
  本轮完成后把下一步更新为真实 Agent 配置接入。

## Task 1: 数据来源标注

**Files:**

- Modify: `test/ui-render-smoke.test.ts`
- Modify: `src/ui/server.ts`

- [ ] **Step 1: 写失败测试**

在 `test/ui-render-smoke.test.ts` 的多实例 overview 测试中增加断言：

```ts
assert(html.includes("数据来源"));
assert(html.includes("gateway 连接状态 + 会话状态推导"));
assert(html.includes("会话、任务负责人、审批和预算范围合并推导"));
assert(html.includes("session status token 字段"));
assert(html.includes("只读任务存储"));
assert(html.includes("快照合成事件流"));
```

在单实例 detail 测试中增加相同核心断言：

```ts
assert(detailHtml.includes("数据来源"));
assert(detailHtml.includes("gateway 连接状态 + 会话状态推导"));
assert(detailHtml.includes("会话、任务负责人、审批和预算范围合并推导"));
assert(detailHtml.includes("session status token 字段"));
assert(detailHtml.includes("只读任务存储"));
assert(detailHtml.includes("快照合成事件流"));
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```bash
npm test -- test/ui-render-smoke.test.ts
```

Expected: FAIL，失败点是缺少 `数据来源` 或具体来源文案。

- [ ] **Step 3: 实现来源标注**

在 `src/ui/server.ts` 增加一个小型辅助函数：

```ts
function renderDataSourceNote(language: UiLanguage, source: string): string {
  return `<div class="source-note"><span>${escapeHtml(pickUiText(language, "Data source", "数据来源"))}</span>${escapeHtml(source)}</div>`;
}
```

然后在这些 panel 的 `panel-head` 或正文开头加入来源说明：

```ts
renderDataSourceNote(language, t("Gateway connection state + derived session status.", "gateway 连接状态 + 会话状态推导"))
renderDataSourceNote(language, t("Merged from sessions, task owners, approvals, and budget scopes.", "会话、任务负责人、审批和预算范围合并推导"))
renderDataSourceNote(language, t("Session status token fields.", "session status token 字段"))
renderDataSourceNote(language, t("Readonly task store.", "只读任务存储"))
renderDataSourceNote(language, t("Synthetic event stream generated from snapshots.", "快照合成事件流"))
```

- [ ] **Step 4: 运行 smoke 测试确认通过**

Run:

```bash
npm test -- test/ui-render-smoke.test.ts
```

Expected: PASS，33 个测试通过。

- [ ] **Step 5: 运行只读安全测试**

Run:

```bash
npm test -- test/readonly-multi-instance-safety.test.ts
```

Expected: PASS，写接口仍返回 403。

- [ ] **Step 6: 运行构建**

Run:

```bash
npm run build
```

Expected: PASS。

- [ ] **Step 7: 提交并部署**

Run:

```bash
git add src/ui/server.ts test/ui-render-smoke.test.ts implementation_plan.md task.md docs/superpowers/plans/2026-05-17-control-center-data-trust.md
git commit -m "feat: label readonly data sources"
git push origin multi-instance-readonly-control-center
ssh -i /Users/anan/.ssh/oracle-oracle.key ubuntu@146.235.226.66 'cd /srv/openclaw-control-center-readonly && ./update.sh'
```

Expected: Tom 部署到新提交，`./healthcheck.sh` 通过。

## Task 2: 下一步锚点更新

**Files:**

- Modify: `task.md`

- [ ] **Step 1: 更新下一步**

把 `task.md` 中的“当前下一步”改为：

```md
## 当前下一步

真实 Agent 配置接入：让 Agent 名录优先读取每个实例配置文件，推导来源仅作为补充和异常提示。
```

- [ ] **Step 2: 验证文档**

Run:

```bash
sed -n '1,160p' task.md
```

Expected: 当前下一步明确指向真实 Agent 配置接入。

