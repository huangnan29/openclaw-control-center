# 当前任务记录

## 当前目标

推进 OpenClaw 控制中心长期方案，但保持节奏不跑偏。当前仍处于第一阶段：**数据可信度增强**。

## 本轮任务

真实 Agent 配置接入已完成：Agent 名录优先读取每个实例配置文件，推导来源仅作为补充和异常提示。

## 本轮不做

- 不做真实日志文件解析。
- 不做跨服务器 registry。
- 不做 collector。
- 不做任何写操作或管理动作。

## 当前下一步

真实日志接入：把最近日志从“快照合成事件流”升级为“真实 runtime 日志优先，合成事件流 fallback”。

## 最近完成

- 已新增长期推进计划：`implementation_plan.md`。
- 已新增 Superpowers 执行计划：`docs/superpowers/plans/2026-05-17-control-center-data-trust.md`。
- 已为总览页和单实例详情页增加数据来源标注。
- 已验证 `npm test -- test/ui-render-smoke.test.ts`。
- 已验证 `npm test -- test/readonly-multi-instance-safety.test.ts`。
- 已验证 `npm run build`。
- 已新增 Agent 配置名录接入计划：`docs/superpowers/plans/2026-05-17-agent-config-roster.md`。
- 已让只读 snapshot 携带实例级 `agentRoster`。
- 已让 UI Agent 名录优先展示配置 Agent，并把推导来源作为补充。
- 已验证 `npm test -- test/agent-roster.test.ts`。
- 已验证 `npm test -- test/multi-instance-readonly.test.ts`。

## 阶段完成后的下一步

真实日志接入：把最近日志从“快照合成事件流”升级为“真实 runtime 日志优先，合成事件流 fallback”。
