# OpenClaw 控制中心长期推进计划

## 总目标

把 `openclaw-control-center` 从 Tom 单机灰度只读面板，推进到最终上线：当前生产范围是一台 Oracle 上的多套 OpenClaw 实例，先完成 Tom 本机多实例只读监控和受控管理动作；实例扩展通过 registry/collector 继续追加。跨服务器采集保留为后续显式拓扑模式，不作为当前上线阻塞。推进顺序必须先保证数据可信，再上线 dry-run/人工确认/审计/白名单保护下的写动作。

## 当前阶段

当前阶段推进 **Tom 单 Oracle 本机多实例上线** 与 **人工批准的只读 healthcheck live 演练**：中央 control-center 已完成 registry、collector snapshot 读取、本地 exporter、Tom collector cron、本机最终上线状态汇总入口、最终上线总闸门、本机最终上线推进 runner、本机实例安全注册脚本、dry-run API、dry-run UI、OpenClaw/Discord 可调用的管理动作 dry-run 命令入口、文本指令解析、机器人文本桥接层、workspace inbox runner 和 Tom `AGENTS.md` inbox 规范安装器、dry-run 证据闸门、人工确认字段、审计检索视图、默认关闭的 live gate、测试用 mock executor、真实执行审计结果类型、dry-run 引用校验、灰度配置解析、rollout 决策响应、只读 readiness 卡片、生产执行器最小骨架、显式挂载开关、只读 healthcheck 人工演练材料、Tom preflight、一次性演练窗口脚本、实例影响快照留证、结构化 approval 记录、approval 准备/状态查看、批准前证据包生成与校验、批准前只读 approval review 汇总、显式 approval `approve` 记录命令、approval `approve` 前强制证据包校验、只读 live healthcheck readiness 汇总、自动推进到人工批准前和人工批准后的 live healthcheck rollout runner、final runner 重复 `prepare` 幂等返回人工批准/已批准边界、approval 一次性 `consume` 状态和演练报告生成、显式确认的 `approve-and-run` 本机总入口。`OPENCLAW_TOPOLOGY_MODE` 默认 `local-only`，因此第二台 Oracle host/key 不再阻塞当前上线；同一台 Oracle 新增实例时，使用 `register-local-instance.sh plan/apply` 只更新 control-center registry 与 compose 只读挂载，再刷新 collector snapshot 和 healthcheck；如果未来扩展到其他 Oracle，再显式设置 `OPENCLAW_TOPOLOGY_MODE=cross-server` 并使用已保留的远端凭据发现、onboarding、preflight、pull、register 和 rollout runner 链路。Tom 仍不默认启用 live gate 或 executor；下一步可用 `final-go-live-runner.sh prepare` 从本机总入口自动执行最终 `check`、Tom runner prepare 和复核，停在人工批准前；如果已经到达人工批准边界，重复执行 `prepare` 会直接返回当前边界，不再次写 Tom runtime；OpenClaw/Discord 可以先让 Tom 在 workspace 的 `control-center-commands/inbox/*.txt` 写入“对 tom 运行 zhihu-human-ops-writing dry-run”，再由 `managed-action-inbox-runner.sh status/plan-next/run-next` 通过只读挂载读取 inbox、调用 `managed-action-text-bridge.sh`，预览 `healthcheck`、`collector_refresh`、`skill_run`；`install-managed-action-agents-instructions.sh` 只把这条行为规范安装进 Tom workspace 的 `AGENTS.md` 受控标记块，并备份原文件，不修改 `openclaw.json`、不重启实例；该入口要求文本明确包含 dry-run/预览/演练并拒绝 live、发布、重启、approval 等高风险词，只调用 dry-run API 生成审计，不执行实例命令，不移动或删除 OpenClaw workspace 文件，并可在显式 `MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container` 时从 control-center 容器读取本地令牌而不打印；readiness、approval review、dry-run gate 和总闸门输出的下一步都已收敛到 runner 主链路；人工 approval 由 Anan 审查后，`final-go-live-runner.sh approve-and-run` 可以在强确认、批准人和本地令牌齐全时先只读复核 approval review，再记录 approval 并执行一次 `healthcheck` live 演练；也可以先手动 approval，再用 `final-go-live-runner.sh run-approved` 或 Tom `live-healthcheck-rollout-runner.sh run-approved` 执行。前置条件或人工批准未满足时 runner 返回非 0，避免自动化误判阻断态为成功。

