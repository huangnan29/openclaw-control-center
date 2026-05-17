# 当前任务记录

## 当前目标

推进 OpenClaw 控制中心长期方案，但保持节奏不跑偏。当前只做第一阶段：**数据可信度增强**。

## 本轮任务

为多实例只读总览和单实例详情页增加数据来源标注，让用户能看清每个模块是来自真实 gateway、只读挂载、session status、推导，还是合成事件流。

## 本轮不做

- 不做真实日志文件解析。
- 不做真实 Agent 配置读取升级。
- 不做跨服务器 registry。
- 不做 collector。
- 不做任何写操作或管理动作。

## 当前下一步

真实 Agent 配置接入：让 Agent 名录优先读取每个实例配置文件，推导来源仅作为补充和异常提示。

## 最近完成

- 已新增长期推进计划：`implementation_plan.md`。
- 已新增 Superpowers 执行计划：`docs/superpowers/plans/2026-05-17-control-center-data-trust.md`。
- 已为总览页和单实例详情页增加数据来源标注。
- 已验证 `npm test -- test/ui-render-smoke.test.ts`。
- 已验证 `npm test -- test/readonly-multi-instance-safety.test.ts`。
- 已验证 `npm run build`。

## 阶段完成后的下一步

真实 Agent 配置接入：让 Agent 名录优先读取每个实例配置文件，推导来源仅作为补充和异常提示。
