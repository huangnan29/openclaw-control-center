# 当前任务记录

## 当前目标

推进 OpenClaw 控制中心长期方案，但保持节奏不跑偏。当前推进到第五阶段：**中央 collector 架构（只读）**。

## 本轮任务

Tom collector 定时化已完成并部署到 Tom：Tom 当前会通过 cron 定时生成 collector 快照，`healthcheck.sh` 会检查快照新鲜度，避免中央 UI 长期读取过期快照。

## 本轮不做

- 不做任何写操作或管理动作。
- 不做 HTTP collector 服务。
- 不接入 Tom 之外的其他 Oracle 服务器。
- 不让中央控制中心直接挂载远端实例目录。

## 当前下一步

将 collector 快照时间、来源和过期状态更明确地显示到 UI 中，方便从页面上判断数据是否仍然可信。

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
- 已新增 collector 快照接入计划：`docs/superpowers/plans/2026-05-17-collector-snapshot-ingestion.md`。
- 已让 server registry 支持 `collectorSnapshotPath`。
- 已新增 collector 快照文件解析器：`src/runtime/collector-snapshot.ts`。
- 已让多实例只读 adapter 对配置了 `collectorSnapshotPath` 的实例优先使用 collector 快照。
- 已新增 collector exporter：`src/runtime/collector-exporter.ts`。
- 已新增命令：`npm run collector:snapshot -- <output-path>` 与 `node dist/index.js collector-snapshot <output-path>`。
- 已新增 Tom 快照脚本：`ops/tom-readonly/collector-snapshot.sh`。
- 已在 Tom 备份切流前 registry：`runtime/deploy-state/instances.before-collector-cutover.20260517044631.json.bak`。
- 已在 Tom 生成最新 collector 快照：`/app/runtime/collectors/tom-oracle/snapshot.json`。
- 已把 Tom `config/instances.json` 的 `tom-oracle` 指向 `collectorSnapshotPath`。
- 已验证总览页和实例详情页出现 `collector ok`，Tom `healthcheck.sh` 通过。
- 已新增 Tom collector 定时化计划：`docs/superpowers/plans/2026-05-17-collector-snapshot-scheduling.md`。
- 已新增 `ops/tom-readonly/install-collector-cron.sh`，通过 `OPENCLAW_COLLECTOR_CRON_BEGIN` 标记块幂等安装快照 cron。
- 已让 `ops/tom-readonly/healthcheck.sh` 检查 `collectorSnapshotPath` 快照新鲜度，默认 `COLLECTOR_SNAPSHOT_MAX_AGE_SECONDS=300`。
- 已提交并推送 `200660d feat: schedule tom collector snapshots`。
- 已部署到 Tom，并验证运行代码提交 `200660d`。
- 已在 Tom 安装 cron：`*/2 * * * *`。
- 已确认 cron 自动刷新快照：`generatedAt` 从 `2026-05-17T04:58:07.916Z` 更新到 `2026-05-17T05:00:01.779Z`。
- 已验证 Tom 新版 `healthcheck.sh` 通过，collector 快照检查为 `server=tom-oracle`、`instances=5`。

## 阶段完成后的下一步

UI collector 可见性增强：在总览和详情页展示 collector 快照生成时间、最大允许年龄和来源状态。