补充当前状态：本机已执行 `final-go-live-runner.sh prepare`，Tom 已生成并校验 live healthcheck approval packet，当前 readiness 为 `waiting_human_approval`，approval 文件仍为 `needs_manual_approval`。这一阶段只写 control-center runtime 与 approval 模板/证据包，不批准、不打开 live gate、不调用 managed action live API、不修改 OpenClaw 实例目录、不重启实例。下一步需要 Anan 人工审查后显式执行 `approve-and-run` 或手动 approval 后再 `run-approved`；在拿到明确批准前仍只允许继续做准备、复核、测试和部署。

补充 dry-run inbox 状态：`managed-action-inbox-runner.sh run-pending` 已作为 `run-next` 的批处理入口，必须使用同一个显式确认短语，最多处理 `MANAGED_ACTION_INBOX_MAX_PER_RUN` 条待处理请求，只调用文本桥接层 dry-run，只写 control-center runtime，不移动、不删除、不修改 OpenClaw workspace 请求文件。

补充自动消费状态：`install-managed-action-inbox-cron.sh` 已作为 `run-pending` 的受控 cron 安装入口设计并同步到 Tom；`status/plan` 不写 crontab，`apply/remove` 必须显式确认，只更新当前用户 crontab 的 `OPENCLAW_MANAGED_ACTION_INBOX_CRON` 标记块。Tom 当前 `status` 为 `inbox_cron_installed` 且 `needsUpdate=false`；已通过 workspace inbox smoke 验证 cron 自动执行 `run-pending`，把“对 tom 运行 zhihu-human-ops-writing dry-run”转换为 `skill_run` dry-run 审计。该 cron 只用于自动创建 dry-run 审计，不调用 live API、不修改实例目录、不重启实例。

## 推进原则

1. 每次只推进一个可验证的小闭环。
2. 每个闭环必须明确：目标、修改文件、验证命令、部署结果、下一步。
3. 所有监控数据必须标注来源，区分真实读取、只读挂载、推导和合成。
4. 管理动作必须排在数据可信之后，且必须从 dry-run 和人工确认开始。
5. 每次推进结束必须更新 `task.md`，确保下一步不会丢失。
6. 任何阶段都不能影响当前正在运行的 OpenClaw 实例；默认不写实例目录、不重启实例、不触发实例任务。

## 阶段路线

### 阶段 1：数据可信度增强

目标：让页面上的每个关键模块都能说明数据来源。

范围：

- 实例健康：标注为 gateway 连接状态 + 会话状态推导。
- Agent 名录：标注为会话、任务 owner、审批、预算 scope 合并推导。
- 用量：标注为 session status token 字段统计。
- 最近任务：标注为只读任务存储。
- 最近日志：标注为快照合成事件流。

验收：

- 总览页和单实例详情页都显示数据来源。
- UI smoke 测试覆盖来源标注。
- 只读安全测试继续通过。
- Tom 部署后 `healthcheck.sh` 通过。

### 阶段 2：真实 Agent 配置接入

目标：把 Agent 名录从推导版升级为配置优先版。

范围：

- 读取每个实例的 `openclaw.json` 或当前项目 agent 配置。
- 保留会话和任务 owner 作为补充来源。
- UI 区分“配置存在但未运行”和“运行中出现但配置缺失”。

验收：

- Agent 名录能显示配置来源。
- 无 agent 配置时仍可回退到推导来源。

### 阶段 3：真实日志接入

目标：把最近日志从合成事件流升级为真实日志优先。

范围：

- 只读读取每个实例 runtime 日志目录。
- 解析最近日志行，展示来源文件和时间。
- 合成日志保留为 fallback。

验收：

- UI 明确展示真实日志文件来源。
- 日志读取失败不会影响实例快照展示。

### 阶段 4：跨服务器 registry

目标：把当前 `instances.json` 升级为 `servers + instances` 模型。

范围：

- 设计 `servers.json` 或扩展 `instances.json`。
- 支持 Tom 之外的 Oracle 服务器。
- UI 增加服务器维度筛选和健康汇总。

验收：

- Tom 保持兼容。
- 新配置可以表达多服务器、多实例。

### 阶段 5：中央 collector 架构

目标：每台 Oracle 服务器本地运行只读 collector，中央 control-center 汇总 collector。

范围：

- collector 只读采集本机实例。
- 中央 UI 聚合所有 collector 的 snapshot。
- collector 与中央之间只传监控数据，不暴露实例目录写权限。

验收：

- 中央控制中心无需直接挂载远端实例目录。
- 单台服务器 collector 故障不影响其他服务器。

### 阶段 6：受控管理动作

目标：在监控可信后，逐步增加人工确认下的管理动作。

范围：

- 从 dry-run 开始。
- 每个动作必须有审计日志和人工确认。
- 优先级：健康检查、日志刷新、skill 触发、实例重启。

验收：

- 默认仍是只读。
- 写动作必须显式开启、显式确认、可审计。

