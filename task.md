# 当前任务记录

## 当前目标

推进 OpenClaw 控制中心长期方案，但保持节奏不跑偏。当前推进到第四阶段：**跨服务器 registry（只读）**。

## 本轮任务

跨服务器 registry 已进入实现：配置层支持 `servers[].instances`，UI 支持服务器健康汇总和 `server=` 只读筛选。

## 本轮不做

- 不做 collector。
- 不做任何写操作或管理动作。
- 不做跨服务器真实采集，只表达服务器与实例的 registry 关系。

## 当前下一步

完成跨服务器 registry 验证与 Tom 灰度部署；随后进入下一步：中央 collector 架构设计，但仍保持只读。

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
- 已新增真实 runtime 日志接入计划：`docs/superpowers/plans/2026-05-17-runtime-log-ingestion.md`。
- 已新增只读 runtime 日志扫描器：`src/runtime/runtime-logs.ts`。
- 已让只读 snapshot 携带实例级 `runtimeLogs`。
- 已让 UI 最近日志真实日志优先，无真实日志时 fallback 到合成事件。
- 已验证 `npm test -- test/runtime-logs.test.ts`。
- 已新增跨服务器 registry 计划：`docs/superpowers/plans/2026-05-17-cross-server-registry.md`。
- 已让 `OPENCLAW_INSTANCES_FILE` 支持旧版 `instances` 与新版 `servers[].instances`。
- 已让 UI 显示服务器健康、服务器筛选和实例详情中的服务器元数据。

## 阶段完成后的下一步

中央 collector 架构设计：每台 Oracle 本地只读采集，中央 control-center 汇总 collector 快照。
