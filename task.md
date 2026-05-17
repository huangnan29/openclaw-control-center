# 当前任务记录

## 当前目标

最终上线 OpenClaw 控制中心：先完成不影响现有 OpenClaw 实例的跨服务器只读监控上线，再以 dry-run、人工确认、审计日志和白名单方式逐步上线受控管理动作。每个步骤验证通过后直接进入下一步。

## 本轮任务

生产执行器最小骨架：新增可测试的只读 `healthcheck` 生产执行器模块，但当前仍不接入 `/api/managed-actions/live`，Tom 上继续显示 `productionWired=false`。

## 本轮不做

- 不执行任何真实管理动作。
- 不修改任何 OpenClaw 实例目录。
- 不重启、不停止、不发布、不触发任何 OpenClaw 实例任务。
- 不让中央控制中心直接挂载远端实例目录。

## 当前下一步

设计 live 执行器挂载开关：

- 新增显式生产执行器挂载配置，默认关闭。
- 关闭时 live 路由行为完全不变。
- 关闭时 readiness 仍显示 `executor.productionWired=false`。
- 打开配置也必须继续受 live gate、dry-run 引用、rollout、确认短语共同约束。
- Tom 暂不启用该开关。

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
- 已让 `InstanceSnapshot` 携带 collector 元数据：`sourcePath`、`serverId`、`generatedAt`、`status`、`detail`。
- 已在多实例总览和实例详情页新增 `Collector 快照` 面板，展示来源路径、生成时间、年龄/上限和新鲜度。
- 已验证 `npm test -- test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts`。
- 已验证 `npm run build`。
- 已发现 Tom 之外的候选 Oracle 主机暂不能安全接入：22 端口可达，但 SSH banner 阶段超时；本轮不强行修改该主机。
- 已新增只读多实例模式下的管理动作 dry-run API：`GET /api/managed-actions` 与 `POST /api/managed-actions/dry-run`。
- 已新增白名单动作预览：`healthcheck`、`collector_refresh`、`skill_run`。
- 已确保 dry-run 返回 `liveExecution:false`、`dryRun:true`，并声明 `mutatesOpenClawInstance:false`。
- 已让 dry-run API 写入控制中心审计日志 `managed_action_dry_run`，不调用 OpenClaw 实例命令。
- 已把 `notification-center` 与导出包目录统一到 `OPENCLAW_RUNTIME_DIR` 兼容路径，修复测试隔离下的命令回归。
- 已验证 `npm test -- test/managed-actions-dry-run.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts`。
- 已验证 `npm test -- test/phase9-routes-commands.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `fc044df feat: add readonly managed action dry-run previews`。
- 已部署到 Tom，并验证运行提交 `fc044df`。
- 已验证 Tom `GET /api/managed-actions` 返回 3 个白名单动作：`healthcheck`、`collector_refresh`、`skill_run`。
- 已验证 Tom 未带本地令牌的 `POST /api/managed-actions/dry-run` 返回 401。
- 已验证 Tom 授权 dry-run 返回 `status=dry_run_ready`、`dryRun=true`、`liveExecution=false`、`mutatesOpenClawInstance=false`。
- 已验证 Tom 审计日志出现 `managed_action_dry_run`，目标实例为 `tom`。
- 已新增多实例总览页 `管理动作预览` UI，支持选择实例、动作、skill、原因和本地令牌。
- 已确保实例详情页仍不挂载管理动作 UI。
- 已提交并推送 `f09f899 feat: add managed action dry-run UI`。
- 已部署到 Tom，并验证运行提交 `f09f899`。
- 已验证页面包含 `管理动作预览`，浏览器页面树可见该入口。
- 已验证 `npm test -- test/ui-render-smoke.test.ts test/managed-actions-dry-run.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts`。
- 已验证 `npm run build`。
- 已让 dry-run API 要求 `operator`、`reason`、`confirmedText=DRY-RUN-ONLY`。
- 已让 dry-run 结果返回 `review.operationRequestId`、`review.operator`、`review.reason`、`review.confirmationTextMatched` 和 `review.targetConfigSnapshot`。
- 已让 dry-run 审计日志记录操作申请 ID、操作者、原因、确认结果和目标配置快照。
- 已让总览页 `管理动作预览` UI 增加操作者与确认短语输入。
- 已验证错误确认短语在带本地令牌时返回 400。
- 已验证 Tom 授权 dry-run 返回 `confirmationTextMatched=true`、`targetConfigSnapshot=tom`、`mutatesOpenClawInstance=false`。
- 已验证 Tom 审计日志包含 `operationRequestId`、`operator`、`confirmationTextMatched` 和 `targetConfigSnapshot`。
- 已提交并推送 `d86bfdd feat: require review metadata for managed action previews`。
- 已部署到 Tom，并验证运行提交 `d86bfdd`。
- 已验证 `npm test -- test/managed-actions-dry-run.test.ts test/ui-render-smoke.test.ts test/phase9-routes-commands.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts`。
- 已验证 `npm run build`。
- 已新增只读审计读取层：`src/runtime/managed-action-audit.ts`。
- 已新增 `GET /api/managed-actions/audit`，支持 `limit`、`instanceId`、`operator`、`action` 过滤。
- 已在多实例总览页新增 `管理动作审计` 面板，展示最近 dry-run 申请。
- 已让审计记录包含动作名、目标实例、操作者、原因、确认结果、命令预览和申请 ID。
- 已验证 `npm test -- test/managed-actions-dry-run.test.ts test/ui-render-smoke.test.ts test/phase9-routes-commands.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts`。
- 已验证 `npm run build`。
- 已新增配置项：`MANAGED_ACTIONS_LIVE_ENABLED=false` 默认关闭，`MANAGED_ACTIONS_LIVE_ALLOWED_ACTIONS` 默认为空。
- 已新增真实执行确认短语：`LIVE-ACTION-APPROVED`。
- 已新增 `/api/managed-actions/live`，当前只做闸门判断，不实现执行器。
- 已确保 live gate 默认返回 `blocked_disabled`、`liveExecution=false`。
- 已让 live gate 阻断记录写入 `managed_action_live_blocked` 审计。
- 已验证 `npm test -- test/managed-actions-dry-run.test.ts test/phase9-routes-commands.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `0f26baa feat: add disabled managed action live gate`。
- 已部署到 Tom，并验证运行提交 `0f26baa`。
- 已验证 Tom `/api/managed-actions/live` 在带本地令牌和 `LIVE-ACTION-APPROVED` 时仍返回 `blocked_disabled`。
- 已验证 Tom live gate 返回 `liveExecution=false`、`enabled=false`、`readonlyMode=true`、`allowedActions=[]`。
- 已验证 Tom 页面仍只有 `管理动作预览` 与 `管理动作审计`，没有真实执行入口。
- 已验证 Tom 审计日志写入 `managed_action_live_blocked`，且 `liveExecution=false`。
- 已新增执行器接口：`src/runtime/managed-action-executor.ts`。
- 已新增测试用 mock healthcheck executor。
- 已验证 gate 未 ready 时不会调用执行器。
- 已验证只有测试环境传入 mock executor 且 `gateReady=true` 时才会得到 `executed_mock`。
- 已验证未注册动作返回 `executor_missing` 且 `liveExecution=false`。
- 已验证 `npm test -- test/managed-action-executor.test.ts test/managed-actions-dry-run.test.ts test/phase9-routes-commands.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `9b2e52e feat: add managed action executor test seam`。
- 已部署到 Tom，并验证运行提交 `9b2e52e`。
- 已验证 Tom `/api/managed-actions/live` 仍返回 `blocked_disabled`、`liveExecution=false`、`enabled=false`、`readonlyMode=true`。
- 已验证 Tom 页面仍无真实执行入口。
- 已新增真实执行审计结果类型模块：`src/runtime/managed-action-live-audit.ts`。
- 已新增 `managed_action_live_result` 审计 action 类型。
- 已定义真实执行审计 metadata：`operationRequestId`、`operator`、`reason`、`executor`、`target`、`gate`、`commandPreview`、`durationMs`、`rollback`、`result`、`error`、`skip`。
- 已覆盖四类审计结果：`executed`、`failed`、`rolled_back`、`skipped`。
- 已验证 `executed` 与 `skipped` 为 `ok=true`，`failed` 与 `rolled_back` 为 `ok=false`。
- 已验证 `skipped` 不标记真实执行，`executed/failed/rolled_back` 标记 `liveExecution=true`。
- 已验证 `npm test -- test/managed-action-live-audit.test.ts test/managed-action-executor.test.ts test/managed-actions-dry-run.test.ts test/phase9-routes-commands.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts`。
- 已验证 `npm run build`。
- 已新增 dry-run 引用校验：按 `operationRequestId` 查找 `managed_action_dry_run` 审计记录。
- 已校验 live 请求引用的 dry-run 动作一致、目标实例一致、确认短语已通过、未超过默认 24 小时有效期。
- 已让 `/api/managed-actions/live` 返回 `dryRunReference` 摘要，包含 `valid`、`status`、`operationRequestId`、`ageMs`、`maxAgeMs` 和匹配记录摘要。
- 已让 live 阻断审计记录包含 `dryRunReference` 摘要。
- 已验证有效引用时 `dryRunReference.status=valid`。
- 已验证缺失引用时 `dryRunReference.status=missing`。
- 已验证动作不一致时 `dryRunReference.status=action_mismatch`。
- 已验证目标实例不一致时 `dryRunReference.status=target_mismatch`。
- 已验证 `npm test -- test/managed-actions-dry-run.test.ts test/managed-action-live-audit.test.ts test/managed-action-executor.test.ts test/phase9-routes-commands.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `0ec55da feat: validate live requests against dry-run audits`。
- 已部署到 Tom，并验证运行提交 `0ec55da`。
- 已验证 Tom 有效 dry-run 引用返回 `dryRunReference.status=valid`。
- 已验证 Tom 缺失引用返回 `dryRunReference.status=missing`。
- 已验证 Tom 动作不一致返回 `dryRunReference.status=action_mismatch`。
- 已验证 Tom `/api/managed-actions/live` 仍返回 `blocked_disabled`、`liveExecution=false`、`enabled=false`。
- 已验证 Tom 页面仍无真实执行入口。
- 已新增配置项：`MANAGED_ACTIONS_LIVE_ROLLOUT_FILE`。
- 已新增灰度配置解析模块：`src/runtime/managed-action-live-rollout.ts`。
- 已定义灰度规则字段：`action`、`instanceId`、`operators`、`risk`、`enabled`、`maxDryRunAgeMinutes`。
- 已验证默认配置为禁用且无规则。
- 已验证窄匹配规则只允许指定动作、实例和操作者。
- 已验证 `operators:["*"]` 支持通配操作者，但禁用规则不会放行。
- 已验证非法规则进入 `issues`，且不会被允许。
- 已验证可以从 JSON 文件加载灰度配置。
- 已验证 `npm test -- test/managed-action-live-rollout.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-audit.test.ts test/managed-action-executor.test.ts test/phase9-routes-commands.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `5a95f91 feat: add managed action live rollout config`。
- 已部署到 Tom，并验证运行提交 `5a95f91`。
- 已验证 Tom 没有配置 `MANAGED_ACTIONS_LIVE_ROLLOUT_FILE`。
- 已验证 Tom `/api/managed-actions/live` 仍返回 `blocked_disabled`、`liveExecution=false`、`enabled=false`。
- 已验证 Tom 页面仍无真实执行入口。
- 已将 rollout 决策接入 `/api/managed-actions/live` 响应和 `managed_action_live_blocked` 审计。
- 已新增 `blocked_rollout_not_allowed` gate 状态。
- 已验证全部安全检查通过但 rollout 不匹配时会被 `blocked_rollout_not_allowed` 拦截。
- 已验证全部安全检查和 rollout 都通过时仍返回 `ready_not_implemented`，因为当前没有生产执行器。
- 已验证 live 响应包含 `rollout.allowed`、`rollout.status`、`rollout.message` 和可选规则摘要。
- 已验证 `npm test -- test/managed-action-live-gate.test.ts test/managed-action-live-rollout.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-audit.test.ts test/managed-action-executor.test.ts test/phase9-routes-commands.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `342105c feat: surface rollout decisions in live gate`。
- 已部署到 Tom，并验证运行提交 `342105c`。
- 已验证 Tom live 响应返回 `dryRunReference=valid`、`rollout.status=disabled`。
- 已验证 Tom live 仍返回 `blocked_disabled`、`liveExecution=false`、`enabled=false`。
- 已验证 Tom 页面仍无真实执行入口。
- 已新增只读 readiness 建模：`src/runtime/managed-action-live-readiness.ts`。
- 已新增 `GET /api/managed-actions/readiness`。
- 已在多实例总览页和单实例详情页新增 `真实执行上线条件` 卡片。
- 已验证 readiness 卡片只读展示 live gate、rollout、dry-run 审计和执行器接入状态。
- 已验证 readiness API 返回 `liveExecutionAttempted=false`、`mutatesOpenClawInstance=false`。
- 已验证页面卡片不调用 `/api/managed-actions/live`，不提供真实执行按钮。
- 已验证 `npm test -- test/managed-action-live-readiness.test.ts test/managed-action-live-gate.test.ts test/managed-action-live-rollout.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-audit.test.ts test/managed-action-executor.test.ts test/phase9-routes-commands.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `0fc5fbe feat: add managed action live readiness diagnostics`。
- 已部署到 Tom，并验证运行提交 `0fc5fbe`。
- 已验证 Tom `healthcheck.sh` 通过，5 个 gateway 健康端口通过。
- 已验证 Tom readiness 返回 `status=blocked`、`liveExecutionAvailable=false`、`liveExecutionAttempted=false`、`mutatesOpenClawInstance=false`。
- 已验证 Tom readiness 返回 `gate.enabled=false`、`gate.readonlyMode=true`、`rollout.enabled=false`、`executor.productionWired=false`。
- 已验证 Tom 总览页和实例详情页都出现 `真实执行上线条件`。
- 已验证 Tom 总览页不包含 `/api/managed-actions/live` 前端调用，也不包含真实执行确认短语。
- 已新增生产执行器骨架：`src/runtime/managed-action-production-executor.ts`。
- 已验证生产执行器骨架只注册只读 `healthcheck`，不注册 `collector_refresh` 和 `skill_run`。
- 已验证该骨架当前仅被测试引用，未接入 live 路由。
- 已验证 `npm test -- test/managed-action-executor.test.ts test/managed-action-live-readiness.test.ts test/managed-actions-dry-run.test.ts test/phase9-routes-commands.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `ce71ff0 feat: add production managed action executor skeleton`。
- 已部署到 Tom，并验证运行提交 `ce71ff0`。
- 已验证 Tom `healthcheck.sh` 通过，5 个 gateway 健康端口通过，容器只读边界通过。
- 已验证 Tom readiness 仍返回 `status=blocked`、`liveExecutionAvailable=false`、`liveExecutionAttempted=false`、`mutatesOpenClawInstance=false`。
- 已验证 Tom readiness 仍返回 `executor.productionWired=false`、`executor.status=missing`。
- 已验证 Tom 总览页仍无 `/api/managed-actions/live` 前端调用，也无真实执行确认短语。

## 阶段完成后的下一步

live 执行器挂载开关设计：只允许通过显式配置把生产执行器接到 live 路由，默认关闭；Tom 暂不启用。