当前落地顺序：

1. 白名单动作 dry-run API：只预览健康检查、collector 刷新、skill 调用。
2. UI dry-run 入口：页面上可选择实例和动作，只能预览，不能执行。
3. 人工确认与审计增强：确认文本、操作者、原因、目标实例快照摘要全部入审计。
4. dry-run 审计检索视图：页面可复核最近的预览申请和审计结果。
5. 白名单真实执行设计：先实现配置、闸门和测试，默认关闭，不在 Tom 执行真实动作。
6. 真实执行审计结果类型：定义成功、失败、回滚、跳过四类结构。
7. 真实执行前置 dry-run 申请有效性校验：确认 live 请求必须引用仍有效的 dry-run 申请。
8. 单动作真实执行灰度配置文件：解析允许动作、实例、操作者和风险等级，默认禁用。
9. rollout 决策接入 live gate 响应：即使 live 默认关闭，也能看到灰度规则是否匹配。
10. live readiness 诊断卡：只读展示 live gate、dry-run 引用、rollout、执行器接入状态。
11. healthcheck live preflight：只读检查 rollout、live 开关和 readiness，不调用 live API。
12. live healthcheck 演练切换与回滚脚本：只作用于 control-center 容器配置，演练后必须回到只读监控状态。
13. 实例影响快照留证：演练前后比较 gateway、监听端口、容器挂载、live 开关和 readiness。
14. 结构化人工批准记录：打开 live 窗口前校验 approval 文件，记录批准人、时间、动作、确认短语和 checklist。
15. approval 准备与状态查看：Tom 上生成 approval 草稿，窗口 status 直接显示人工批准缺口。
16. approval 显式批准命令：使用 `CONFIRM_APPROVAL_RECORD` 和 `APPROVED_BY` 记录批准，减少手工编辑 JSON 风险；该命令只写 approval 文件，不启用 live gate。
17. approval 一次性使用：live healthcheck 调用成功后自动 `consume` 批准记录，后续 check 必须重新 approve，防止同一批准重复演练。
18. 演练报告生成：成功演练后汇总 approval、dry-run 审计、live result 审计和影响快照，并要求 approval 已批准且已使用。
19. 远端 collector snapshot 只读拉取：Tom 通过 SSH 只读取远端已经生成好的 JSON，校验后写入本机 `runtime/collectors`，不执行远端 collector，不修改远端实例目录。
20. collector-only 远端 registry：server 配置 `collectorSnapshotPath` 后，远端实例可只填写 `id/name`，中央不需要远端 `openclawHome` 或 workspace 路径。
21. 远端 collector-only 节点 bootstrap：在远端 Oracle 上 dry-run 生成 collector-only compose、registry、snapshot 脚本和 cron 脚本，默认不启动容器、不修改实例。
22. Tom 远端 collector onboarding 接入包：在 Tom runtime 下生成可审查的接入包，包含远端 collector 配置、远端 bootstrap 脚本、Tom 拉取配置、Tom 注册配置、RUNBOOK 和默认内置的最小 Docker build context；`verify` 可离线校验接入包一致性、安全边界和 bootstrap plan；`preflight check` 只通过 SSH 执行只读远端前置检查；该步骤不写活跃 registry、不修改实例。
23. Tom 到远端 collector 节点同步与运行：`remote-collector-node-sync.sh plan` 不联网；`sync` 只把接入包复制到远端 collector deploy 目录；`bootstrap-plan/bootstrap-write` 只执行远端 collector-only bootstrap；`snapshot/install-cron` 只启动/使用 collector-only 容器生成 snapshot，并安装当前用户 crontab 中的 collector 受控块，不启动或重启 OpenClaw 实例容器、不修改实例目录。
24. Tom registry 安全注册：读取已拉取的远端 collector snapshot，先 `plan` 审查将新增的 server 和实例，确认后 `apply` 备份并原子更新 `config/instances.json`；该步骤只更新 control-center registry，不修改远端或本地 OpenClaw 实例。
25. 第二台 Oracle 接入中央视图：在远端生成 collector JSON，在 Tom 只读拉取后，通过注册脚本把对应 server 的 `collectorSnapshotPath` 写入 registry，再通过 `healthcheck.sh` 验收。
26. 跨服务器只读接入 rollout gate：读取 onboarding bundle、preflight 状态、pull 状态、snapshot 和 registry，输出 `needs_remote_preflight`、`needs_remote_collector_pull`、`needs_registry_register` 或 `ready_for_healthcheck`，不 SSH、不写 registry、不写远端文件。
27. 白名单真实执行灰度：默认关闭，只在单实例、单动作、人工确认下开启。
