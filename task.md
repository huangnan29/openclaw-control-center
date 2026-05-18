# 当前任务记录

## 当前目标

最终上线 OpenClaw 控制中心：当前只有一台 Oracle，因此先完成 Tom 这一台 Oracle 上现有 OpenClaw 实例的只读监控与受控管理上线；实例数量可继续通过 registry/collector 扩展。跨服务器只读 collector 保留为后续显式 `OPENCLAW_TOPOLOGY_MODE=cross-server` 扩展项，不再作为当前上线阻塞。

## 本轮任务

单 Oracle 上线收口：把 Tom 当前五个 OpenClaw 实例的只读监控、dry-run 管理动作、人工审批、审计和一次性 healthcheck live 演练串成安全上线主链路。当前重点是把“approval review ready 后人工批准并执行一次性演练”的本机总入口收束好，默认仍不允许真实执行、不允许修改实例、不允许打开 live gate。

## 本轮不做

- 不执行任何真实管理动作。
- 不修改任何 OpenClaw 实例目录。
- 不重启、不停止、不发布、不触发任何 OpenClaw 实例任务。
- 不让中央控制中心直接挂载远端实例目录。

## 当前下一步

Tom 单 Oracle 上线下一步：

- 每次判断最终上线距离时，先在本机运行总控状态入口：
  `ops/local/final-go-live-status.sh status`
- 需要同时验证 Tom 现有实例只读安全边界时，运行：
  `ops/local/final-go-live-status.sh check`
- 当前默认 `OPENCLAW_TOPOLOGY_MODE=local-only`，不要求第二台 Oracle host/key；如果未来要接第二台 Oracle，再显式运行：
  `OPENCLAW_TOPOLOGY_MODE=cross-server ops/local/final-go-live-status.sh check`
- 本机实例扩展已走显式安全脚本：
  `repo/ops/tom-readonly/register-local-instance.sh plan runtime/register-local-instance.json`
  确认后再运行：
  `CONFIRM_LOCAL_INSTANCE_REGISTER=I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_LOCAL_REGISTRY repo/ops/tom-readonly/register-local-instance.sh apply runtime/register-local-instance.json`
  然后只重建 control-center 容器、刷新 collector snapshot，并跑 `./healthcheck.sh`。
- 当前 managed action dry-run 证据已存在；local-only healthcheck 通过后，下一阶段统一走 runner 主链路：先自动准备证据包并停在人工 approval 前，人工批准后再显式运行一次性 live healthcheck 演练。
- 查看 live healthcheck 下一步 readiness：
  `repo/ops/tom-readonly/live-healthcheck-readiness.sh status`
  需要同时验证 Tom 现有实例只读健康时运行：
  `repo/ops/tom-readonly/live-healthcheck-readiness.sh check`
  readiness 脚本只读汇总总闸门、dry-run、证据包、approval 和 live window；它输出的下一步已统一指向 `live-healthcheck-rollout-runner.sh prepare/run-approved` 主链路，不生成证据包、不写 approval、不打开 live gate。
- 自动推进到人工批准前：
  `ops/local/final-go-live-runner.sh prepare`
  该本机总 runner 会先跑最终上线 `check`，确认 Tom 现有实例健康且下一步确实是 Tom runner prepare 后，才 SSH 到 Tom 执行准备动作并复核最终状态。到达人工批准边界后，它会只读运行 Tom approval review，并把 `approve-and-run` 单命令作为下一步；review 不 ready 时会在批准前阻断。
- Tom 侧自动推进到人工批准前：
  `repo/ops/tom-readonly/live-healthcheck-rollout-runner.sh prepare`
  该 runner 会检查 dry-run、准备 approval 模板、生成并校验证据包、刷新 readiness，然后停在人工批准前；不会批准 approval、不会打开 live gate。
- 人工批准命令：
  `CONFIRM_APPROVAL_RECORD=I_APPROVE_LIVE_HEALTHCHECK_RECORD APPROVED_BY=Anan repo/ops/tom-readonly/live-healthcheck-approval.sh approve runtime/live-healthcheck-approval.json`
- 人工审查后优先走本机包装器单命令入口，它会先只读运行 approval review，只有 review 是 `ready_for_human_approval` 时才记录 approval，然后执行一次性演练：
  `ops/local/final-go-live-approve-and-run-from-tom-token.sh status`
  `CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN=I_APPROVE_AND_RUN_FINAL_LIVE_HEALTHCHECK APPROVED_BY=Anan FINAL_GO_LIVE_OUTPUT=summary ops/local/final-go-live-approve-and-run-from-tom-token.sh approve-and-run`
- 如果不想手工导出 `LOCAL_API_TOKEN`，可用本机包装器从 Tom control-center 容器环境读取令牌到子进程，不打印、不落盘，然后委托既有 `approve-and-run`：
  `ops/local/final-go-live-approve-and-run-from-tom-token.sh status`
  `CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN=I_APPROVE_AND_RUN_FINAL_LIVE_HEALTHCHECK APPROVED_BY=Anan FINAL_GO_LIVE_OUTPUT=summary ops/local/final-go-live-approve-and-run-from-tom-token.sh approve-and-run`
- 人工 approval 已批准后，自动执行一次性演练：
  `CONFIRM_FINAL_GO_LIVE_RUNNER=I_UNDERSTAND_THIS_RUNS_APPROVED_FINAL_GO_LIVE LOCAL_API_TOKEN=<本地令牌> ops/local/final-go-live-runner.sh run-approved`
  `CONFIRM_LIVE_HEALTHCHECK_RUNNER=I_UNDERSTAND_THIS_RUNS_APPROVED_LIVE_HEALTHCHECK LOCAL_API_TOKEN=<本地令牌> repo/ops/tom-readonly/live-healthcheck-rollout-runner.sh run-approved`
  该模式会先确认 readiness 为 `approved_ready_for_live_window`，否则不会打开 live gate，并以非 0 退出码让 openclaw 调度侧知道本次被人工批准边界挡住。
- 演练后只读验收：
  `ops/local/final-go-live-runner.sh verify-completed`
  `repo/ops/tom-readonly/live-healthcheck-rollout-runner.sh verify-completed`
  该模式只读确认 readiness 为 `approval_consumed`、最新报告 `passed`、approval 已消费、impact 检查通过且未修改 OpenClaw 实例。
- Tom 当前部署没有 `/srv/openclaw-control-center-readonly/.env`，`LOCAL_API_TOKEN` 来自 `openclaw-control-center-readonly` 容器环境；本机执行 live 演练前用 `docker inspect ... | sed -n "s/^LOCAL_API_TOKEN=//p"` 通过 SSH 读入当前 shell，且不要打印真实 token。

## 本轮新增（最终 approval token 包装器）

- 已新增 `ops/local/final-go-live-approve-and-run-from-tom-token.sh`。
- 该包装器用于最终人工批准时减少手工读取 `LOCAL_API_TOKEN` 的出错概率。
- 已扩展 `status` 模式：只读检查 Tom 容器 token 长度和 approval review 状态，不要求确认短语，不打印 token，不执行 approval。
- 已把 `final-go-live-review.sh status`、`final-go-live-completion-audit.sh status`、`final-go-live-runner.sh prepare`、Tom `live-healthcheck-approval-review.sh status/check` 的下一步命令收敛到包装器：先运行 `ops/local/final-go-live-approve-and-run-from-tom-token.sh status`，再显式确认执行包装器 `approve-and-run`。
- 新的 review/audit nextCommands 不再要求人工手写 `LOCAL_API_TOKEN=<本地令牌>`。
- `final-go-live-runner.sh run-approved` 在发现 Tom 尚未批准时，也会把下一步规范化为包装器流程，而不是提示手工 `LOCAL_API_TOKEN`。
- Tom `live-healthcheck-approval-review.sh` 在 `ready_for_human_approval` 时已直接输出包装器 `status` 和 `approve-and-run`。
- 缺少 `CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN=I_APPROVE_AND_RUN_FINAL_LIVE_HEALTHCHECK` 或 `APPROVED_BY` 时，脚本在连接 Tom 前阻断。
- `approve-and-run` 确认齐全后，它只读 SSH 到 Tom，通过 `docker inspect openclaw-control-center-readonly` 从容器环境读取 `LOCAL_API_TOKEN`，不打印、不落盘，然后作为子进程环境传给 `ops/local/final-go-live-runner.sh approve-and-run`。
- 最终是否写 approval、打开一次性 live healthcheck 窗口、调用 live API，仍完全由既有 runner 的 review/readiness/approval 闸门决定。
- 已新增 `test/final-go-live-approve-and-run-from-tom-token.test.ts`，覆盖 status 只读 preflight、缺确认不连接 Tom、成功委托时不打印 token、token 为空时不委托 runner。
- 已更新 `test/final-go-live-review.test.ts` 与 `test/final-go-live-completion-audit.test.ts`，断言 review/audit 输出包装器命令且不再输出 `LOCAL_API_TOKEN=<本地令牌>`。
- 已更新 `test/final-go-live-runner.test.ts` 与 `test/live-healthcheck-approval-review.test.ts`，断言 prepare/approval review 等常见入口输出包装器命令。
- 真实 Tom `status` preflight 已返回 `preflight_ready_for_human_approval`，token length 为 28，review 为 `ready_for_human_approval_with_usage_alerts`，未委托 final runner。

## 本轮新增（heartbeat/token warning 明细）

- 已增强 `ops/tom-readonly/heartbeat-burn-alert-runner.sh status`：保留原有 `latest.suspiciousRows` 数量字段，同时新增 `latest.suspiciousInstances` 明细。
- 已增强 `ops/local/final-go-live-review.sh status`：当 heartbeat/token 告警存在实例明细时，warning 会展示实例与信号，例如 `main(periodic_small_growth)`。
- completion audit 会继承 review 的 warning 明细，避免只看到“若干可疑实例”而不知道具体是谁。
- 已通过只读 Tom 检查确认当前 warning 指向 `main(periodic_small_growth)`、`deepseek(periodic_small_growth)`、`spark(recent_spike)`；这些仍是 warning，不是最终上线硬阻塞。
- 本次没有清空 `HEARTBEAT.md`、没有修改 OpenClaw 实例目录、没有重启实例、没有调用模型。

## 本轮新增（approve-and-run 最终入口）

- 已扩展 `ops/local/final-go-live-runner.sh`，新增 `approve-and-run` 模式。
- 该模式必须设置 `CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN=I_APPROVE_AND_RUN_FINAL_LIVE_HEALTHCHECK`、`APPROVED_BY` 和 `LOCAL_API_TOKEN`，缺任一项都会在连接 Tom 前阻断。
- `approve-and-run` 会先 SSH 到 Tom 执行 `live-healthcheck-approval-review.sh check`，只有状态为 `ready_for_human_approval` 时才继续。
- approval review 未 ready、已经是已批准待执行、inbox 有 pending、证据包异常或 readiness 异常时，均不会写 approval、不会打开 live gate。
- review ready 后，该模式只写 `runtime/live-healthcheck-approval.json` 的 approval 记录，然后交给既有 `live-healthcheck-rollout-runner.sh run-approved` 再次校验 readiness 与本地令牌。
- 完成路径仍只允许一次 `healthcheck` live 演练，并保持 `writesOpenClawInstanceDirs=false`、`restartsOpenClawInstances=false`。
- 已新增测试覆盖缺确认不连接 Tom、approval review 未 ready 不批准、批准后才执行一次性 live healthcheck。
- 已验证 `bash -n ops/local/final-go-live-runner.sh`。
- 已验证 `npm test -- test/final-go-live-runner.test.ts`，10/10 通过。

## 本轮新增（演练后 verify-completed 验收）

- 已扩展 `ops/tom-readonly/live-healthcheck-rollout-runner.sh`，新增 `verify-completed` 模式。
- `verify-completed` 只读运行 readiness `check` 并读取 `runtime/live-healthcheck-reports/` 最新 JSON 报告。
- 验收通过条件包括 readiness 为 `approval_consumed`、最新报告 `status=passed`、`approval.consumed=true`、存在 live result 审计、`liveExecution=true`、`mutatesOpenClawInstance=false`、`impact.ok=true`。
- 已让 Tom `run-approved` 在 live window 成功后自动执行 `verify-completed`；验收失败时返回 `failed_post_live_verification`，不把演练误判为完成。
- 已扩展 `ops/local/final-go-live-runner.sh`，新增本机 `verify-completed` 代理入口；本机 `run-approved` 与 `approve-and-run` 成功后也会自动调用 Tom 验收。
- 已更新 approval review：`ready_for_human_approval` 下一步现在同时给出本机 `approve-and-run` 单命令入口和手动 approval 命令。
- 仍未执行 approval `approve`、未打开 live gate、未调用 managed action live API、未修改 OpenClaw 实例目录、未重启实例。

## 本轮新增（prepare 下一步收敛到 approve-and-run）

- 已增强 `ops/local/final-go-live-runner.sh prepare`：到达 `prepared_waiting_human_approval` 后，会只读执行 Tom `live-healthcheck-approval-review.sh check`。
- `prepare` 现在会优先返回 approval review 的下一步，因此 OpenClaw 调度侧可直接看到 token 包装器 `status` 与 `approve-and-run` 单命令。
- 如果 approval review 未到 `ready_for_human_approval`，`prepare` 返回 `blocked_approval_review`，不会批准 approval、不会打开 live gate、不会调用 managed action live API。
- 已补测试覆盖：`prepare` 返回 `approve-and-run` 下一步、重复 prepare 仍幂等、approval review 未 ready 时阻断且不批准。

后续跨服务器扩展预留步骤：

- 为第二台 Oracle 服务器准备本地 collector exporter，让该服务器自行生成 collector JSON。
- 先在本机只读发现候选 SSH host/key：
  `ops/local/discover-remote-oracle-credentials.sh scan ops/local/discover-remote-oracle-credentials.example.json`
- 如果 scan 找到候选 host/key，可以显式确认后做只读 SSH 探测：
  `CONFIRM_REMOTE_ORACLE_DISCOVERY=I_UNDERSTAND_THIS_ONLY_PROBES_SSH_READONLY ops/local/discover-remote-oracle-credentials.sh probe ops/local/discover-remote-oracle-credentials.example.json`
- 找到可达候选后，直接生成本机 push 配置：
  `REMOTE_ORACLE_HOST=<可达候选 host> REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> ops/local/discover-remote-oracle-credentials.sh render-push-config ops/local/discover-remote-oracle-credentials.example.json > runtime/push-remote-collector-credentials.json`
- 或显式确认后只写本机 push 配置文件：
  `CONFIRM_REMOTE_ORACLE_PUSH_CONFIG_WRITE=I_UNDERSTAND_THIS_ONLY_WRITES_LOCAL_PUSH_CONFIG REMOTE_ORACLE_HOST=<可达候选 host> REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> ops/local/discover-remote-oracle-credentials.sh write-push-config ops/local/discover-remote-oracle-credentials.example.json`
- 如果已明确知道第二台 Oracle host/key，优先用 intake 编排器先预览再接入 Tom runtime：
  `REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> ops/local/remote-oracle-intake.sh doctor`
  `REMOTE_ORACLE_HOST=<可达候选 host> REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> ops/local/remote-oracle-intake.sh doctor`
  `REMOTE_ORACLE_HOST=<可达候选 host> REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> ops/local/remote-oracle-intake.sh plan`
  `CONFIRM_REMOTE_ORACLE_INTAKE=I_UNDERSTAND_THIS_WRITES_LOCAL_PUSH_CONFIG_AND_TOM_RUNTIME_ONLY REMOTE_ORACLE_HOST=<可达候选 host> REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> ops/local/remote-oracle-intake.sh apply`
- 要在凭据接入后自动触发 Tom 端安全 rollout runner，使用：
  `CONFIRM_REMOTE_ORACLE_INTAKE=I_UNDERSTAND_THIS_WRITES_LOCAL_PUSH_CONFIG_AND_TOM_RUNTIME_ONLY CONFIRM_REMOTE_ORACLE_INTAKE_RUNNER=I_UNDERSTAND_THIS_PUSHES_CREDENTIALS_AND_RUNS_TOM_SAFE_ROLLOUT REMOTE_ORACLE_HOST=<可达候选 host> REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> ops/local/remote-oracle-intake.sh run`
- 在 Tom 先复制 `repo/ops/tom-readonly/remote-collector-onboarding.example.json` 到 `runtime/remote-collector-onboarding.json`，填入第二台 Oracle 的 SSH 信息和实例路径。
- 任何阶段不确定下一步时，先运行：
  `repo/ops/tom-readonly/remote-collector-rollout.sh status runtime/remote-onboarding/<serverId>`
- 如果已经准备好真实远端凭据、onboarding、远端 snapshot 等前置条件，优先让 Tom 自动推进安全阶段：
  `CONFIRM_REMOTE_COLLECTOR_ROLLOUT_RUNNER=I_UNDERSTAND_THIS_RUNS_SAFE_REMOTE_COLLECTOR_ROLLOUT_STEPS repo/ops/tom-readonly/remote-collector-rollout-runner.sh run runtime/remote-onboarding/<serverId>`
- 每次判断最终上线距离时，先看总闸门：
  `repo/ops/tom-readonly/go-live-gate.sh status runtime/remote-onboarding/<serverId>`
- 需要同时验证 Tom 现有实例只读安全边界时，运行：
  `repo/ops/tom-readonly/go-live-gate.sh check runtime/remote-onboarding/<serverId>`
- 如果 rollout gate 返回 `needs_remote_credentials`，必须先补齐真实远端 host/user/port 和 Tom 上可读的只读 SSH key，不能用样板 `10.0.0.12` 硬跑 preflight。
- 如果远端只读 SSH key 还在本机，推荐先复制 `ops/local/push-remote-collector-credentials.example.json` 到 `runtime/push-remote-collector-credentials.json`，填入真实 `remote.sourceSshKeyPath` 后运行：
  `ops/local/push-remote-collector-credentials.sh plan runtime/push-remote-collector-credentials.json`
- 确认后运行：
  `CONFIRM_PUSH_REMOTE_COLLECTOR_CREDENTIALS=I_UNDERSTAND_THIS_ONLY_PUSHES_REMOTE_COLLECTOR_CREDENTIALS_TO_TOM_RUNTIME ops/local/push-remote-collector-credentials.sh apply runtime/push-remote-collector-credentials.json`
- 推荐先复制 `repo/ops/tom-readonly/remote-collector-credentials.example.json` 到 `runtime/remote-collector-credentials.json`，填入真实 `sourceSshKeyPath` 后运行：
  `repo/ops/tom-readonly/remote-collector-credentials.sh plan runtime/remote-collector-credentials.json`
- 确认后运行：
  `CONFIRM_REMOTE_COLLECTOR_CREDENTIALS=I_UNDERSTAND_THIS_ONLY_WRITES_CONTROL_CENTER_REMOTE_CREDENTIALS repo/ops/tom-readonly/remote-collector-credentials.sh apply runtime/remote-collector-credentials.json`
- 如果远端已经有可用的 control-center 源码目录，可以设置 `collectorNode.buildContext`；否则保持默认 `collectorNode.bundleBuildContext=true`，让接入包携带最小构建上下文。
- 先执行 `repo/ops/tom-readonly/remote-collector-onboarding.sh plan runtime/remote-collector-onboarding.json`，确认只生成接入包计划、不写文件。
- 确认后执行：
  `CONFIRM_REMOTE_COLLECTOR_ONBOARDING=I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_ONBOARDING_BUNDLE repo/ops/tom-readonly/remote-collector-onboarding.sh write runtime/remote-collector-onboarding.json`
- 写入后先执行：
  `repo/ops/tom-readonly/remote-collector-onboarding.sh verify runtime/remote-onboarding/<serverId>`
- verify 通过后执行远端只读 preflight：
  `repo/ops/tom-readonly/remote-collector-preflight.sh plan runtime/remote-onboarding/<serverId>`
- 确认后执行：
  `CONFIRM_REMOTE_COLLECTOR_PREFLIGHT=I_UNDERSTAND_THIS_ONLY_READS_REMOTE_PREREQUISITES repo/ops/tom-readonly/remote-collector-preflight.sh check runtime/remote-onboarding/<serverId>`
- preflight 通过后执行 rollout gate，确认阶段进入 `needs_remote_collector_pull`：
  `repo/ops/tom-readonly/remote-collector-rollout.sh status runtime/remote-onboarding/<serverId>`
- 审查 `runtime/remote-onboarding/<serverId>/RUNBOOK.md`、`collector-node.json`、`remote-collector-pull.sources.json`、`register-remote-collector.json`、`build-context-manifest.json` 和 `safety.json`。
- 先用 Tom 侧同步器审查远端 collector 节点同步计划：
  `repo/ops/tom-readonly/remote-collector-node-sync.sh plan runtime/remote-onboarding/<serverId>`
- 确认后只把接入包复制到远端 collector deploy 目录：
  `CONFIRM_REMOTE_COLLECTOR_NODE_SYNC=I_UNDERSTAND_THIS_ONLY_COPIES_COLLECTOR_BUNDLE_TO_REMOTE repo/ops/tom-readonly/remote-collector-node-sync.sh sync runtime/remote-onboarding/<serverId>`
- 在远端 collector deploy 目录内先执行 bootstrap plan：
  `CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_PLAN=I_UNDERSTAND_THIS_ONLY_RUNS_REMOTE_BOOTSTRAP_PLAN repo/ops/tom-readonly/remote-collector-node-sync.sh bootstrap-plan runtime/remote-onboarding/<serverId>`
- 确认后只写远端 collector-only 部署文件：
  `CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_WRITE=I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_COLLECTOR_NODE_FILES repo/ops/tom-readonly/remote-collector-node-sync.sh bootstrap-write runtime/remote-onboarding/<serverId>`
- 生成远端 collector snapshot：
  `CONFIRM_REMOTE_COLLECTOR_NODE_SNAPSHOT=I_UNDERSTAND_THIS_RUNS_REMOTE_COLLECTOR_SNAPSHOT_ONLY repo/ops/tom-readonly/remote-collector-node-sync.sh snapshot runtime/remote-onboarding/<serverId>`
- 安装远端 collector cron：
  `CONFIRM_REMOTE_COLLECTOR_NODE_CRON=I_UNDERSTAND_THIS_ONLY_INSTALLS_REMOTE_COLLECTOR_CRON repo/ops/tom-readonly/remote-collector-node-sync.sh install-cron runtime/remote-onboarding/<serverId>`
- 使用接入包里的 `remote-collector-pull.sources.json`，只配置远端 snapshot 路径和本地 `runtime/collectors/<serverId>/snapshot.json`。
- 先执行 `repo/ops/tom-readonly/remote-collector-pull.sh plan runtime/remote-onboarding/<serverId>/remote-collector-pull.sources.json` 审查来源。
- 只有确认远端 snapshot 文件存在后，才执行：
  `CONFIRM_REMOTE_COLLECTOR_PULL=I_UNDERSTAND_THIS_ONLY_READS_REMOTE_COLLECTOR_SNAPSHOTS repo/ops/tom-readonly/remote-collector-pull.sh pull runtime/remote-onboarding/<serverId>/remote-collector-pull.sources.json`
- pull 成功后执行 rollout gate，确认阶段进入 `needs_registry_register`：
  `repo/ops/tom-readonly/remote-collector-rollout.sh status runtime/remote-onboarding/<serverId>`
- 拉取成功后，使用接入包里的 `register-remote-collector.json`，先执行：
  `repo/ops/tom-readonly/register-remote-collector.sh plan runtime/remote-onboarding/<serverId>/register-remote-collector.json`
- 确认 registry diff 后再执行：
  `CONFIRM_REMOTE_COLLECTOR_REGISTER=I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_REGISTRY repo/ops/tom-readonly/register-remote-collector.sh apply runtime/remote-onboarding/<serverId>/register-remote-collector.json`
- register 成功后执行 rollout gate，确认阶段进入 `ready_for_healthcheck`。
- 最后运行 `./healthcheck.sh` 验收新增 server、collector snapshot 新鲜度和页面只读状态。
- 远端 server 的实例配置可以只写 `id` 和 `name`；只要 server 配置了 `collectorSnapshotPath`，中央会生成内部 `/collector/<serverId>/<instanceId>/config` 占位路径。

受控管理动作下一步仍是人工批准后执行一次只读 healthcheck live 演练：

- 先检查 dry-run 证据：
  `repo/ops/tom-readonly/managed-action-dry-run-gate.sh status`
- 如果没有有效 dry-run 审计，显式确认并带本地令牌创建 dry-run 记录：
  `CONFIRM_MANAGED_ACTION_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CREATES_DRY_RUN_AUDIT_RECORD LOCAL_API_TOKEN=<本地令牌> repo/ops/tom-readonly/managed-action-dry-run-gate.sh run`
- 使用 `repo/ops/tom-readonly/live-healthcheck-window.sh run`。
- 必须显式提供 `CONFIRM_LIVE_HEALTHCHECK_WINDOW`、`CONFIRM_LIVE_HEALTHCHECK` 和 `LOCAL_API_TOKEN`。
- 演练窗口会临时启用 control-center live healthcheck 配置，动作仍限制为 `healthcheck`。
- 必须先生成并批准 `runtime/live-healthcheck-approval.json`，通过 `live-healthcheck-approval.sh check` 后才允许打开窗口。
- 批准前先生成并校验 `live-healthcheck-approval-packet.sh generate/check` 证据包，确认总闸门、dry-run、approval、live window、当前 commit 和影响快照都在预期状态；`live-healthcheck-approval.sh approve` 已强制先校验证据包才写 approval，`live-healthcheck-window.sh enable/run` 也会先校验证据包，再校验 approval 文件。
- 可用 `live-healthcheck-readiness.sh status/check` 汇总当前是否为 `waiting_human_approval` 或 `approved_ready_for_live_window`。
- 可用 `live-healthcheck-rollout-runner.sh prepare` 自动完成证据包准备并停在人工批准前。
- 人工批准后可用 `live-healthcheck-rollout-runner.sh run-approved` 自动执行一次性 healthcheck live 演练。
- 推荐批准方式：
  `CONFIRM_APPROVAL_RECORD=I_APPROVE_LIVE_HEALTHCHECK_RECORD APPROVED_BY=Anan repo/ops/tom-readonly/live-healthcheck-approval.sh approve runtime/live-healthcheck-approval.json`
- 当前 Tom 已生成 approval 草稿，状态为 `needs_manual_approval`。
- 当前 Tom 已具备 `approve` 命令，但尚未执行批准命令。
- 脚本退出前必须恢复只读状态，并重新通过 `healthcheck.sh`。
- 脚本会自动生成 before/after 实例影响快照并比较。
- live 调用成功后会自动将 approval 标记为 `consumed=true`，再次演练必须重新 approve。
- 脚本成功后会自动生成 live healthcheck 演练报告，汇总 approval、dry-run 审计、live result 审计和影响快照；报告要求 approval 已批准且已使用。
- 未获得人工批准前，不执行 `/api/managed-actions/live`。

## 最近完成

- 已新增 `ops/tom-readonly/live-healthcheck-approval-review.sh`，作为人工 approval 前的只读审查汇总入口。
- `live-healthcheck-approval-review.sh status` 只读取 readiness、approval packet、approval、dry-run inbox cron 和 inbox pending 状态，不运行 healthcheck。
- `live-healthcheck-approval-review.sh check` 只让 readiness 执行只读 healthcheck，用于确认 Tom 现有实例仍正常。
- approval review 输出 `ready_for_human_approval`、`approved_ready_for_live_window` 或 `blocked_preconditions`，并给出下一步 approval 或 run-approved 命令。
- approval review 不生成新证据包、不批准 approval、不打开 live gate、不调用 managed action live API、不修改 OpenClaw 实例目录、不重启实例。
- 已新增 `test/live-healthcheck-approval-review.test.ts`，覆盖等待人工批准、已批准可演练、inbox 有 pending 时阻塞三种路径。
- 已验证 `npm test -- test/live-healthcheck-approval-review.test.ts`，3/3 通过。
- 已验证管理动作 approval review、readiness、rollout runner、live gate、dry-run、inbox cron 和只读安全回归集，39/39 通过。
- 已验证 `npm run build`。
- 已推送提交 `026a92e21cfc86d4d5fe8b25e322b9df59f6ac5c` 并同步到 Tom。
- Tom `update.sh` 已完成，只读 healthcheck 通过：5 个实例快照正常，写接口继续被只读闸门拦截。
- 已执行 `ops/local/final-go-live-runner.sh prepare`，为 Tom 当前 commit 重新生成 approval packet，并停在人工批准前。
- Tom `live-healthcheck-approval-review.sh status` 返回 `ready_for_human_approval`，`readiness=waiting_human_approval`，`approvalPacket=ready`，`approval=needs_manual_approval`，`inboxCron=inbox_cron_installed`，`inboxPendingCount=0`。
- Tom `live-healthcheck-approval-review.sh check` 返回 `ready_for_human_approval`，且 `checkRunsHealthcheckOnly=true`；该模式只运行只读 healthcheck，不生成 packet、不写 approval、不打开 live gate。
- Tom 最新 approval packet `live-healthcheck-approval-packet-20260517T173439+0000.json` 已校验 `ready`，`issues=[]`。
- 已新增并部署 `ops/tom-readonly/install-managed-action-inbox-cron.sh`，作为 Tom 上自动消费 OpenClaw workspace inbox 的 dry-run cron 安装器。
- 本地已验证 `bash -n ops/tom-readonly/install-managed-action-inbox-cron.sh`。
- 本地已验证 `npm test -- test/managed-action-inbox-cron.test.ts test/managed-action-inbox-runner.test.ts test/managed-action-text-bridge.test.ts test/managed-action-command-runner.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-readiness.test.ts test/managed-action-live-gate.test.ts test/oss-readiness.test.ts test/readonly-multi-instance-safety.test.ts`，39/39 通过。
- 本地已验证 `npm run build`。
- 已推送提交 `3d49deda3e0c6626638a3e7499ce57ced12ba59d` 并同步到 Tom `/srv/openclaw-control-center-readonly/repo`。
- Tom `update.sh` 已完成，只读 healthcheck 通过：5 个实例快照正常，写接口继续被只读闸门拦截。
- 已修复 `install-managed-action-inbox-cron.sh` 生成的 crontab 命令，确保 `cd '/srv/openclaw-control-center-readonly' && CONFIRM_MANAGED_ACTION_INBOX_RUNNER=...` 后才执行 runner；新增测试断言防止回归。
- 已验证 `npm test -- test/managed-action-inbox-cron.test.ts test/managed-action-inbox-runner.test.ts test/managed-action-text-bridge.test.ts test/managed-action-command-runner.test.ts`，22/22 通过。
- 已验证管理动作和只读安全回归集，39/39 通过。
- 已验证 `npm run build`。
- 已推送提交 `b44ca4c50fe90e38fd62ec9e118f83d2c2a50326` 并同步到 Tom。
- Tom `update.sh` 已完成，只读 healthcheck 通过：5 个实例快照正常，写接口继续被只读闸门拦截。
- Tom 已刷新 dry-run inbox cron 受控块，当前状态为 `inbox_cron_installed` 且 `needsUpdate=false`。
- Tom crontab 中 `OPENCLAW_MANAGED_ACTION_INBOX_CRON` 受控块当前只执行 `managed-action-inbox-runner.sh run-pending`，不调用 live API、不修改实例目录、不重启实例。
- 已向 Tom workspace inbox 写入测试指令 `20260517T171415Z-cron-smoke.txt`，cron 自动消费成功：`pendingCountBefore=1`、`pendingCountAfter=0`、`processedCount=1`。
- 自动消费生成 dry-run 审计 `b8608cf9-aba0-4f8c-9293-f6816b8d673a`，目标为 `tom` 的 `zhihu-human-ops-writing` `skill_run` dry-run。
- 本次自动消费安全标记：`callsManagedActionsDryRunApi=true`，`callsManagedActionsLiveApi=false`，`writesOpenClawInstanceDirs=false`，`restartsOpenClawInstances=false`，`mutatesOpenClawInstance=false`，`opensLiveGate=false`。
- 已验证未批准状态下执行本机 `final-go-live-runner.sh run-approved` 会被 Tom readiness 硬阻断，返回 `blocked_not_approved`。
- 阻断原因明确为 `readiness 不是 approved_ready_for_live_window：waiting_human_approval`。
- 该阻断测试即使提供 runner 确认短语和测试令牌，也没有打开 live gate、没有调用 managed action live API、没有写 Tom runtime、没有修改 OpenClaw 实例目录、没有重启实例。
- 阻断测试后再次验证 Tom `healthcheck.sh` 通过，5 个实例健康，readiness 仍为 `waiting_human_approval`，approval packet 仍为 `ready`，approval 仍为 `needs_manual_approval`。
- 阻断测试后再次验证 dry-run inbox cron 仍为 `inbox_cron_installed` 且 `needsUpdate=false`；空 inbox 下 cron 只记录 `inbox_empty`，安全字段保持不调用 live API、不写实例目录、不重启实例。
- 已为 `ops/local/remote-oracle-intake.sh` 新增 `doctor` 模式。
- `remote-oracle-intake.sh doctor` 只读取本机 SSH config、host hint 和 key 文件元数据；如果显式提供 `REMOTE_ORACLE_HOST/REMOTE_ORACLE_KEY_PATH`，只离线渲染配置摘要，不写文件、不联网、不连接 Tom、不连接第二台 Oracle。
- `doctor` 会输出 `needs_remote_host`、`needs_remote_key`、`candidates_found` 或 `ready_for_apply`，并给出下一步 `plan/apply/run` 命令。
- 本机执行 `ops/local/remote-oracle-intake.sh doctor`，当前状态为 `needs_remote_host`；发现 3 个本机 key 候选，但没有发现第二台 Oracle host。
- 已验证 `npm test -- test/remote-oracle-intake.test.ts test/discover-remote-oracle-credentials.test.ts test/oss-readiness.test.ts`，21/21 通过。
- 已验证跨服务器只读、总闸门、dry-run、凭据接入和远端 collector 自动引导回归集，58/58 通过。
- 已验证 `npm run build`。
- 已新增 `ops/tom-readonly/remote-collector-node-sync.sh`，用于把 Tom 已生成并校验过的 onboarding 接入包同步到第二台 Oracle 的 collector deploy 目录。
- `remote-collector-node-sync.sh plan` 只读取 Tom 本地接入包，不联网、不写文件。
- `remote-collector-node-sync.sh sync` 必须设置 `CONFIRM_REMOTE_COLLECTOR_NODE_SYNC=I_UNDERSTAND_THIS_ONLY_COPIES_COLLECTOR_BUNDLE_TO_REMOTE`，只通过 SSH+tar 写远端 collector deploy 目录，不写 OpenClaw 实例目录。
- `bootstrap-plan/bootstrap-write` 分别需要显式确认；`bootstrap-write` 只执行远端接入包里的 `bootstrap-collector-node.sh write`，写 collector-only 部署文件，不启动容器、不安装 cron、不调用 live API。
- `snapshot/install-cron` 分别需要显式确认；`snapshot` 只启动/使用 collector-only 容器生成远端 snapshot，`install-cron` 只安装当前用户 crontab 中的 collector 受控块，二者都不修改 OpenClaw 实例目录、不调用 live API。
- 已让 `remote-collector-rollout.sh` 在 `needs_remote_collector_pull` 阶段输出 `remote-collector-node-sync.sh` 的 plan/sync/bootstrap/snapshot/cron 命令，减少后续手工复制和远端手工执行风险。
- 已让 `remote-collector-rollout-runner.sh` 在 `needs_remote_collector_pull` 阶段自动串联远端接入包同步、bootstrap plan/write、snapshot、cron 和 Tom 只读 pull；缺凭据、远端检查或 snapshot 失败时会停住。
- 已新增并扩展 `test/remote-collector-node-sync.test.ts`，覆盖 plan 不联网、sync 必须确认、bootstrap plan/write、snapshot/cron 仍保持 collector-only 边界。
- 已扩展 `test/remote-collector-rollout-runner.test.ts`，覆盖 runner 在 pull 前先准备远端 collector 节点并生成 snapshot。
- 已验证 `npm test -- test/remote-collector-node-sync.test.ts test/remote-collector-rollout-runner.test.ts test/remote-collector-rollout.test.ts test/go-live-gate.test.ts test/oss-readiness.test.ts`，20/20 通过。
- 已验证跨服务器只读、总闸门、dry-run、凭据接入和远端 collector 自动引导回归集，56/56 通过。
- 已验证 `bash -n ops/tom-readonly/remote-collector-node-sync.sh` 和 `bash -n ops/tom-readonly/remote-collector-rollout.sh`。
- 已验证 `npm test -- test/remote-collector-node-sync.test.ts test/oss-readiness.test.ts`，10/10 通过。
- 已验证跨服务器只读、总闸门、dry-run 和凭据接入回归集，54/54 通过。
- 已验证 `npm run build`。
- 已新增 `ops/local/remote-oracle-intake.sh`，作为本机侧第二台 Oracle 凭据接入编排器。
- `remote-oracle-intake.sh plan` 只渲染 push 配置摘要，不写文件、不联网、不连接 Tom、不连接第二台 Oracle。
- `remote-oracle-intake.sh apply` 必须设置 `CONFIRM_REMOTE_ORACLE_INTAKE=I_UNDERSTAND_THIS_WRITES_LOCAL_PUSH_CONFIG_AND_TOM_RUNTIME_ONLY`，只串联本机 push 配置写入和 Tom runtime 凭据推送。
- `remote-oracle-intake.sh apply` 不连接第二台 Oracle、不写 Tom registry、不修改任何 OpenClaw 实例目录、不调用 managed action live API。
- `remote-oracle-intake.sh run` 还必须设置 `CONFIRM_REMOTE_ORACLE_INTAKE_RUNNER=I_UNDERSTAND_THIS_PUSHES_CREDENTIALS_AND_RUNS_TOM_SAFE_ROLLOUT`，会在 `apply` 后触发 Tom 端 `remote-collector-rollout-runner.sh run`，继续推进已满足安全门禁的阶段。
- `remote-oracle-intake.sh run` 可能通过 Tom 对第二台 Oracle 做只读 preflight/pull，并可能更新 Tom control-center registry；它不会写远端实例目录、不会启动容器、不会调用 managed action live API。
- 已新增 `test/remote-oracle-intake.test.ts`，覆盖 plan 不写不推、apply 缺确认被拒、apply 只写本机配置并只推 Tom runtime、run 缺二次确认被拒、run 触发 Tom 安全 rollout。
- 已验证 `bash -n ops/local/remote-oracle-intake.sh`。
- 已验证 `npm test -- test/remote-oracle-intake.test.ts`，5/5 通过。
- 已验证 intake、rollout、发现、push 和 OSS 安全断言组合，24/24 通过。
- 已验证 intake、rollout、OSS 安全断言组合，16/16 通过。
- 已验证跨服务器只读上线相关回归集，51/51 通过。
- 已验证 `npm run build`。
- 已增强 `ops/local/discover-remote-oracle-credentials.sh`，新增 `write-push-config` 模式。
- `write-push-config` 必须设置 `CONFIRM_REMOTE_ORACLE_PUSH_CONFIG_WRITE=I_UNDERSTAND_THIS_ONLY_WRITES_LOCAL_PUSH_CONFIG`，只根据显式 `REMOTE_ORACLE_HOST` 和 `REMOTE_ORACLE_KEY_PATH` 写本机 `runtime/push-remote-collector-credentials.json`。
- `write-push-config` 不联网、不连接 Tom、不连接第二台 Oracle、不写 Tom runtime、不写 registry、不修改任何 OpenClaw 实例目录，也不输出私钥内容。
- `remote-collector-rollout.sh` 的 `needs_remote_credentials` 下一步提示已同步加入 `write-push-config`，避免总闸门继续引导手工复制样板。
- 已扩展 `test/discover-remote-oracle-credentials.test.ts`，覆盖 `write-push-config` 缺确认被拒、显式确认后只写本机 push 配置且不泄露 key 内容。
- 已验证 `bash -n ops/local/discover-remote-oracle-credentials.sh`。
- 已验证 `npm test -- test/discover-remote-oracle-credentials.test.ts test/push-remote-collector-credentials.test.ts test/oss-readiness.test.ts`，17/17 通过。
- 已验证 `bash -n ops/tom-readonly/remote-collector-rollout.sh`。
- 已验证 `npm test -- test/remote-collector-rollout.test.ts test/remote-collector-rollout-runner.test.ts test/discover-remote-oracle-credentials.test.ts test/oss-readiness.test.ts`，18/18 通过。
- 已验证跨服务器只读上线相关回归集，46/46 通过。
- 已验证 `npm run build`。
- 已新增 `ops/tom-readonly/managed-action-dry-run-gate.sh`，作为管理动作 dry-run 证据闸门。
- `managed-action-dry-run-gate.sh status` 只读取 readiness 与 dry-run audit，不写文件、不调用 live API。
- `managed-action-dry-run-gate.sh run` 必须设置 `CONFIRM_MANAGED_ACTION_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CREATES_DRY_RUN_AUDIT_RECORD` 且提供 `LOCAL_API_TOKEN`，只调用 `/api/managed-actions/dry-run` 创建 dry-run 审计记录。
- `go-live-gate.sh` 已纳入 `managedActionDryRunEvidence` 阶段；跨服务器只读和现有实例 healthcheck 通过后，如果缺少有效 dry-run 审计，会先阻塞在 `blocked_managed_action_dry_run`。
- 已新增 `test/managed-action-dry-run-gate.test.ts`，覆盖已有有效审计、run 缺确认被拒、run 只调用 dry-run 不调用 live。
- 已扩展 `test/go-live-gate.test.ts`，覆盖总闸门在缺少 dry-run 证据时先阻塞 `blocked_managed_action_dry_run`。
- 已验证 `bash -n ops/tom-readonly/managed-action-dry-run-gate.sh` 与 `bash -n ops/tom-readonly/go-live-gate.sh`。
- 已验证 `npm test -- test/managed-action-dry-run-gate.test.ts test/go-live-gate.test.ts test/oss-readiness.test.ts`，14/14 通过。
- 已验证跨服务器只读上线相关回归集，44/44 通过。
- 已验证 managed action 核心回归集，16/16 通过。
- 已验证 `npm run build`。
- 已新增 `ops/local/discover-remote-oracle-credentials.sh` 和 `discover-remote-oracle-credentials.example.json`，用于本机只读发现第二台 Oracle 候选 SSH host/key。
- `discover-remote-oracle-credentials.sh scan` 只读取本机 SSH config 和候选 key 文件元数据，不联网、不写文件、不输出私钥内容。
- `discover-remote-oracle-credentials.sh probe` 必须设置 `CONFIRM_REMOTE_ORACLE_DISCOVERY=I_UNDERSTAND_THIS_ONLY_PROBES_SSH_READONLY`，只执行 `id -un`、`uname -n`、`uname -s` 这类只读 SSH 探测，不写远端文件、不写 Tom runtime。
- `discover-remote-oracle-credentials.sh render-push-config` 只根据显式 `REMOTE_ORACLE_HOST` 和 `REMOTE_ORACLE_KEY_PATH` 输出本机 push 配置 JSON，不联网、不写文件。
- 已增强 `test/discover-remote-oracle-credentials.test.ts`，覆盖 scan 不泄露 key 内容、host hint 文件抽取、probe 必须确认、probe 使用只读 SSH 参数、render-push-config 不泄露 key 内容。
- 已验证 `bash -n ops/local/discover-remote-oracle-credentials.sh`。
- 已验证 `npm test -- test/discover-remote-oracle-credentials.test.ts test/push-remote-collector-credentials.test.ts test/oss-readiness.test.ts`，15/15 通过。
- 已验证 `npm test -- test/discover-remote-oracle-credentials.test.ts test/go-live-gate.test.ts test/remote-collector-rollout-runner.test.ts test/push-remote-collector-credentials.test.ts test/remote-collector-credentials.test.ts test/remote-collector-rollout.test.ts test/remote-collector-preflight.test.ts test/remote-collector-onboarding.test.ts test/remote-collector-pull.test.ts test/register-remote-collector.test.ts test/collector-node-bootstrap.test.ts test/oss-readiness.test.ts`，40/40 通过。
- 已验证 `npm run build`。
- 本机执行 `ops/local/discover-remote-oracle-credentials.sh scan ops/local/discover-remote-oracle-credentials.example.json`，当前发现 3 个候选 key，但没有发现 Tom 以外的候选 host，状态为 `needs_remote_host`。
- 已新增 `ops/tom-readonly/go-live-gate.sh`，作为最终上线总闸门。
- `go-live-gate.sh status` 只汇总跨服务器 rollout runner 状态、managed action dry-run 证据与 live healthcheck window readiness，不运行 healthcheck、不写文件、不调用 live API。
- `go-live-gate.sh check` 会额外运行 `./healthcheck.sh`，用于验证 Tom 现有实例仍正常、只读边界仍有效。
- 总闸门会输出 `blocked_existing_instances`、`blocked_cross_server_readonly`、`ready_for_existing_instance_healthcheck`、`blocked_managed_actions` 或 `ready_for_live_healthcheck`，并附带下一步命令。
- 已新增 `test/go-live-gate.test.ts`，覆盖缺远端凭据、只读监控通过后进入管理动作阻塞、现有实例 healthcheck 失败时优先阻塞。
- 已验证 `bash -n ops/tom-readonly/go-live-gate.sh`。
- 已验证 `npm test -- test/go-live-gate.test.ts test/remote-collector-rollout-runner.test.ts test/oss-readiness.test.ts`，13/13 通过。
- 已验证 `npm test -- test/go-live-gate.test.ts test/remote-collector-rollout-runner.test.ts test/push-remote-collector-credentials.test.ts test/remote-collector-credentials.test.ts test/remote-collector-rollout.test.ts test/remote-collector-preflight.test.ts test/remote-collector-onboarding.test.ts test/remote-collector-pull.test.ts test/register-remote-collector.test.ts test/collector-node-bootstrap.test.ts test/oss-readiness.test.ts`，35/35 通过。
- 已验证 `npm run build`。
- 已新增 `ops/tom-readonly/remote-collector-rollout-runner.sh`，按 rollout gate 当前阶段自动调用 onboarding refresh、只读 preflight、只读 pull、registry register 和 healthcheck。
- `remote-collector-rollout-runner.sh status/plan` 只读取 rollout gate；`step/run` 必须设置 `CONFIRM_REMOTE_COLLECTOR_ROLLOUT_RUNNER=I_UNDERSTAND_THIS_RUNS_SAFE_REMOTE_COLLECTOR_ROLLOUT_STEPS`。
- runner 缺少 Tom 本地 `runtime/remote-collector-onboarding.json` 或真实远端 SSH key 时会停在 `needs_remote_credentials`，不会硬跑 SSH。
- 已新增 `test/remote-collector-rollout-runner.test.ts`，覆盖 status 只读代理、step 必须显式确认、刷新 onboarding 后推进到 preflight。
- 已验证 `bash -n ops/tom-readonly/remote-collector-rollout-runner.sh`。
- 已验证 `npm test -- test/remote-collector-rollout-runner.test.ts test/remote-collector-rollout.test.ts test/oss-readiness.test.ts`，11/11 通过。
- 已验证 `npm test -- test/remote-collector-rollout-runner.test.ts test/push-remote-collector-credentials.test.ts test/remote-collector-credentials.test.ts test/remote-collector-rollout.test.ts test/remote-collector-preflight.test.ts test/remote-collector-onboarding.test.ts test/remote-collector-pull.test.ts test/register-remote-collector.test.ts test/collector-node-bootstrap.test.ts test/oss-readiness.test.ts`，32/32 通过。
- 已验证 `npm run build`。
- 已尝试 `npm test` 全量套件；协作大厅相关用例出现多处失败并长时间未退出，已中断。失败集中在 hall execution / handoff / runtime-backed discussion，与本轮新增的跨服务器脚本链路无直接交叉，后续需要单独处理大厅测试稳定性。
- 已新增 `ops/tom-readonly/remote-collector-rollout.sh`，作为跨服务器只读 collector 接入总控闸门。
- 已新增 `ops/tom-readonly/remote-collector-credentials.sh` 和 `remote-collector-credentials.example.json`，用于把 Tom 本地已有的远端只读 SSH key 安装到 control-center runtime，并生成 `runtime/remote-collector-onboarding.json`。
- `remote-collector-credentials.sh plan` 不写文件、不联网；`apply` 必须设置 `CONFIRM_REMOTE_COLLECTOR_CREDENTIALS=I_UNDERSTAND_THIS_ONLY_WRITES_CONTROL_CENTER_REMOTE_CREDENTIALS`，只写 Tom control-center runtime，不 SSH、不写 registry、不修改实例目录。
- 已新增 `ops/local/push-remote-collector-credentials.sh` 和 `push-remote-collector-credentials.example.json`，用于从本机把远端只读 SSH key 和 onboarding 配置推送到 Tom control-center runtime。
- `push-remote-collector-credentials.sh plan` 不写文件、不联网；`apply` 必须设置 `CONFIRM_PUSH_REMOTE_COLLECTOR_CREDENTIALS=I_UNDERSTAND_THIS_ONLY_PUSHES_REMOTE_COLLECTOR_CREDENTIALS_TO_TOM_RUNTIME`，只通过 SSH 写 Tom runtime，不连接第二台 Oracle、不写 registry、不修改实例目录。
- 已新增 `test/push-remote-collector-credentials.test.ts`，覆盖 plan 不 SSH、apply 必须确认、payload 不在 SSH 命令行泄露、拒绝写出 Tom runtime。
- 已新增 `test/remote-collector-credentials.test.ts`，覆盖 plan 不写 runtime、apply 必须确认、key 权限 600、生成 onboarding config、默认拒绝覆盖和拒绝写出 runtime。
- `remote-collector-rollout.sh status/plan` 只读取 Tom 本地 onboarding bundle、preflight 状态、pull 状态、snapshot 和 registry，不 SSH、不写 registry、不写远端文件、不启动容器、不调用 live API。
- 已让 rollout gate 在 SSH key 缺失、source 未启用、host/user 缺失或 known_hosts 路径异常时停在 `needs_remote_credentials`，避免直接运行会失败的 SSH preflight。
- rollout gate 会输出 `needs_remote_credentials`、`needs_remote_preflight`、`needs_remote_collector_pull`、`needs_registry_register` 或 `ready_for_healthcheck`，并给出下一步命令。
- 已让 `remote-collector-preflight.sh check` 把结果写入 Tom 本地 `runtime/remote-preflight-state/<serverId>.json`，同时新增 `status` 模式用于只读查看。
- 已新增 `test/remote-collector-rollout.test.ts`，覆盖从缺 preflight 到 ready for healthcheck 的阶段推进。
- 已更新 `test/remote-collector-preflight.test.ts`，覆盖 preflight 状态文件与只读 status。
- 已验证 `bash -n ops/tom-readonly/remote-collector-preflight.sh` 和 `bash -n ops/tom-readonly/remote-collector-rollout.sh`。
- 已验证 `npm test -- test/remote-collector-preflight.test.ts test/remote-collector-rollout.test.ts test/remote-collector-onboarding.test.ts test/remote-collector-pull.test.ts test/register-remote-collector.test.ts test/oss-readiness.test.ts`，20/20 通过。
- 已验证 `bash -n ops/tom-readonly/remote-collector-credentials.sh`。
- 已验证 `npm test -- test/remote-collector-credentials.test.ts test/remote-collector-rollout.test.ts test/remote-collector-preflight.test.ts test/remote-collector-onboarding.test.ts test/remote-collector-pull.test.ts test/register-remote-collector.test.ts test/oss-readiness.test.ts`，24/24 通过。
- 已验证 `bash -n ops/local/push-remote-collector-credentials.sh`。
- 已验证 `npm test -- test/push-remote-collector-credentials.test.ts`，3/3 通过。
- 已验证 `npm test -- test/push-remote-collector-credentials.test.ts test/remote-collector-credentials.test.ts test/remote-collector-rollout.test.ts test/remote-collector-preflight.test.ts test/remote-collector-onboarding.test.ts test/remote-collector-pull.test.ts test/register-remote-collector.test.ts test/oss-readiness.test.ts`，27/27 通过。
- 已验证 `npm run build`。
- 已新增长期推进计划：`implementation_plan.md`。
- 已新增 `ops/tom-readonly/remote-collector-onboarding.sh`，用于在 Tom 生成第二台 Oracle 的只读 collector 接入包。
- 已新增 `ops/tom-readonly/remote-collector-onboarding.example.json` 样板。
- `remote-collector-onboarding.sh plan` 只校验配置并输出将生成的文件，不写文件、不 SSH。
- `remote-collector-onboarding.sh write` 必须设置 `CONFIRM_REMOTE_COLLECTOR_ONBOARDING=I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_ONBOARDING_BUNDLE`，只写 `runtime/remote-onboarding/<serverId>/` 下的接入包。
- 接入包包含 `collector-node.json`、`bootstrap-collector-node.sh`、`remote-collector-pull.sources.json`、`register-remote-collector.json`、`RUNBOOK.md` 和 `safety.json`。
- 已新增 `test/remote-collector-onboarding.test.ts`，覆盖 plan 不写文件、write 必须确认、只写 onboarding 目录、拒绝越界 outputDir、生成接入包可跑远端 bootstrap plan。
- 已验证 `bash -n ops/tom-readonly/remote-collector-onboarding.sh`。
- 已验证 `npm test -- test/remote-collector-onboarding.test.ts test/oss-readiness.test.ts`，10/10 通过。
- 已验证 `ops/tom-readonly/remote-collector-onboarding.sh plan ops/tom-readonly/remote-collector-onboarding.example.json`，输出 `writesActiveRegistry=false`、`connectsSsh=false`、`mutatesOpenClawInstance=false`、`callsLiveApi=false`。
- 已验证 `npm test -- test/remote-collector-onboarding.test.ts test/register-remote-collector.test.ts test/remote-collector-pull.test.ts test/collector-node-bootstrap.test.ts test/oss-readiness.test.ts`，16/16 通过。
- 已验证 `npm test -- test/multi-instance-readonly.test.ts test/readonly-multi-instance-safety.test.ts test/ui-render-smoke.test.ts`，39/39 通过。
- 已验证 `npm run build`。
- 已提交并推送 `43a6abc ops: bundle remote collector onboarding`。
- 已部署到 Tom，并验证运行提交 `43a6abc`。
- 已在 Tom 验证 `remote-collector-onboarding.sh plan` 返回 `writesActiveRegistry=false`、`connectsSsh=false`、`mutatesOpenClawInstance=false`、`callsLiveApi=false`，未执行 write，未生成真实接入包。
- 已验证 Tom `healthcheck.sh` 通过，现有 5 个实例仍只读；live window status 仍为 `needs_manual_approval`、`READONLY_MODE=true`、`readiness.status=blocked`，未调用 live API。
- 已让 `remote-collector-onboarding.sh` 在未配置 `collectorNode.buildContext` 时默认生成 `build-context/` 和 `build-context-manifest.json`，并把生成的 `collector-node.json` 指向远端 `/srv/openclaw-collector-node/build-context`。
- build context 只包含构建 collector image 所需的最小文件：`Dockerfile`、`.dockerignore`、`package.json`、`package-lock.json`、`tsconfig.json`、`.env.example`、`README*`、`HALL.md`、`src/`、`scripts/` 和 `docs/`。
- 已更新 onboarding RUNBOOK，复制接入包时会带上 `build-context/`，远端执行前会放入 collector deploy 目录。
- 已新增测试覆盖无显式 `buildContext` 时自动打包 build context、生成 manifest、更新 collector-node `buildContext` 和 safety 记录。
- 已验证 `ops/tom-readonly/remote-collector-onboarding.sh plan ops/tom-readonly/remote-collector-onboarding.example.json` 返回 `warnings=[]`、`bundlesBuildContext=true`、`remoteBuildContext=/srv/openclaw-collector-node/build-context`、`buildContextFiles=88`。
- 已验证 `npm test -- test/remote-collector-onboarding.test.ts test/register-remote-collector.test.ts test/remote-collector-pull.test.ts test/collector-node-bootstrap.test.ts test/oss-readiness.test.ts`，17/17 通过。
- 已验证 `npm test -- test/multi-instance-readonly.test.ts test/readonly-multi-instance-safety.test.ts test/ui-render-smoke.test.ts`，39/39 通过。
- 已验证 `npm run build`。
- 已提交并推送 `1e9adcb ops: bundle remote collector build context`。
- 已部署到 Tom，并验证运行提交 `1e9adcb`。
- 已在 Tom 验证 onboarding 样板 `plan` 返回 `warnings=[]`、`bundlesBuildContext=true`、`remoteBuildContext=/srv/openclaw-collector-node/build-context`、`buildContextFiles=88`，未执行 write，未生成真实接入包。
- 已验证 Tom `healthcheck.sh` 通过，现有 5 个实例仍只读；live window status 仍为 `needs_manual_approval`、`READONLY_MODE=true`、`readiness.status=blocked`，未调用 live API。
- 已新增 `remote-collector-onboarding.sh verify <bundle-dir>`，只读取已生成接入包并离线校验，不 SSH、不写文件、不改 registry。
- `verify` 会校验必需文件、serverId 一致性、safety 布尔边界、pull/register 路径、build-context manifest，并调用接入包内 `bootstrap-collector-node.sh plan` 确认不启动容器、不修改实例。
- 已新增测试覆盖 `verify` 成功路径和篡改 `safety.connectsSsh=true` 后失败。
- 已提交并推送 `f1b4960 ops: verify remote collector onboarding bundles`。
- 已部署到 Tom，并验证运行提交 `f1b4960`。
- 已在 Tom 用样板配置执行 onboarding `write`，只写入 `runtime/remote-onboarding/remote-oracle/`，未 SSH、未写 active registry、未修改任何 OpenClaw 实例。
- 已在 Tom 对样板接入包执行 `verify`，返回 `status=verified`、`bundlesBuildContext=true`、`buildContextFiles=88`、`bootstrapStartsContainers=false`、`writesActiveRegistry=false`、`connectsSsh=false`、`mutatesOpenClawInstance=false`、`callsLiveApi=false`。
- 已验证 Tom `healthcheck.sh` 通过，现有 5 个实例仍只读；live window status 仍为 `needs_manual_approval`、`READONLY_MODE=true`、`readiness.status=blocked`，未调用 live API。
- 已新增 `ops/tom-readonly/remote-collector-preflight.sh`，用于在真实复制到远端前做 SSH 只读预检。
- `remote-collector-preflight.sh plan` 只读取 onboarding bundle，不联网、不写文件。
- `remote-collector-preflight.sh check` 必须设置 `CONFIRM_REMOTE_COLLECTOR_PREFLIGHT=I_UNDERSTAND_THIS_ONLY_READS_REMOTE_PREREQUISITES`，只通过 SSH 检查远端 docker、docker compose、crontab、deploy 目录或父目录权限、实例目录可读性和 gateway 端口。
- preflight 不写远端文件、不启动容器、不修改任何 OpenClaw 实例目录、不调用 managed action live API。
- 已新增 `test/remote-collector-preflight.test.ts`，覆盖 plan 不 SSH、check 必须确认、只读检查成功、必需检查失败时 blocked。
- 已验证 `bash -n ops/tom-readonly/remote-collector-preflight.sh`。
- 已验证 `npm test -- test/remote-collector-preflight.test.ts`，3/3 通过。
- 已验证 `npm test -- test/remote-collector-preflight.test.ts test/remote-collector-onboarding.test.ts test/register-remote-collector.test.ts test/remote-collector-pull.test.ts test/collector-node-bootstrap.test.ts test/oss-readiness.test.ts`，21/21 通过。
- 已验证 `npm test -- test/multi-instance-readonly.test.ts test/readonly-multi-instance-safety.test.ts test/ui-render-smoke.test.ts`，39/39 通过。
- 已验证 `npm run build`。
- 已提交并推送 `2d2dfa5 ops: preflight remote collector prerequisites`。
- 已部署到 Tom，并验证运行提交 `2d2dfa5`。
- 已在 Tom 对样板接入包执行 `remote-collector-preflight.sh plan`，返回 `connectsSsh=false`、`writesRemoteFiles=false`、`startsContainers=false`、`mutatesOpenClawInstance=false`、`callsLiveApi=false`。
- 已在 Tom 再次执行 onboarding `verify`，返回 `status=verified`、`bootstrapStartsContainers=false`、`writesActiveRegistry=false`、`connectsSsh=false`。
- 已验证 Tom `healthcheck.sh` 通过，现有 5 个实例仍只读；live window status 仍为 `needs_manual_approval`、`READONLY_MODE=true`、`readiness.status=blocked`，未调用 live API。
- 已新增 `ops/tom-readonly/register-remote-collector.sh`，用于把已拉取的远端 collector snapshot 注册到 Tom `config/instances.json`。
- 已新增 `ops/tom-readonly/register-remote-collector.example.json` 样板。
- `register-remote-collector.sh plan` 只读取配置、Tom registry 和本机 snapshot，不写文件。
- `register-remote-collector.sh apply` 必须设置 `CONFIRM_REMOTE_COLLECTOR_REGISTER=I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_REGISTRY`，会先备份原 registry，再原子写入新 registry。
- 注册脚本会校验 snapshot `serverId`、`generatedAt`、实例列表、重复 server/instance id，并保证新增实例是 collector-only。
- 已新增 `test/register-remote-collector.test.ts`，覆盖 plan 不写文件、apply 必须确认、自动备份、collector-only server 写入和 serverId 不匹配失败。
- 已验证 `bash -n ops/tom-readonly/register-remote-collector.sh`。
- 已验证 `npm test -- test/register-remote-collector.test.ts test/remote-collector-pull.test.ts test/instance-config.test.ts test/oss-readiness.test.ts`，23/23 通过。
- 已验证 `npm test -- test/register-remote-collector.test.ts test/remote-collector-pull.test.ts test/collector-node-bootstrap.test.ts test/collector-exporter.test.ts test/multi-instance-readonly.test.ts test/readonly-multi-instance-safety.test.ts`，16/16 通过。
- 已验证 `npm run build`。
- 已提交并推送 `d6a332b ops: register remote collector snapshots`。
- 已部署到 Tom，并验证运行提交 `d6a332b`。
- 已在 Tom 临时目录验证 `register-remote-collector.sh plan` 返回 `status=planned`、`mutatesOpenClawInstance=false`、`callsLiveApi=false`，未对真实 registry 执行 apply。
- 已验证 Tom `healthcheck.sh` 通过，现有 5 个实例仍只读；live window status 仍为 `needs_manual_approval`、`READONLY_MODE=true`、`readiness.status=blocked`，未调用 live API。
- 已新增 `ops/collector-node/bootstrap-collector-node.sh`，用于远端 Oracle collector-only 节点引导。
- 已新增 `ops/collector-node/collector-node.example.json` 样板。
- `bootstrap-collector-node.sh plan` 只校验配置并输出将生成的文件，不写入、不启动容器。
- `bootstrap-collector-node.sh write` 必须设置 `CONFIRM_COLLECTOR_NODE_WRITE=I_UNDERSTAND_THIS_ONLY_WRITES_COLLECTOR_NODE_FILES`，只写 `docker-compose.collector.yml`、`config/instances.json`、`collector-snapshot.sh` 和 `install-collector-cron.sh`。
- 生成的 collector-only compose 不暴露端口、不挂载 `/var/run/docker.sock`、不启用 privileged，实例目录全部 `:ro`。
- 已新增 `test/collector-node-bootstrap.test.ts`，覆盖 plan 不写文件、write 必须确认、生成文件只读安全边界。
- 已验证 `bash -n ops/collector-node/bootstrap-collector-node.sh`。
- 已验证 `ops/collector-node/bootstrap-collector-node.sh plan ops/collector-node/collector-node.example.json`。
- 已验证 `npm test -- test/collector-node-bootstrap.test.ts test/remote-collector-pull.test.ts test/oss-readiness.test.ts`，11/11 通过。
- 已验证 `npm test -- test/collector-node-bootstrap.test.ts test/remote-collector-pull.test.ts test/collector-exporter.test.ts test/instance-config.test.ts test/multi-instance-readonly.test.ts test/readonly-multi-instance-safety.test.ts`，26/26 通过。
- 已验证 `npm run build`。
- 已提交并推送 `53c9bef ops: scaffold collector-only remote nodes`。
- 已部署到 Tom，并验证运行提交 `53c9bef`。
- 已验证 Tom 上 bootstrap `plan` 返回 `startsContainers=false`、`mutatesOpenClawInstance=false`，没有执行 write、没有启动 collector-only 容器。
- 已验证 Tom `healthcheck.sh` 通过，现有 5 个实例仍只读；live window status 仍为 `needs_manual_approval`、`READONLY_MODE=true`、`readiness.status=blocked`，未调用 live API。
- 已让 `parseOpenClawInstanceConfigText` 支持 collector-only 远端实例：server 配置 `collectorSnapshotPath` 后，实例可以省略 `openclawHome/workspaceRoot`。
- 已为 collector-only 实例生成内部占位路径 `/collector/<serverId>/<instanceId>/config`，中央仍只从 collector snapshot 读取数据。
- 已更新 `docs/MULTI_INSTANCE_READONLY.md`，远端 collector 示例不再要求填写远端目录路径。
- 已验证 `npm test -- test/instance-config.test.ts test/multi-instance-readonly.test.ts test/remote-collector-pull.test.ts test/oss-readiness.test.ts`，25/25 通过。
- 已验证 `npm run build`。
- 已提交并推送 `fcc996f feat: allow collector-only remote instances`。
- 已部署到 Tom，并验证运行提交 `fcc996f`。
- 已在 Tom 容器内验证 collector-only registry 解析结果为 `status=ok`，内部路径为 `/collector/remote-oracle/remote-main/config`。
- 已验证 Tom `healthcheck.sh` 通过，现有 5 个实例仍只读；live window status 仍为 `needs_manual_approval`、`READONLY_MODE=true`、`readiness.status=blocked`，未调用 live API。
- 已新增跨服务器只读拉取脚本 `ops/tom-readonly/remote-collector-pull.sh`。
- 已新增拉取配置样板 `ops/tom-readonly/remote-collector-pull.sources.example.json`，默认 `enabled=false`。
- `remote-collector-pull.sh plan` 只校验配置和输出计划，不联网。
- `remote-collector-pull.sh pull` 必须设置 `CONFIRM_REMOTE_COLLECTOR_PULL=I_UNDERSTAND_THIS_ONLY_READS_REMOTE_COLLECTOR_SNAPSHOTS`，只通过 SSH `cat` 读取远端 collector JSON。
- 已让拉取脚本校验 `schemaVersion=1`、`serverId` 匹配、`generatedAt` 可解析、`instances` 非空，并限制本地写入路径必须位于 `runtime/collectors/`。
- 已让拉取脚本写入 `runtime/collector-pull-state/<serverId>.json`，方便审计最近一次拉取状态。
- 已新增 `test/remote-collector-pull.test.ts`，覆盖计划、确认短语、假 SSH 拉取、原子写入、状态记录和 serverId 不匹配失败。
- 已验证 `bash -n ops/tom-readonly/remote-collector-pull.sh`。
- 已验证 `ops/tom-readonly/remote-collector-pull.sh plan ops/tom-readonly/remote-collector-pull.sources.example.json`。
- 已验证 `npm test -- test/remote-collector-pull.test.ts test/collector-exporter.test.ts test/oss-readiness.test.ts`。
- 已验证 `npm test -- test/multi-instance-readonly.test.ts test/instance-config.test.ts test/ui-render-smoke.test.ts test/readonly-multi-instance-safety.test.ts test/remote-collector-pull.test.ts`，共 52/52 通过。
- 已验证 `npm run build`。
- 已提交并推送 `fcdd104 ops: add readonly remote collector pull`。
- 已部署到 Tom，并验证运行提交 `fcdd104`。
- 已验证 Tom `remote-collector-pull.sh plan` 对样板配置返回 `status=planned`，样板源 `enabled=false`，没有执行远端拉取。
- 已验证 Tom `healthcheck.sh` 通过，collector 快照正常，仍只读；Tom live window status 仍为 `needs_manual_approval`、`READONLY_MODE=true`、`readiness.status=blocked`，未调用 live API。
- 已新增 `live-healthcheck-approval.sh consume`，让批准记录在 live healthcheck 调用成功后变为一次性已使用状态，后续 `check` 会要求重新 approve。
- 已让 `live-healthcheck-window.sh run` 在 smoke 成功后自动调用 `consume`，再恢复只读并生成影响快照和报告。
- 已让演练报告要求 `approval.consumed === true`，确保报告证明批准记录不会被复用。
- 已验证 approval 本地临时目录生命周期：未批准时 `check` 失败，approve 后 `check` 通过，consume 后 `status=consumed` 且 `check` 再次失败。
- 已验证 `bash -n ops/tom-readonly/live-healthcheck-approval.sh`、`live-healthcheck-window.sh`、`live-healthcheck-report.sh`。
- 已验证 `npm test -- test/oss-readiness.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-gate.test.ts test/managed-action-live-audit.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `6644cfb ops: consume live healthcheck approvals after use`。
- 已部署到 Tom，并验证运行提交 `6644cfb`。
- 已在 Tom 临时目录验证 approval 生命周期，未改真实 runtime approval。
- 已验证 Tom 真实 approval 仍为 `needs_manual_approval`、`consumed=false`，`READONLY_MODE=true`，live gate/executor 未启用，`readiness.status=blocked`，未调用 live API。
- 已新增 `live-healthcheck-approval.sh approve`，要求 `CONFIRM_APPROVAL_RECORD=I_APPROVE_LIVE_HEALTHCHECK_RECORD` 和 `APPROVED_BY=<批准人>`，只写 approval 文件，不启用 live gate。
- 已验证 approve 辅助命令本地临时目录流程：缺少确认短语会失败，确认短语和批准人齐全后写入 `approved=true` 并通过 `status/check`。
- 已验证 `bash -n ops/tom-readonly/live-healthcheck-approval.sh`。
- 已验证 `npm test -- test/oss-readiness.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-gate.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `4467e9a ops: add explicit approval record command`。
- 已部署到 Tom，并验证运行提交 `4467e9a`。
- 已验证 Tom `healthcheck.sh` 通过，collector 快照正常，5 个实例仍在只读监控范围内。
- 已验证 Tom approval 仍为 `needs_manual_approval`，`READONLY_MODE=true`，`MANAGED_ACTIONS_LIVE_ENABLED` 和 `MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED` 均未启用。
- 已验证 Tom `live-healthcheck-window.sh status` 仍为 `readiness.status=blocked`，未调用 live API。
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
- 已新增 `MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED=false` 默认配置。
- 已让 live gate 在 `executorWired=true` 且所有安全条件通过时返回 `ready`；默认仍返回 `ready_not_implemented`。
- 已将生产执行器挂载开关接入 `/api/managed-actions/live`。
- 已验证显式打开开关、live gate、dry-run 引用、rollout 和确认短语全部通过时，只读 `healthcheck` 返回 `executed_readonly_healthcheck`。
- 已验证只读 `healthcheck` 响应声明 `safety.mutatesOpenClawInstance=false`。
- 已让 readiness 根据挂载开关显示 `executor.productionWired`。
- 已更新 Tom `healthcheck.sh`，如果 `MANAGED_ACTIONS_LIVE_ENABLED=true` 或 `MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED=true` 会直接失败。
- 已验证 `npm test -- test/managed-action-live-gate.test.ts test/managed-actions-dry-run.test.ts test/managed-action-executor.test.ts test/managed-action-live-audit.test.ts test/managed-action-live-readiness.test.ts test/phase9-routes-commands.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts test/oss-readiness.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `5ee4b43 feat: gate live managed action executor wiring`。
- 已部署到 Tom，并验证运行提交 `5ee4b43`。
- 已验证 Tom `healthcheck.sh` 通过，新增 live 开关安全检查通过。
- 已验证 Tom 容器没有启用 `MANAGED_ACTIONS_LIVE_ENABLED=true` 或 `MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED=true`。
- 已验证 Tom readiness 返回 `status=blocked`、`liveExecutionAvailable=false`、`liveExecutionAttempted=false`、`executor.productionWired=false`。
- 已验证 Tom 总览页仍包含 `真实执行上线条件`，但不包含 `/api/managed-actions/live` 前端调用，也不包含真实执行确认短语。
- 已新增只读 healthcheck live rollout 样板：`ops/tom-readonly/managed-action-healthcheck-rollout.example.json`。
- 已新增人工 smoke 脚本：`ops/tom-readonly/live-healthcheck-smoke.sh`。
- 已让 smoke 脚本必须设置 `CONFIRM_LIVE_HEALTHCHECK=I_UNDERSTAND_THIS_CALLS_LIVE_API` 和 `LOCAL_API_TOKEN` 后才会继续。
- 已让 smoke 脚本先检查 readiness，未允许 live execution 时不会调用 `/api/managed-actions/live`。
- 已验证 `npm test -- test/oss-readiness.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-gate.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `cbc04f9 ops: add live healthcheck smoke plan`。
- 已部署到 Tom，并验证运行提交 `cbc04f9`。
- 已验证 Tom `healthcheck.sh` 通过。
- 已验证 Tom 存在可执行 `live-healthcheck-smoke.sh` 和 rollout 样板。
- 已验证 Tom `bash -n repo/ops/tom-readonly/live-healthcheck-smoke.sh` 通过。
- 已验证 Tom readiness 仍返回 `liveExecutionAvailable=false`、`executor.productionWired=false`。
- 已新增只读 preflight 脚本：`ops/tom-readonly/live-healthcheck-preflight.sh`，用于检查 rollout 样板、容器 live 开关和 readiness。
- 已发现 Tom preflight 首次失败原因：rollout 校验运行在容器内，未接收到 `INSTANCE_ID` 和 `OPERATOR`。
- 已修复 preflight 环境变量传递位置，只在 `check_rollout_file()` 的容器校验中传入 `INSTANCE_ID` 与 `OPERATOR`。
- 已增强 `test/oss-readiness.test.ts`，精确断言 `check_rollout_file()` 段包含 `-e INSTANCE_ID` 与 `-e OPERATOR`。
- 已验证 `bash -n ops/tom-readonly/live-healthcheck-preflight.sh`。
- 已验证 `npm test -- test/oss-readiness.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-gate.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `28ee982 fix: pass rollout inputs to live preflight`。
- 已部署到 Tom，并验证运行提交 `28ee982`。
- 已验证 Tom `healthcheck.sh` 通过，5 个 OpenClaw gateway 健康端口、容器只读边界和 collector 快照检查通过。
- 已验证 Tom preflight 通过，rollout 样板匹配 `action=healthcheck`、`instanceId=tom`、`operator=Anan`。
- 已验证 Tom 容器仍为 `READONLY_MODE=true`，`MANAGED_ACTIONS_LIVE_ENABLED` 与 `MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED` 均未启用。
- 已验证 Tom readiness 仍为 `status=blocked`、`liveExecutionAvailable=false`、`executor.productionWired=false`。
- 已验证 preflight 完成且未调用 live API。
- 已新增一次性演练窗口脚本：`ops/tom-readonly/live-healthcheck-window.sh`。
- 已让窗口脚本支持 `status`、`enable`、`disable`、`run` 四种模式。
- 已让 `run` 模式设置退出 trap，失败或结束后自动执行 `disable` 恢复只读状态。
- 已让窗口脚本生成临时 compose override，仅启用 `READONLY_MODE=false`、`MANAGED_ACTIONS_LIVE_ENABLED=true`、`MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED=true`、`MANAGED_ACTIONS_LIVE_ALLOWED_ACTIONS=healthcheck` 和 rollout 文件路径。
- 已让窗口脚本的 `enable/run` 必须确认 `CONFIRM_LIVE_HEALTHCHECK_WINDOW=I_UNDERSTAND_THIS_TEMPORARILY_ENABLES_LIVE_GATE`。
- 已让 `run` 模式继续要求 `CONFIRM_LIVE_HEALTHCHECK=I_UNDERSTAND_THIS_CALLS_LIVE_API` 和 `LOCAL_API_TOKEN`。
- 已更新 `ops/tom-readonly/README.md`，记录一次性演练窗口命令。
- 已增强 `test/oss-readiness.test.ts`，覆盖窗口脚本存在、确认短语、只允许 healthcheck 和退出恢复逻辑。
- 已验证 `bash -n ops/tom-readonly/live-healthcheck-window.sh`。
- 已验证 `npm test -- test/oss-readiness.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-gate.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `98965fb ops: add live healthcheck window script`。
- 已部署到 Tom，并验证运行提交 `98965fb`。
- 已验证 Tom `healthcheck.sh` 通过，5 个 OpenClaw gateway 健康端口、容器只读边界和 collector 快照检查通过。
- 已验证 Tom `repo/ops/tom-readonly/live-healthcheck-window.sh status` 通过，未检测到临时 override。
- 已验证 Tom 当前仍为 `READONLY_MODE=true`，live gate 与 executor 均未启用，readiness 仍为 `blocked`。
- 本轮未执行 `enable` 或 `run`，未调用 live API。
- 已新增实例影响快照脚本：`ops/tom-readonly/instance-impact-snapshot.sh`。
- 快照内容包括 gateway health、监听端口、control-center 容器特权状态、实例挂载只读状态、docker.sock 挂载状态、live 相关环境变量和 readiness。
- 已让 `live-healthcheck-window.sh run` 在演练前自动生成 before 快照，在成功或失败恢复只读后生成 after 快照，并调用 `instance-impact-snapshot.sh compare`。
- 已让 compare 要求 after 状态满足：gateway 健康、监听行稳定、实例挂载仍只读、无 docker.sock、`READONLY_MODE=true`、live gate 与 executor 关闭、readiness 不允许 live execution。
- 已更新 `ops/tom-readonly/README.md`，记录快照目录和比较标准。
- 已增强 `test/oss-readiness.test.ts`，覆盖实例影响快照脚本和窗口脚本接入。
- 已验证 `bash -n ops/tom-readonly/instance-impact-snapshot.sh && bash -n ops/tom-readonly/live-healthcheck-window.sh`。
- 已验证 `npm test -- test/oss-readiness.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-gate.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `12f6c8a ops: capture live healthcheck impact evidence`。
- 已部署到 Tom，并验证运行提交 `12f6c8a`。
- 已在 Tom 只读状态下生成 before/after 快照，并验证 `instance-impact-snapshot.sh compare` 通过。
- 已验证 Tom `live-healthcheck-window.sh status` 仍显示未检测到临时 override，`READONLY_MODE=true`，live gate 与 executor 未启用，readiness 仍为 `blocked`。
- 本轮仍未执行 `/api/managed-actions/live`。
- 已新增人工批准记录脚本：`ops/tom-readonly/live-healthcheck-approval.sh`。
- 已新增批准记录样板：`ops/tom-readonly/live-healthcheck-approval.example.json`，默认 `approved=false`。
- 批准记录校验要求：`approved=true`、`approvedAt` 可解析且未过期、`approvedBy` 已填写、实例为 `tom`、动作为 `healthcheck`、操作者为 `Anan`、风险为 `low`、确认短语匹配、`mutatesOpenClawInstance=false`，并且 checklist 全部为 true。
- 已让 `live-healthcheck-window.sh enable/run` 在写入临时 compose override 前调用 `live-healthcheck-approval.sh check`。
- 已让窗口脚本把 `INSTANCE_ID` 与 `OPERATOR` 显式传给 preflight 和 smoke。
- 已更新 `ops/tom-readonly/README.md`，记录 approval 模板生成、人工编辑和校验流程。
- 已增强 `test/oss-readiness.test.ts`，覆盖 approval 脚本、样板和窗口脚本接入。
- 已验证 `bash -n ops/tom-readonly/live-healthcheck-approval.sh && bash -n ops/tom-readonly/live-healthcheck-window.sh`。
- 已验证 approval 模板默认校验失败，人工填入 `approved=true`、`approvedAt`、`approvedBy` 和 checklist 后校验通过。
- 已验证 `npm test -- test/oss-readiness.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-gate.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `e6c629f ops: require approval record for live healthcheck`。
- 已部署到 Tom，并验证运行提交 `e6c629f`。
- 已在 Tom 生成候选 approval 模板，并验证未批准模板不会通过校验。
- 已验证 Tom `live-healthcheck-window.sh status` 仍显示未检测到临时 override，`READONLY_MODE=true`，live gate 与 executor 未启用，readiness 仍为 `blocked`。
- 本轮未执行 `enable` 或 `run`，未调用 `/api/managed-actions/live`。
- 已为 `ops/tom-readonly/live-healthcheck-approval.sh` 新增 `prepare` 模式：文件不存在时生成模板，已存在时不覆盖，并输出 JSON 状态。
- 已为 `ops/tom-readonly/live-healthcheck-approval.sh` 新增 `status` 模式：只读取批准文件状态，不会失败，不调用 live API。
- 已让 `live-healthcheck-window.sh status` 显示 approval 状态。
- 已更新 `ops/tom-readonly/README.md`，将常用流程改为 `prepare -> status -> check -> run`。
- 已增强 `test/oss-readiness.test.ts` 覆盖 `prepare/status` 与窗口状态接入。
- 已验证 `bash -n ops/tom-readonly/live-healthcheck-approval.sh && bash -n ops/tom-readonly/live-healthcheck-window.sh`。
- 已验证 approval `status` 在文件缺失时返回 `missing`。
- 已验证 approval `prepare` 会生成模板并返回 `needs_manual_approval`，再次执行不会覆盖已有文件。
- 已验证 `npm test -- test/oss-readiness.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-gate.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `3d23811 ops: prepare live healthcheck approval safely`。
- 已部署到 Tom，并验证运行提交 `3d23811`。
- 已在 Tom 生成 `/srv/openclaw-control-center-readonly/runtime/live-healthcheck-approval.json` 草稿。
- 已验证 Tom approval 状态为 `needs_manual_approval`，缺口包括 `approved=false`、`approvedBy` 为空、`approvedAt` 未填写、checklist 未确认。
- 已验证 Tom `live-healthcheck-window.sh status` 会显示 approval 状态，并继续显示未检测到临时 override、`READONLY_MODE=true`、live gate 与 executor 未启用、readiness 仍为 `blocked`。
- 本轮未执行 `enable` 或 `run`，未调用 `/api/managed-actions/live`。
- 已新增演练报告脚本：`ops/tom-readonly/live-healthcheck-report.sh`。
- 报告脚本只读取 approval、before/after impact snapshots 和 `runtime/operation-audit.log`，不调用 live API。
- 报告通过条件包括：approval 已批准、dry-run 审计存在、live result 审计为 `executed`、`liveExecution=true`、`mutatesOpenClawInstance=false`，以及 after 快照恢复只读。
- 已让 `live-healthcheck-window.sh run` 在成功比较 before/after 快照后自动调用报告脚本。
- 报告会写入 `runtime/live-healthcheck-reports/`，同时生成 JSON 与 Markdown。
- 已更新 `ops/tom-readonly/README.md`，记录报告目录和通过条件。
- 已增强 `test/oss-readiness.test.ts`，覆盖报告脚本和窗口脚本接入。
- 已验证 `bash -n ops/tom-readonly/live-healthcheck-report.sh && bash -n ops/tom-readonly/live-healthcheck-window.sh`。
- 已用临时 approval、impact snapshots 和模拟 `operation-audit.log` 验证报告脚本生成 `status=passed`，且 Markdown 报告存在。
- 已验证 `npm test -- test/oss-readiness.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-gate.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `ff9890e ops: generate live healthcheck evidence report`。
- 已部署到 Tom，并验证运行提交 `ff9890e`。
- 已验证 Tom `bash -n repo/ops/tom-readonly/live-healthcheck-report.sh` 通过。
- 已验证 Tom `live-healthcheck-window.sh status` 仍显示未检测到临时 override，`READONLY_MODE=true`，live gate 与 executor 未启用，readiness 仍为 `blocked`。
- 本轮未执行 `enable` 或 `run`，未调用 `/api/managed-actions/live`。
- 已根据当前只有一台 Oracle 的生产约束，将当前上线口径收束为 `OPENCLAW_TOPOLOGY_MODE=local-only`：先管理 Tom 当前 Oracle 上的多套 OpenClaw 实例，未来扩展第二台 Oracle 时再显式打开 `cross-server` 链路。
- 已让 `ops/local/final-go-live-runner.sh prepare` 在已经处于人工批准边界时幂等返回 `prepared_waiting_human_approval`，并声明 `writesTomRuntime=false`、`opensLiveGate=false`、`callsManagedActionsLiveApi=false`。
- 已让 `ops/local/final-go-live-runner.sh prepare` 在已经处于批准后待执行边界时幂等返回 `prepared_approved_ready_for_live_window`，不再次准备 Tom runtime。
- 已更新 `ops/tom-readonly/README.md`，说明 OpenClaw 可重复调用本机侧 `prepare`，重复执行不会批准 approval、不会打开 live gate、不会调用 live API。
- 已更新 `implementation_plan.md`，把 final runner 重复 `prepare` 幂等语义写入当前阶段。
- 已新增 `test/final-go-live-runner.test.ts` 覆盖重复 `prepare` 场景，验证第二次调用不会再次 SSH 执行 Tom `prepare`。
- 已验证 `bash -n ops/local/final-go-live-runner.sh`。
- 已验证 `npm test -- test/final-go-live-runner.test.ts`。
- 已验证 `npm test -- test/final-go-live-runner.test.ts test/final-go-live-status.test.ts test/live-healthcheck-rollout-runner.test.ts test/go-live-gate.test.ts test/oss-readiness.test.ts`。
- 已验证 `npm run build`。
- 已验证 `git diff --check`。
- 部署后真实复核发现 Tom 总闸门会同时输出 `live-healthcheck-rollout-runner.sh prepare` 与 approval 命令；已修正 final runner 语义：只要仍存在 `prepare` 下一步，就必须先执行 Tom runner prepare，不能因为同一列表里出现 approval 命令而提前幂等返回。
- 已新增测试覆盖“prepare 与 approval 同时出现时仍先执行 prepare”，验证会 SSH 调用 Tom `live-healthcheck-rollout-runner.sh prepare`，且不会调用 `run-approved`。
- 已重新验证 `bash -n ops/local/final-go-live-runner.sh`。
- 已重新验证 `npm test -- test/final-go-live-runner.test.ts`。
- 已重新验证 `npm test -- test/final-go-live-runner.test.ts test/final-go-live-status.test.ts test/live-healthcheck-rollout-runner.test.ts test/go-live-gate.test.ts test/oss-readiness.test.ts`。
- 已重新验证 `npm run build`。
- 已重新验证 `git diff --check`。
- 已进一步增强本机侧 `final-go-live-runner.sh prepare`：即使 Tom 总闸门仍保守提示 `prepare`，也会先只读调用 Tom `live-healthcheck-rollout-runner.sh status`；如果 Tom 已经处于 `waiting_human_approval` 或 `approved_ready_for_live_window`，则直接幂等返回，不再写 Tom runtime。
- 已更新 `ops/tom-readonly/README.md`，记录本机 runner 会先只读询问 Tom runner readiness，再决定是否真正执行 prepare。
- 已让 `test/final-go-live-runner.test.ts` 的 fake Tom runner 支持 `status`，覆盖首次 prepare 与重复 prepare 的真实调用顺序。
- 已再次验证 `bash -n ops/local/final-go-live-runner.sh`。
- 已再次验证 `npm test -- test/final-go-live-runner.test.ts`。
- 已再次验证 `npm test -- test/final-go-live-runner.test.ts test/final-go-live-status.test.ts test/live-healthcheck-rollout-runner.test.ts test/go-live-gate.test.ts test/oss-readiness.test.ts`。
- 已再次验证 `npm run build`。
- 已再次验证 `git diff --check`。
- 已提交并推送 `8b9cfef ops: make final go live prepare idempotent`、`024cf55 ops: prefer tom prepare before approval boundary`、`a3d3a30 ops: make final prepare check tom readiness first`。
- 已部署到 Tom，并验证运行提交 `a3d3a30`。
- 已验证 Tom `update.sh` 通过，5 个 OpenClaw gateway 健康端口、只读写接口拦截、容器安全边界和 collector 快照均通过。
- 已真实连续执行两次本机侧 `ops/local/final-go-live-runner.sh prepare`：第一次在 Tom readiness 尚未到批准边界时执行 Tom `prepare`，返回 `prepared_waiting_human_approval`，`writesTomRuntime=true` 且只写 control-center runtime；第二次只读识别 `waiting_human_approval`，返回 `prepared_waiting_human_approval`，`writesTomRuntime=false`、`opensLiveGate=false`、`callsManagedActionsLiveApi=false`。
- 当前 Tom 下一步仍是人工 approval：`CONFIRM_APPROVAL_RECORD=I_APPROVE_LIVE_HEALTHCHECK_RECORD APPROVED_BY=Anan repo/ops/tom-readonly/live-healthcheck-approval.sh approve runtime/live-healthcheck-approval.json`。
- 本轮仍未执行 approval `approve`、未打开 live gate、未调用 `/api/managed-actions/live`、未修改或重启任何 OpenClaw 实例。

## 本轮新增

- 已新增 OpenClaw/Discord 可调用的 Tom 侧管理动作命令入口：`ops/tom-readonly/managed-action-command-runner.sh`。
- `managed-action-command-runner.sh status` 只读取 `/api/managed-actions` 与 `/api/managed-actions/readiness`；`plan <command.json>` 只校验命令 JSON，不联网、不写审计；`dry-run <command.json>` 必须设置 `CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CALLS_MANAGED_ACTION_DRY_RUN_API`，并通过 `LOCAL_API_TOKEN` 或显式 `MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container` 取得本地令牌，只调用 `/api/managed-actions/dry-run`。
- 该入口支持 `healthcheck`、`collector_refresh`、`skill_run` 的 dry-run，其中 `skill_run` 必须显式提供 `skillName`；当前仍只生成预览和审计，不调用 OpenClaw skill，不修改实例目录，不重启实例，不打开 live gate。
- 已更新 `ops/tom-readonly/README.md`，加入机器人调用入口的常用命令与安全边界说明。
- 已更新 `implementation_plan.md`，将 OpenClaw/Discord dry-run 命令入口写入当前阶段能力。
- 已新增 `test/managed-action-command-runner.test.ts`，覆盖 plan 不联网、dry-run 缺确认不调用 API、dry-run 只调用 dry-run API 且不泄露本地令牌。
- 已更新 `test/oss-readiness.test.ts`，断言该入口包含确认短语、只调用 dry-run API，并且不包含 managed-actions live API 路径。
- 已验证 `bash -n ops/tom-readonly/managed-action-command-runner.sh`。
- 已发现 Tom 宿主机没有 `.env`，但 control-center 容器内存在 `LOCAL_API_TOKEN`；已为 runner 增加显式 `MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container`，只在 dry-run 模式读取容器令牌，不输出、不落盘。
- 已重新验证 `bash -n ops/tom-readonly/managed-action-command-runner.sh`。
- 已重新验证 `npm test -- test/managed-action-command-runner.test.ts test/oss-readiness.test.ts`。
- 已重新验证 `npm test -- test/managed-action-command-runner.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-readiness.test.ts test/managed-action-live-gate.test.ts test/oss-readiness.test.ts test/readonly-multi-instance-safety.test.ts`。
- 已重新验证 `npm run build`。
- 已重新验证 `git diff --check`。
- 已提交并推送 `c8497be ops: add managed action command dry run runner` 与 `5cc68c6 ops: support container token for command dry runs`。
- 已部署到 Tom，并验证运行提交 `5cc68c6`。
- 已验证 Tom `update.sh` 通过，5 个 OpenClaw gateway 健康端口、只读写接口拦截、容器安全边界和 collector 快照均通过。
- 已在 Tom 生成 `runtime/managed-action-command-smoke.json`，内容为 `instanceId=tom`、`action=skill_run`、`skillName=zhihu-human-ops-writing`。
- 已验证 Tom `managed-action-command-runner.sh status` 返回 `status_ready`，readiness 仍为 `blocked`、`liveExecutionAvailable=false`。
- 已验证 Tom `managed-action-command-runner.sh plan runtime/managed-action-command-smoke.json` 返回 `planned`，且 `callsManagedActionsDryRunApi=false`、`callsManagedActionsLiveApi=false`、`writesOpenClawInstanceDirs=false`。
- 已验证 Tom 使用 `CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CALLS_MANAGED_ACTION_DRY_RUN_API MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container` 执行 `dry-run` 成功，返回 `dry_run_completed`、`apiStatus=dry_run_ready`，生成 dry-run 审计 `operationRequestId=26dc83f7-5abb-4736-b6ae-578a7b8db1ea`。
- 已验证 Tom dry-run 的 `commandPreview` 为 `openclaw skill dry-run for instance tom: zhihu-human-ops-writing`，安全字段为 `callsManagedActionsDryRunApi=true`、`callsManagedActionsLiveApi=false`、`writesOpenClawInstanceDirs=false`、`restartsOpenClawInstances=false`、`opensLiveGate=false`、`localApiTokenSource=container`。
- 本轮仍未执行 approval `approve`、未打开 live gate、未调用 `/api/managed-actions/live`、未修改或重启任何 OpenClaw 实例。

## 阶段完成后的下一步

- 已为 `ops/tom-readonly/managed-action-command-runner.sh` 增加文本指令入口：`parse-text <command.txt>`、`plan-text <command.txt>`、`dry-run-text <command.txt>`。
- 已固化文本解析规则：文本必须明确包含 `dry-run`、`预览` 或 `演练`，否则阻止；文本包含 `live`、`真实执行`、`发布`、`重启`、`approval` 等高风险词时阻止。
- 已支持把“对 tom 运行 zhihu-human-ops-writing dry-run”解析为 `instanceId=tom`、`action=skill_run`、`skillName=zhihu-human-ops-writing`、`operator=Anan`、`confirmedText=DRY-RUN-ONLY`。
- 已更新 `ops/tom-readonly/README.md`，加入 `parse-text`、`plan-text`、`dry-run-text` 常用命令和安全边界。
- 已更新 `test/managed-action-command-runner.test.ts`，覆盖中文文本解析、`plan-text` 不联网、缺少 dry-run 字样阻断、高风险词阻断、`dry-run-text` 只调用 dry-run API。
- 已更新 `test/oss-readiness.test.ts`，断言文本入口存在、要求 dry-run 字样、包含高风险词阻断逻辑，并继续断言不包含 managed-actions live API 路径。
- 已验证 `bash -n ops/tom-readonly/managed-action-command-runner.sh`。
- 已验证 `npm test -- test/managed-action-command-runner.test.ts`。
- 已验证 `npm test -- test/managed-action-command-runner.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-readiness.test.ts test/managed-action-live-gate.test.ts test/oss-readiness.test.ts test/readonly-multi-instance-safety.test.ts`。
- 已验证 `npm run build`。
- 已验证 `git diff --check`。
- 已提交并推送 `1f16bb0 ops: parse managed action text commands`。
- 已部署到 Tom，并验证运行提交 `1f16bb0`。
- 已验证 Tom `update.sh` 通过，5 个 OpenClaw gateway 健康端口、只读写接口拦截、容器安全边界和 collector 快照均通过。
- 已在 Tom 生成文本指令 `runtime/managed-action-command-text-smoke.txt`，内容为“对 tom 运行 zhihu-human-ops-writing dry-run”。
- 已验证 Tom `parse-text` 返回 `parsed`，解析为 `instanceId=tom`、`action=skill_run`、`skillName=zhihu-human-ops-writing`、`operator=Anan`、`confirmedText=DRY-RUN-ONLY`，且 `callsManagedActionsDryRunApi=false`、`callsManagedActionsLiveApi=false`、`writesOpenClawInstanceDirs=false`。
- 已验证 Tom `plan-text` 返回 `planned`，目标为 `tom / skill_run / zhihu-human-ops-writing`，仍不联网、不写审计、不调用 live。
- 已验证 Tom `dry-run-text` 使用 `MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container` 成功，返回 `dry_run_completed`、`apiStatus=dry_run_ready`，生成 dry-run 审计 `operationRequestId=ff77d3d5-5c71-46aa-b5a4-4c10137655a3`。
- 已验证 Tom `dry-run-text` 的 `commandPreview` 为 `openclaw skill dry-run for instance tom: zhihu-human-ops-writing`，安全字段为 `callsManagedActionsDryRunApi=true`、`callsManagedActionsLiveApi=false`、`writesOpenClawInstanceDirs=false`、`restartsOpenClawInstances=false`、`opensLiveGate=false`、`localApiTokenSource=container`。
- 已验证 Tom 对高风险文本“对 tom 运行 zhihu-human-ops-writing dry-run 后发布”执行 `parse-text` 会返回 `blocked_invalid_command`、退出码 2，并在调用 API 前阻止。
- 本轮仍未执行 approval `approve`、未打开 live gate、未调用 `/api/managed-actions/live`、未修改或重启任何 OpenClaw 实例。

## 阶段完成后的下一步

## 本轮新增（机器人文本桥接层）

- 已新增 `ops/tom-readonly/managed-action-text-bridge.sh`。
- 该脚本支持 `parse <command.txt|->`、`plan <command.txt|->`、`dry-run <command.txt|->`，也支持 `MANAGED_ACTION_TEXT` 和 `MANAGED_ACTION_TEXT_FILE`。
- 桥接层会把机器人文本统一写入 control-center runtime 的 `managed-action-command.txt`，再调用底层 `managed-action-command-runner.sh parse-text/plan-text/dry-run-text`。
- 已修正 Tom repo 布局下的默认 runtime 位置：从 `repo/ops/tom-readonly` 调用时，桥接层默认写部署根目录的 `runtime/managed-action-command.txt`，并把同一个 `DEPLOY_DIR` 传给底层 runner。
- `parse/plan` 只写 control-center runtime 文本副本并返回精简 JSON 摘要；不联网、不写审计、不调用 live。
- `dry-run` 必须设置 `CONFIRM_MANAGED_ACTION_TEXT_BRIDGE=I_UNDERSTAND_THIS_ONLY_RUNS_MANAGED_ACTION_DRY_RUN_TEXT`，随后才会自动补齐底层 runner 的 dry-run 确认并调用 `dry-run-text`。
- 输出摘要包含 `runnerStatus`、`target`、`operationRequestId`、`commandPreview` 和安全字段，便于机器人直接回传给 Discord/OpenClaw。
- 已新增 `test/managed-action-text-bridge.test.ts`，覆盖 parse 写入 runtime 并调用 runner、plan 只调用 `plan-text`、dry-run 缺桥接确认不调用 runner、dry-run 设置底层确认且不泄露令牌、Tom repo 布局下默认写部署根 runtime。
- 已更新 `ops/tom-readonly/README.md`、`docs/MULTI_INSTANCE_READONLY.md`、`implementation_plan.md` 和 `test/oss-readiness.test.ts`，记录桥接入口和安全边界。
- 已验证 `bash -n ops/tom-readonly/managed-action-text-bridge.sh`。
- 已验证 `npm test -- test/managed-action-text-bridge.test.ts`，5/5 通过。
- 已验证 `npm test -- test/managed-action-text-bridge.test.ts test/managed-action-command-runner.test.ts test/oss-readiness.test.ts`，18/18 通过。
- 已验证 `npm test -- test/managed-action-text-bridge.test.ts test/managed-action-command-runner.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-readiness.test.ts test/managed-action-live-gate.test.ts test/oss-readiness.test.ts test/readonly-multi-instance-safety.test.ts`，29/29 通过。
- 已验证 `npm run build`。
- 已验证 `git diff --check`。
- 已提交并推送 `b1d4385 ops: add managed action text bridge` 和 `aa64728 ops: use deploy runtime for text bridge`。
- 已部署到 Tom，并验证运行提交 `aa64728`。
- 已验证 Tom `update.sh` 通过，5 个 OpenClaw gateway 健康端口、只读写接口拦截、容器安全边界和 collector 快照均通过。
- 已在 Tom 真实执行桥接层 smoke：`parse` 返回 `bridge_parse_completed`、`runnerStatus=parsed`，目标为 `tom / skill_run / zhihu-human-ops-writing`，且 `callsManagedActionsDryRunApi=false`、`callsManagedActionsLiveApi=false`、`writesOpenClawInstanceDirs=false`。
- 已验证 Tom `plan` 返回 `bridge_plan_completed`、`runnerStatus=planned`，仍不调用 dry-run API、不调用 live、不写实例目录。
- 已验证 Tom `dry-run` 使用 `CONFIRM_MANAGED_ACTION_TEXT_BRIDGE=I_UNDERSTAND_THIS_ONLY_RUNS_MANAGED_ACTION_DRY_RUN_TEXT` 和 `MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container` 成功，返回 `bridge_dry_run_completed`、`runnerStatus=dry_run_completed`，生成 dry-run 审计 `operationRequestId=89c2c8c0-f657-4fcc-8946-5bb48e0b1be9`。
- 已验证 Tom 桥接层默认写入 `/srv/openclaw-control-center-readonly/runtime/managed-action-command.txt`，没有继续写 `repo/runtime/managed-action-command.txt`。
- 已验证 Tom 对高风险文本“对 tom 运行 zhihu-human-ops-writing dry-run 后发布”返回 `blocked_bridge_runner`、`runnerStatus=blocked_invalid_command`，在调用 dry-run API 前阻断，安全字段保持 `callsManagedActionsDryRunApi=false`、`callsManagedActionsLiveApi=false`、`writesOpenClawInstanceDirs=false`。
- 本轮仍未执行 approval `approve`、未打开 live gate、未调用 managed action live API、未修改或重启任何 OpenClaw 实例。

## 阶段完成后的下一步

## 本轮新增（OpenClaw workspace inbox runner）

- 已新增 `ops/tom-readonly/managed-action-inbox-runner.sh`。
- 该脚本支持 `status`、`plan-next`、`run-next`。
- Tom/Discord 机器人不需要改 Discord 插件，也不需要重启 OpenClaw；它只需在 workspace 写入 `control-center-commands/inbox/*.txt` 文本请求。
- control-center 通过只读挂载 `/instances/tom/workspace/control-center-commands/inbox` 读取请求，`MANAGED_ACTION_INBOX_SOURCE=control-center-container` 时由 control-center 容器读取该只读挂载，避免宿主机直接写 OpenClaw workspace。
- `status` 只列出待处理文本，不调用桥接层。
- `plan-next` 调用 `managed-action-text-bridge.sh plan`，不标记已处理，不创建 dry-run 审计。
- `run-next` 必须设置 `CONFIRM_MANAGED_ACTION_INBOX_RUNNER=I_UNDERSTAND_THIS_READS_OPENCLAW_INBOX_AND_RUNS_DRY_RUN_TEXT`，只调用桥接层 `dry-run`。
- runner 不移动、不删除、不修改 OpenClaw workspace 中的请求文件；处理状态、结果和去重 key 只写 `runtime/managed-action-inbox-runner/`。
- 同一路径同一内容只处理一次；如果文本内容被修改，会生成新的 key 并重新评估。
- 已新增 `test/managed-action-inbox-runner.test.ts`，覆盖 status 不调用桥接层、plan-next 不标记已处理、run-next 缺确认阻断、run-next 成功写 control-center runtime 状态并隐藏令牌。
- 已更新 `ops/tom-readonly/README.md`、`docs/MULTI_INSTANCE_READONLY.md`、`implementation_plan.md` 和 `test/oss-readiness.test.ts`，记录 inbox runner 和安全边界。
- 已验证 `bash -n ops/tom-readonly/managed-action-inbox-runner.sh` 与 `bash -n ops/tom-readonly/managed-action-text-bridge.sh`。
- 已验证 `npm test -- test/managed-action-inbox-runner.test.ts test/managed-action-text-bridge.test.ts test/managed-action-command-runner.test.ts test/oss-readiness.test.ts`，23/23 通过。
- 已验证 `npm test -- test/managed-action-inbox-runner.test.ts test/managed-action-text-bridge.test.ts test/managed-action-command-runner.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-readiness.test.ts test/managed-action-live-gate.test.ts test/oss-readiness.test.ts test/readonly-multi-instance-safety.test.ts`，33/33 通过。
- 已验证 `npm run build`。
- 已提交并推送 `61b4615 ops: add managed action inbox runner`。
- 已部署到 Tom，并验证运行提交 `61b4615`。
- 已验证 Tom `update.sh` 通过，5 个 OpenClaw gateway 健康端口、只读写接口拦截、容器安全边界和 collector 快照均通过。
- 已在 Tom 的 OpenClaw workspace 创建专用 smoke inbox：`/home/node/.openclaw/workspace/control-center-commands/smoke-20260517T162355Z/inbox/001.txt`，内容为“对 tom 运行 zhihu-human-ops-writing dry-run”。
- 已验证 control-center 通过只读挂载 `/instances/tom/workspace/control-center-commands/smoke-20260517T162355Z/inbox` 读取该请求，`status` 返回 `inbox_status_ready`、`pendingCount=1`，不调用桥接层、不创建审计。
- 已验证 `plan-next` 返回 `inbox_plan_completed`、`bridgeStatus=bridge_plan_completed`、`runnerStatus=planned`，目标为 `tom / skill_run / zhihu-human-ops-writing`，安全字段为 `callsManagedActionsDryRunApi=false`、`callsManagedActionsLiveApi=false`、`writesOpenClawInstanceDirs=false`。
- 已验证 `run-next` 使用 `CONFIRM_MANAGED_ACTION_INBOX_RUNNER=I_UNDERSTAND_THIS_READS_OPENCLAW_INBOX_AND_RUNS_DRY_RUN_TEXT` 与 `MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container` 成功，返回 `inbox_dry_run_completed`、`bridgeStatus=bridge_dry_run_completed`、`runnerStatus=dry_run_completed`，生成 dry-run 审计 `operationRequestId=fae5dec5-3f1f-424f-92a6-a1bd05233565`。
- 已验证 `run-next` 的 `commandPreview` 为 `openclaw skill dry-run for instance tom: zhihu-human-ops-writing`，结果写入 `/srv/openclaw-control-center-readonly/runtime/managed-action-inbox-runner/results/2026-05-17T16-24-55-798Z-001.txt.json`。
- 已验证重复 `status` 对同一路径同一内容返回 `inbox_empty`、`pendingCount=0`，且 OpenClaw workspace 中原请求文件仍存在，没有被移动、删除或修改。
- 本轮仍未执行 approval `approve`、未打开 live gate、未调用 managed action live API、未修改 OpenClaw 配置、未重启任何 OpenClaw 实例。

## 阶段完成后的下一步

## 本轮新增（Tom AGENTS inbox 规范安装器）

- 已新增 `ops/tom-readonly/install-managed-action-agents-instructions.sh`。
- 该脚本支持 `status`、`plan`、`apply`。
- `status/plan` 只读取目标 `AGENTS.md`，展示 `OPENCLAW_CONTROL_CENTER_MANAGED_ACTIONS` 标记块是否需要安装或更新，不写文件。
- `apply` 必须设置 `CONFIRM_MANAGED_ACTION_AGENTS_INSTALL=I_UNDERSTAND_THIS_UPDATES_TOM_AGENTS_INSTRUCTIONS_ONLY`。
- 安装器支持 `MANAGED_ACTION_AGENTS_TARGET_SOURCE=local` 用于测试，也支持 `MANAGED_ACTION_AGENTS_TARGET_SOURCE=openclaw-container` 通过 `openclaw-work-openclaw-gateway-1` 写 Tom workspace。
- 安装内容要求 Tom 在 Discord 收到 control-center dry-run/预览类请求时，只写入 `control-center-commands/inbox/*.txt`，不调用 control-center API，不读取或输出 `LOCAL_API_TOKEN`，不打开 live gate，不重启实例，不删除或移动 inbox 请求文件。
- `apply` 会在目标 `AGENTS.md` 同目录 `.backup/control-center-agents/` 下备份原文件，并只更新受控标记块。
- 已新增 `test/managed-action-agents-instructions.test.ts`，覆盖 plan 不写文件、apply 缺确认阻断、apply 插入并备份、已有标记块幂等更新。
- 已更新 `ops/tom-readonly/README.md`、`docs/MULTI_INSTANCE_READONLY.md`、`implementation_plan.md` 和 `test/oss-readiness.test.ts`，记录 AGENTS 规范安装器和安全边界。
- 已验证 `bash -n ops/tom-readonly/install-managed-action-agents-instructions.sh`。
- 已验证 `npm test -- test/managed-action-agents-instructions.test.ts test/managed-action-inbox-runner.test.ts test/managed-action-text-bridge.test.ts test/managed-action-command-runner.test.ts test/oss-readiness.test.ts`，27/27 通过。
- 已验证 `npm test -- test/managed-action-agents-instructions.test.ts test/managed-action-inbox-runner.test.ts test/managed-action-text-bridge.test.ts test/managed-action-command-runner.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-readiness.test.ts test/managed-action-live-gate.test.ts test/oss-readiness.test.ts test/readonly-multi-instance-safety.test.ts`，37/37 通过。
- 已验证 `npm run build` 与 `git diff --check`。
- 已提交并推送 `716cfc9 ops: install managed action agents instructions`。
- 已部署到 Tom，并验证 `update.sh` 通过，5 个 OpenClaw gateway 健康端口、只读写接口拦截、容器安全边界和 collector 快照均通过。
- 已在 Tom 执行 `status/plan`，确认目标为 `/home/node/.openclaw/workspace/AGENTS.md`，初始状态 `installed=false`、`needsUpdate=true`，计划只插入 `OPENCLAW_CONTROL_CENTER_MANAGED_ACTIONS` 标记块。
- 已执行显式确认 `apply`，返回 `agents_instructions_installed`，备份路径为 `/home/node/.openclaw/workspace/.backup/control-center-agents/2026-05-17T16-37-12-259Z-AGENTS.md`，安全字段为 `writesAgentsMdOnly=true`、`writesOpenClawConfig=false`、`restartsOpenClawInstances=false`、`callsManagedActionsLiveApi=false`、`opensLiveGate=false`。
- 部署后发现 `apply` 已插入标记块但 `status` 仍误报 `needsUpdate=true`；根因为受控标记块前后空白归一化不幂等。
- 已新增回归测试“apply 后 status 不应再次要求更新”，先复现失败，再修复 `replaceBlock()` 的空白处理。
- 已验证修复后 `npm test -- test/managed-action-agents-instructions.test.ts`，5/5 通过。
- 已验证修复后 managed-action 安全回归，38/38 通过。
- 已再次验证 `npm run build` 与 `git diff --check`。
- 已提交并推送 `b10d5a9 fix: make managed action agents installer idempotent`。
- 已部署到 Tom，并验证 Tom repo 当前提交为 `b10d5a9`。
- 已重新运行 Tom `status`，返回 `agents_instructions_installed`、`installed=true`、`needsUpdate=false`。
- 已验证 Tom OpenClaw gateway 容器 `openclaw-work-openclaw-gateway-1` 仍为 `Up 28 hours (healthy)`。
- 已验证 Tom `healthcheck.sh` 通过，collector 快照正常，当前实例数量为 5。
- 已执行标准 inbox smoke，先确认 `/instances/tom/workspace/control-center-commands/inbox` 返回 `inbox_empty`、`pendingCount=0`。
- 已模拟 Tom/Discord 按 AGENTS 规范在容器内写入 `/home/node/.openclaw/workspace/control-center-commands/inbox/20260517T164118Z-managed-action.txt`，内容为“对 tom 运行 zhihu-human-ops-writing dry-run”。
- 已验证 control-center 通过只读挂载读取标准 inbox，`status` 返回 `inbox_status_ready`、`candidateCount=1`、`pendingCount=1`。
- 已验证 `plan-next` 返回 `inbox_plan_completed`、`bridgeStatus=bridge_plan_completed`、`runnerStatus=planned`，目标为 `tom / skill_run / zhihu-human-ops-writing`，且 `callsManagedActionsDryRunApi=false`、`callsManagedActionsLiveApi=false`、`writesOpenClawInstanceDirs=false`、`restartsOpenClawInstances=false`。
- 已验证 `run-next` 使用显式确认和 `MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container` 成功，返回 `inbox_dry_run_completed`、`bridgeStatus=bridge_dry_run_completed`、`runnerStatus=dry_run_completed`。
- 本次标准 inbox smoke 生成 dry-run 审计 `operationRequestId=d7b98d20-39ad-47e9-9b31-53bae6121c1f`，`commandPreview` 为 `openclaw skill dry-run for instance tom: zhihu-human-ops-writing`。
- 已验证 smoke 结果写入 `/srv/openclaw-control-center-readonly/runtime/managed-action-inbox-runner/results/2026-05-17T16-41-32-472Z-20260517T164118Z-managed-action.txt.json`。
- 已验证重复 `status` 返回 `inbox_empty`、`pendingCount=0`，原请求文件仍存在，大小 47 bytes，没有被移动或删除。
- 已再次验证 Tom `healthcheck.sh` 通过，collector 快照正常，当前实例数量为 5。
- 本轮仍未执行 approval `approve`、未打开 live gate、未调用 managed action live API、未修改 `openclaw.json`、未重启任何 OpenClaw 实例。

## 阶段完成后的下一步

下一步让 Anan 从 Discord 发一条同类测试指令，验证“Discord/OpenClaw 消息 → Tom inbox → control-center dry-run 审计”的真实链路。建议指令为：“控制中心 dry-run：对 tom 运行 zhihu-human-ops-writing dry-run”。Tom 应只回报 inbox 文件路径；随后在 host 侧运行 `managed-action-inbox-runner.sh status/plan-next/run-next` 完成 dry-run 审计。仍不得执行 approval `approve`、不得打开 live gate、不得触发真实 skill。

## 本轮继续（最终上线 runner prepare）

- 已核对本地仓库：`multi-instance-readonly-control-center` 与 origin 同步，工作树干净。
- 已核对 Tom repo：运行提交 `fbd015d`，工作树干净。
- 已检查标准 inbox：`MANAGED_ACTION_INBOX_SOURCE=control-center-container`、`MANAGED_ACTION_INBOX_DIR=/instances/tom/workspace/control-center-commands/inbox` 返回 `inbox_empty`、`candidateCount=1`、`pendingCount=0`，说明还没有新的 Discord 真实请求。
- 已执行本机总状态入口 `ops/local/final-go-live-status.sh status`，返回 `ready_for_existing_instance_healthcheck`；当前拓扑为 `local-only`，第二台 Oracle host/key 被跳过，跨服务器接入不是当前上线阻塞。
- 已执行本机总检查入口 `ops/local/final-go-live-status.sh check`，现有 5 个 OpenClaw gateway 端口、总览页、实例详情页、只读写接口闸门、容器安全边界和 collector 快照均通过；状态阻塞在 `blocked_managed_actions`，原因是 approval 仍为 `needs_manual_approval`，live gate 未打开。
- 已执行 `ops/local/final-go-live-runner.sh prepare`，返回 `prepared_waiting_human_approval`。
- `prepare` 的安全字段显示：`writesTomRuntime=true`、`writesControlCenterRuntimeOnly=true`、`approvesLiveHealthcheck=false`、`opensLiveGate=false`、`callsManagedActionsLiveApi=false`、`writesOpenClawInstanceDirs=false`、`restartsOpenClawInstances=false`。
- `prepare` 后再次自动执行最终 check，现有实例健康仍通过，collector 快照正常，仍阻塞在人工 approval，不进入 live。
- 已验证 Tom `live-healthcheck-readiness.sh status` 返回 `waiting_human_approval`。
- 已验证 Tom `live-healthcheck-approval.sh status runtime/live-healthcheck-approval.json` 返回 `needs_manual_approval`，`approved=false`，`approvedBy` 和 `approvedAt` 仍为空，所有人工 checklist 仍未勾选。
- 文档提交同步到 Tom 后，旧证据包会因为 commit 变化被 readiness 正确拦截并返回 commit mismatch；这是批准前证据包安全机制生效。
- 已按安全机制重新执行 `ops/local/final-go-live-runner.sh prepare`，为 Tom 当前 commit 重新生成证据包，并继续停在人工批准前。
- 当前有效证据包不写死在文档中；以 Tom runtime 最新 `runtime/live-healthcheck-approval-packets/live-healthcheck-approval-packet-*.json` 和 `live-healthcheck-readiness.sh status` 为准。
- 最终复核要求：Tom `live-healthcheck-readiness.sh status` 返回 `waiting_human_approval`，`issues=[]`，`approvalStatus=needs_manual_approval`；最新证据包 `live-healthcheck-approval-packet.sh check` 返回 `ready`，packet commit 与 Tom 当前 commit 一致。
- 证据包安全字段显示：`callsManagedActionsLiveApi=false`、`writesOpenClawInstanceDirs=false`、`restartsOpenClawInstances=false`、`bypassesApproval=false`。
- 已再次验证 Tom `healthcheck.sh` 通过，当前实例数量为 5。
- 本轮仍未执行 approval `approve`、未打开 live gate、未调用 managed action live API、未修改 `openclaw.json`、未重启任何 OpenClaw 实例。

## 阶段完成后的下一步

当前 dry-run inbox cron 已安装并通过自动消费 smoke。下一步是重新生成与当前 commit 对齐的 live healthcheck approval packet，并停在人工批准前；如果要继续 live healthcheck 演练，必须由 Anan 审查证据包后显式运行 `CONFIRM_APPROVAL_RECORD=I_APPROVE_LIVE_HEALTHCHECK_RECORD APPROVED_BY=Anan repo/ops/tom-readonly/live-healthcheck-approval.sh approve runtime/live-healthcheck-approval.json`，之后才允许执行一次性 `run-approved`。仍不得绕过人工 approval。

## 本轮新增（inbox dry-run cron 安装器）

- 已新增 `ops/tom-readonly/install-managed-action-inbox-cron.sh`。
- 该脚本支持 `status`、`plan`、`apply`、`remove`。
- `status/plan` 只读取当前用户 crontab，并展示将安装的 `OPENCLAW_MANAGED_ACTION_INBOX_CRON` 受控块，不写 crontab。
- `apply/remove` 必须设置 `CONFIRM_MANAGED_ACTION_INBOX_CRON=I_UNDERSTAND_THIS_ONLY_INSTALLS_DRY_RUN_INBOX_CRON`。
- 安装后的 cron 只调用 `managed-action-inbox-runner.sh run-pending`，并自动带上 `CONFIRM_MANAGED_ACTION_INBOX_RUNNER`、`MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container`、`MANAGED_ACTION_INBOX_SOURCE=control-center-container`、`MANAGED_ACTION_INBOX_MAX_PER_RUN`。
- 安装器安全字段保持 `callsManagedActionsLiveApi=false`、`writesOpenClawInstanceDirs=false`、`restartsOpenClawInstances=false`、`opensLiveGate=false`。
- 已新增 `test/managed-action-inbox-cron.test.ts`，覆盖 plan 不写 crontab、apply 缺确认阻断、apply 安装受控块、remove 移除受控块、runner 缺失阻断，以及 crontab 命令必须在 `cd ... &&` 后执行 runner。
- 已更新 `ops/tom-readonly/README.md`、`docs/MULTI_INSTANCE_READONLY.md`、`implementation_plan.md` 和 `test/oss-readiness.test.ts`，记录 cron 安装器和安全边界。
- 已验证 `bash -n ops/tom-readonly/install-managed-action-inbox-cron.sh`。
- 已验证 `npm test -- test/managed-action-inbox-cron.test.ts`，4/4 通过。

## 阶段完成后的下一步

cron 安装器已完成部署、受控 crontab 已安装，且 Tom workspace inbox 自动消费 smoke 已通过。继续推进时先重建最终 approval packet，并确认 readiness 仍是 `waiting_human_approval`；仍不得执行 approval `approve`、不得打开 live gate。

## 本轮新增（inbox dry-run 批处理入口）

- 已扩展 `ops/tom-readonly/managed-action-inbox-runner.sh`，新增 `run-pending` 模式。
- `run-pending` 与 `run-next` 使用同一个确认短语：`CONFIRM_MANAGED_ACTION_INBOX_RUNNER=I_UNDERSTAND_THIS_READS_OPENCLAW_INBOX_AND_RUNS_DRY_RUN_TEXT`。
- `run-pending` 会按顺序处理待处理 inbox 文本，默认最多处理 `MANAGED_ACTION_INBOX_MAX_PER_RUN=10` 条。
- `run-pending` 只调用 `managed-action-text-bridge.sh dry-run`，只写 `runtime/managed-action-inbox-runner/` 的状态和结果，不移动、不删除、不修改 OpenClaw workspace 请求文件。
- `run-pending` 安全字段保持 `callsManagedActionsLiveApi=false`、`writesOpenClawInstanceDirs=false`、`restartsOpenClawInstances=false`、`opensLiveGate=false`。
- 已新增测试覆盖 `run-pending` 一次处理多个 dry-run 请求，并验证结果、state、去重和 token 隐藏。
- 已新增测试覆盖 `run-pending` 缺确认时阻断且不调用桥接层。
- 已更新 `ops/tom-readonly/README.md`、`docs/MULTI_INSTANCE_READONLY.md`、`implementation_plan.md` 和 `test/oss-readiness.test.ts`，记录 `run-pending` 的用途和安全边界。
- 已验证 `bash -n ops/tom-readonly/managed-action-inbox-runner.sh`。
- 已验证 `npm test -- test/managed-action-inbox-runner.test.ts`，6/6 通过。
- 已验证 `npm test -- test/managed-action-inbox-runner.test.ts test/managed-action-text-bridge.test.ts test/managed-action-command-runner.test.ts test/oss-readiness.test.ts`，25/25 通过。
- 已验证 managed-action 安全回归，35/35 通过。
- 已验证 `npm run build` 与 `git diff --check`。
- 已提交并推送 `ee4cab2 ops: batch process managed action inbox dry runs`。
- 已部署到 Tom，并验证 `update.sh` 通过，5 个 OpenClaw gateway 健康端口、只读写接口拦截、容器安全边界和 collector 快照均通过。
- 已在 Tom 标准 inbox 写入两条 smoke 请求：
  `/home/node/.openclaw/workspace/control-center-commands/inbox/20260517T165820Z-run-pending-1.txt`
  与 `/home/node/.openclaw/workspace/control-center-commands/inbox/20260517T165820Z-run-pending-2.txt`。
- 已验证运行前 `status` 返回 `inbox_status_ready`、`candidateCount=3`、`pendingCount=2`。
- 已用 `CONFIRM_MANAGED_ACTION_INBOX_RUNNER=I_UNDERSTAND_THIS_READS_OPENCLAW_INBOX_AND_RUNS_DRY_RUN_TEXT`、`MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container`、`MANAGED_ACTION_INBOX_MAX_PER_RUN=10` 执行 `run-pending`。
- Tom `run-pending` 返回 `inbox_run_pending_completed`、`pendingCountBefore=2`、`processedCount=2`、`pendingCountAfter=0`。
- 本次 `run-pending` 生成 dry-run 审计 `operationRequestId=f99b7f4a-426e-492d-a4c7-a478ec5e91ec` 和 `operationRequestId=e85e6a59-0178-4930-9fc0-a5cbebe5817b`。
- 已验证 `run-pending` 安全字段为 `callsManagedActionsDryRunApi=true`、`callsManagedActionsLiveApi=false`、`writesOpenClawInstanceDirs=false`、`restartsOpenClawInstances=false`、`mutatesOpenClawInstance=false`、`opensLiveGate=false`。
- 已验证重复 `status` 返回 `inbox_empty`、`pendingCount=0`，标准 inbox 文件仍保留为候选文件，不被移动或删除。

## 阶段完成后的下一步

部署已完成。下一步重新执行 `ops/local/final-go-live-runner.sh prepare`，让 approval packet 与最新 Tom commit 对齐；然后复核 `live-healthcheck-readiness.sh status` 为 `waiting_human_approval` 且 `issues=[]`。仍不得执行 approval `approve`、不得打开 live gate。

## 本轮新增（异常用量线索）

- 已在 `src/ui/server.ts` 为多实例 `usage-cost` 页面新增 `Usage anomaly clues / 异常用量线索` 面板。
- 该面板只读取 collector history 中的 token 增量，不调用模型、不写 runtime、不修改任何 OpenClaw 实例目录。
- 面板会识别“周期性小额增长”形态，展示实例、窗口增量、中位时间间隔、中位 token 增量、节奏分数和最近样本时间。
- 该能力用于提前发现类似 deepseek heartbeat/定时轮询持续消耗 token 的情况。
- 已新增 `test/ui-render-smoke.test.ts` 回归测试，模拟 deepseek 每 30 分钟增加 280 token，确认页面出现“异常用量线索”“周期性小额增长”和 `heartbeat` 提示。
- 已验证 `npm test -- test/ui-render-smoke.test.ts`，36/36 通过。
- 已验证 `npm run build`。
- 已提交并推送 `a975557 usage: flag periodic token growth`。
- 第一版部署到 Tom 后，页面已出现“异常用量线索”面板，但 deepseek 未被标记；根因为 collector 每 2 分钟采样，而算法误把相邻采样间隔当作增长节奏。
- 已修复为“相邻非零增长事件之间的间隔”，并提交推送 `44b39e5 fix: detect sampled periodic token growth`。
- 已再次部署到 Tom，`update.sh` 通过，5 个 OpenClaw gateway 健康端口、总览页、实例详情页、只读写接口拦截、容器安全边界和 collector 快照均通过。
- 已在 Tom 页面级确认 `/?section=usage-cost&usage_instance=deepseek&lang=zh` 显示 deepseek “最近突增”：窗口增量 `+13,509`，节奏 `30 分钟`，中位增量 `282`，最近增量 `+8182 tokens`。
- 已执行本机只读 `FINAL_GO_LIVE_OUTPUT=summary OPENCLAW_TOPOLOGY_MODE=local-only ops/local/final-go-live-runner.sh status`，返回 `ready_for_existing_instance_healthcheck`，安全字段为 `opensLiveGate=false`、`callsManagedActionsLiveApi=false`、`writesOpenClawInstanceDirs=false`、`restartsOpenClawInstances=false`。
- 本轮没有执行 approval `approve`，没有打开 live gate，没有调用 managed action live API，没有修改或重启任何 OpenClaw 实例。

## 阶段完成后的下一步

下一步执行一次只读 `ops/local/final-go-live-status.sh check` 或 `final-go-live-runner.sh prepare`，把最新提交重新推进到人工批准边界；如果 Anan 暂时不想进入 live healthcheck 人工批准流程，则先处理 deepseek heartbeat 根因：清空或关闭 `/srv/openclaw-deepseek/workspace/HEARTBEAT.md`。仍不得执行 approval `approve`、不得打开 live gate、不得触发真实 managed action。

## 本轮新增（consumed approval prepare 幂等修复）

- 发现最终上线 `prepare` 在 Tom 上被旧的 `runtime/live-healthcheck-approval.json` 阻塞：该 approval 已于 `2026-05-17T18:24:39.181Z` 被消费，状态为 `consumed`。
- 已修复 `ops/tom-readonly/live-healthcheck-approval.sh prepare`：当现有 approval 文件 `consumed=true` 时，先备份到 `runtime/.backup/live-healthcheck-approval/`，再生成新的未批准模板。
- 该修复只写 control-center runtime 的 approval 文件和备份，不批准、不打开 live gate、不调用 managed action live API、不修改 OpenClaw 实例目录、不重启实例。
- 已新增 `test/live-healthcheck-approval.test.ts` 回归测试，覆盖 consumed approval 被归档并生成 fresh template。
- 已验证 `bash -n ops/tom-readonly/live-healthcheck-approval.sh ops/tom-readonly/live-healthcheck-rollout-runner.sh`。
- 已验证 `npm test -- test/live-healthcheck-approval.test.ts test/live-healthcheck-rollout-runner.test.ts test/final-go-live-runner.test.ts`，26/26 通过。
- 已验证 `npm run build`。
- 已提交并推送 `9b9063f fix: refresh consumed live approval drafts`。
- 已部署到 Tom，`update.sh` 通过，5 个 OpenClaw gateway 健康端口、总览页、实例详情页、只读写接口拦截、容器安全边界和 collector 快照均通过。
- 已重新执行 `FINAL_GO_LIVE_OUTPUT=summary OPENCLAW_TOPOLOGY_MODE=local-only ops/local/final-go-live-runner.sh prepare`，返回 `prepared_waiting_human_approval`。
- 当前边界状态：`readiness=waiting_human_approval`、`approvalPacket=ready`、`approval=needs_manual_approval`、`inboxPendingCount=0`。
- 当前下一步只剩人工批准命令：`CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN=I_APPROVE_AND_RUN_FINAL_LIVE_HEALTHCHECK APPROVED_BY=Anan FINAL_GO_LIVE_OUTPUT=summary ops/local/final-go-live-approve-and-run-from-tom-token.sh approve-and-run`。
- 本轮仍未执行 approval `approve`、未打开 live gate、未调用 managed action live API、未修改或重启任何 OpenClaw 实例。

## 阶段完成后的下一步

若要完成最终 live healthcheck 验收，需要 Anan 审查当前证据包后显式运行 `approve-and-run`。若暂不进入 live 演练，则下一步优先处理 deepseek heartbeat 根因，避免继续周期性消耗 token。

## 本轮新增（heartbeat burn 只读复核入口）

- 已新增 `ops/tom-readonly/heartbeat-burn-inspector.sh`，用于把页面上的“异常用量线索”变成 Tom 侧可重复执行的命令行复核入口。
- 支持 `status [instanceId]` 和 `check [instanceId]`；`status` 适合人工查看，`check` 发现可疑用量时返回非 0，后续可接告警。
- 脚本只读取 `runtime/collectors/tom-oracle/history.json` 与只读挂载中的 `HEARTBEAT.md` 元数据，不调用模型、不清空 heartbeat、不写 OpenClaw 实例目录、不重启实例、不调用 managed action live API。
- 已新增 `test/heartbeat-burn-inspector.test.ts`，覆盖周期性小额 token 增长识别、`check` 非 0 退出码和跳过 heartbeat 元数据读取三种路径。
- 已更新 `ops/tom-readonly/README.md` 和 `docs/FAQ.md`，记录 deepseek 这类 heartbeat/定时轮询消耗的排查命令与处理原则。
- 已验证 `bash -n ops/tom-readonly/heartbeat-burn-inspector.sh`。
- 已验证 `npm test -- test/heartbeat-burn-inspector.test.ts`，3/3 通过。
- 已验证 `npm test -- test/heartbeat-burn-inspector.test.ts test/oss-readiness.test.ts`，10/10 通过。
- 已验证 `npm run build`。
- 已提交并推送 `2eeda20 ops: add heartbeat burn inspector`。
- 已部署到 Tom，`update.sh` 通过，5 个 OpenClaw gateway 健康端口、总览页、实例详情页、只读写接口拦截、容器安全边界和 collector 快照均通过。
- 已在 Tom 执行 `repo/ops/tom-readonly/heartbeat-burn-inspector.sh status deepseek`，返回 `suspicious_usage_detected`，`deepseek` 信号为 `periodic_small_growth`。
- Tom 实测 deepseek 窗口 token 增量为 `13683`，最近增量为 `174`，中位增量为 `281`，中位间隔约 `30` 分钟。
- Tom 实测 deepseek heartbeat 元数据：`/instances/deepseek/workspace/HEARTBEAT.md`，大小 `226` bytes，`nonEmpty=true`，首个非空行为 markdown 代码块标记，更新时间 `2026-05-08T16:03:52.414Z`。
- 本轮没有清空 `/srv/openclaw-deepseek/workspace/HEARTBEAT.md`，没有修改或重启任何 OpenClaw 实例。

## 阶段完成后的下一步

当前已确认 deepseek 的异常消耗与非空 `HEARTBEAT.md` 高度相关。下一步有两个分支：如果要先止损，需要 Anan 明确批准后再清空或关闭 deepseek 的 `/srv/openclaw-deepseek/workspace/HEARTBEAT.md`；如果要先完成控制中心最终上线，则审查证据包并显式运行 `approve-and-run`。在获得明确批准前，仍不得修改实例 workspace、不得执行 approval `approve`、不得打开 live gate、不得触发真实 managed action。

## 本轮新增（heartbeat burn 告警 cron）

- 已新增 `ops/tom-readonly/heartbeat-burn-alert-runner.sh`，把只读 inspector 的结果写入 control-center runtime。
- `heartbeat-burn-alert-runner.sh run` 会生成 `runtime/heartbeat-burn-alerts/latest.json`；发现可疑增长时追加 `runtime/heartbeat-burn-alerts/events.ndjson`，并以非 0 退出，方便 cron 或外部监控识别。
- 已新增 `ops/tom-readonly/install-heartbeat-burn-alert-cron.sh`，用于安装当前用户 crontab 的 `OPENCLAW_HEARTBEAT_BURN_ALERT_CRON` 受控块。
- `install-heartbeat-burn-alert-cron.sh status/plan` 只读 crontab；`apply/remove` 必须设置 `CONFIRM_HEARTBEAT_BURN_ALERT_CRON=I_UNDERSTAND_THIS_ONLY_INSTALLS_READONLY_HEARTBEAT_BURN_ALERT_CRON`。
- 告警 cron 默认每 15 分钟检查全部实例，也可设置 `HEARTBEAT_BURN_ALERT_INSTANCE_IDS="deepseek"` 聚焦单实例。
- 该链路只写 control-center runtime 与当前用户 crontab，不写 OpenClaw 实例目录、不清空 `HEARTBEAT.md`、不调用模型、不重启实例、不调用 managed action live API、不打开 live gate。
- 已新增 `test/heartbeat-burn-alert-cron.test.ts`，覆盖 runner 写告警报告、无异常 clear 状态、cron plan 不写 crontab、apply 确认与 remove。
- 已验证 `bash -n ops/tom-readonly/heartbeat-burn-alert-runner.sh ops/tom-readonly/install-heartbeat-burn-alert-cron.sh`。
- 已验证 `npm test -- test/heartbeat-burn-alert-cron.test.ts`，4/4 通过。
- 已验证 `npm test -- test/heartbeat-burn-alert-cron.test.ts test/heartbeat-burn-inspector.test.ts test/oss-readiness.test.ts`，14/14 通过。
- 已验证 `npm run build`。
- 已提交并推送 `0286f21 ops: add heartbeat burn alert cron`。
- 已部署到 Tom，`update.sh` 通过，5 个 OpenClaw gateway 健康端口、总览页、实例详情页、只读写接口拦截、容器安全边界和 collector 快照均通过。
- Tom 告警 cron 已安装，`install-heartbeat-burn-alert-cron.sh status` 返回 `heartbeat_burn_alert_cron_installed`、`needsUpdate=false`，计划为每 15 分钟检查全部实例。
- 已在 Tom 手动执行 `heartbeat-burn-alert-runner.sh run` 做 smoke；返回码为 `2`，这是“发现异常”的预期告警语义。
- 本次告警 smoke 写入 `/srv/openclaw-control-center-readonly/runtime/heartbeat-burn-alerts/latest.json` 并追加 `events.ndjson`。
- 本次告警 smoke 发现 2 个可疑实例：`deepseek` 为 `periodic_small_growth`，`spark` 为 `recent_spike`；两者 `HEARTBEAT.md` 均为非空，大小均为 `226` bytes。
- Tom 告警 smoke 安全字段确认 `writesOpenClawInstanceDirs=false`、`clearsHeartbeatFiles=false`、`callsModelApis=false`、`restartsOpenClawInstances=false`、`callsManagedActionsLiveApi=false`、`opensLiveGate=false`。
- 安装 heartbeat 告警 cron 后，发现旧的 dry-run inbox cron 状态误报 `inbox_cron_needs_update`；根因是 installer 用“整个 crontab 文本完全相等”判断更新，新增第二个受控块后会因块顺序变化误判。
- 已修复 `install-managed-action-inbox-cron.sh` 与 `install-heartbeat-burn-alert-cron.sh`：`status/plan` 现在只比较各自的受控块内容，不会因为另一个受控 cron 块存在而互相误报。
- 已补回归测试，覆盖 managed-action inbox cron 与 heartbeat burn alert cron 共存时各自 `needsUpdate=false`，且 remove 只移除自己的受控块。
- 已验证 `npm test -- test/managed-action-inbox-cron.test.ts test/heartbeat-burn-alert-cron.test.ts test/oss-readiness.test.ts`，15/15 通过。
- 已验证 `npm run build`。
- 已提交并推送 `3af80ea fix: keep managed cron blocks independent`。
- 已部署到 Tom，`update.sh` 通过，5 个 OpenClaw gateway 健康端口、总览页、实例详情页、只读写接口拦截、容器安全边界和 collector 快照均通过。
- Tom 当前 `install-managed-action-inbox-cron.sh status` 返回 `inbox_cron_installed`、`needsUpdate=false`。
- Tom 当前 `install-heartbeat-burn-alert-cron.sh status` 返回 `heartbeat_burn_alert_cron_installed`、`needsUpdate=false`。
- 已重新执行 `FINAL_GO_LIVE_OUTPUT=summary OPENCLAW_TOPOLOGY_MODE=local-only ops/local/final-go-live-runner.sh prepare`，返回 `prepared_waiting_human_approval`。
- 当前最终上线边界：`readiness=waiting_human_approval`、`approvalPacket=ready`、`approval=needs_manual_approval`、`inboxPendingCount=0`，安全字段仍为 `opensLiveGate=false`、`callsManagedActionsLiveApi=false`、`writesOpenClawInstanceDirs=false`、`restartsOpenClawInstances=false`。

## 阶段完成后的下一步

当前已停在最终 live healthcheck 人工批准前。下一步只有两个人工分支：一是 Anan 审查证据包后显式运行 `approve-and-run` 完成最终 live healthcheck 验收；二是先处理 `deepseek` 与 `spark` 的非空 `HEARTBEAT.md`。在 Anan 明确批准前，仍不得清空这些文件，也不得执行 approval `approve` 或打开 live gate。

## 本轮新增（最终上线人工审查摘要）

- 已新增 `ops/local/final-go-live-review.sh`，作为本机侧最终上线人工批准前的短摘要入口。
- `final-go-live-review.sh status` 只读 SSH 到 Tom，汇总 Tom commit、live healthcheck readiness、approval packet、approval、dry-run inbox cron、heartbeat burn alert cron 和最新 heartbeat/token 告警。
- readiness、approval packet、approval 与两个 cron 都就绪，但仍存在 heartbeat/token 告警时，脚本返回 `ready_for_human_approval_with_usage_alerts`，把异常用量作为 warning，而不是自动阻断最终 live healthcheck 审查。
- 该脚本不写 Tom runtime、不写 approval 文件、不打开 live gate、不调用 managed action live API、不修改 OpenClaw 实例目录、不清空 `HEARTBEAT.md`、不重启实例。
- 已新增 `test/final-go-live-review.test.ts`，覆盖就绪但有用量告警、dry-run inbox cron 未就绪时阻断两条路径，并断言不调用 approval 与 live API。
- 已更新 `ops/tom-readonly/README.md`、`docs/MULTI_INSTANCE_READONLY.md`、`docs/FAQ.md`、`implementation_plan.md` 与 `test/oss-readiness.test.ts`。
- 已验证 `bash -n ops/local/final-go-live-review.sh`。
- 已验证 `npm test -- test/final-go-live-review.test.ts`，2/2 通过。
- 已验证 `npm test -- test/final-go-live-review.test.ts test/final-go-live-runner.test.ts test/managed-action-inbox-cron.test.ts test/heartbeat-burn-alert-cron.test.ts test/oss-readiness.test.ts`，30/30 通过。
- 已验证 `npm run build`。
- 已提交并推送 `9bac0f4 ops: add final go-live review summary`。
- 已部署到 Tom，`update.sh` 通过，5 个 OpenClaw gateway 健康端口、总览页、实例详情页、只读写接口拦截、容器安全边界和 collector 快照均通过。
- 部署后第一次并行 review smoke 正确发现 approval packet commit mismatch 并阻断；随后执行 `final-go-live-runner.sh prepare` 刷新证据包到当前 Tom commit。
- 刷新后真实只读 review smoke 返回 `ready_for_human_approval_with_usage_alerts`：`tomHead=9bac0f4`、`readiness=waiting_human_approval`、`approvalPacket=ready`、`approval=needs_manual_approval`、`dryRunInboxCron=inbox_cron_installed needsUpdate=false`、`heartbeatBurnAlertCron=heartbeat_burn_alert_cron_installed needsUpdate=false`。
- review smoke 仍提示 heartbeat/token 告警当前存在 2 个可疑实例；安全字段确认 `writesTomRuntime=false`、`writesApprovalFile=false`、`writesOpenClawInstanceDirs=false`、`clearsHeartbeatFiles=false`、`opensLiveGate=false`、`callsManagedActionsLiveApi=false`、`callsModelApis=false`。

## 阶段完成后的下一步

当前 Tom 已到人工批准前短摘要就绪状态。下一步仍是人工分支：Anan 审查摘要和证据包后显式运行 `approve-and-run`，或先人工处理 heartbeat/token 告警中的可疑实例。

## 本轮新增（completion audit 告警分类收口）

- 已调整 `ops/local/final-go-live-completion-audit.sh`：`usage_alerts_review` 在存在 heartbeat/token 告警时显示为 `warning`，不再和最终 live healthcheck 的人工批准 pending 混在一起。
- 已新增未来完成态 `completed_with_warnings`：如果最终 live healthcheck 已完成但仍有用量告警，审计会明确显示“完成但有 warning”，不会误报为无风险完成。
- summary 输出现在为 `pass / warning / pending / fail`。
- 已通过真实 Tom 只读审计确认当前状态为 `blocked_human_approval_required`：5/7 pass，1 warning，1 pending，0 failed。
- 当前唯一硬阻塞仍是 `final_live_healthcheck` 需要 Anan 显式 `approve-and-run`；`deepseek` 与 `spark` 的 heartbeat/token 告警是人工复核 warning。
- 本次没有执行 approval、没有打开 live gate、没有调用 managed action live API、没有修改 OpenClaw 实例目录、没有清空 `HEARTBEAT.md`、没有重启任何 OpenClaw 实例。

## 本轮新增（最终上线完成度审计）

- 已新增 `ops/local/final-go-live-completion-audit.sh`，用于只读审计当前目标完成度，避免把“人工批准前”误判为“已完成”。
- 该脚本会运行 `final-go-live-review.sh status`，并让 Tom 执行 `./healthcheck.sh`，然后把目标拆成 `pass / warning / pending / fail`。
- 审计条目包括 Tom 单 Oracle 多实例只读健康、dry-run 管理链路、监控告警、approval packet、运维文档、heartbeat/token 告警人工复核、最终 live healthcheck 一次性验收。
- 当技术前置项就绪但最终 live healthcheck 尚未人工批准执行时，脚本返回 `blocked_human_approval_required`。
- 当 Tom healthcheck 或 cron/readiness 前置条件失败时，脚本返回 `blocked_preconditions`。
- 该脚本不写 Tom runtime、不写 approval 文件、不修改 OpenClaw 实例目录、不清空 `HEARTBEAT.md`、不重启实例、不打开 live gate、不调用 managed action live API。
- 已新增 `test/final-go-live-completion-audit.test.ts`，覆盖人工 approval 为唯一硬阻塞、Tom healthcheck 失败时阻断两条路径，并断言不调用 approval 或 live API。
- 已验证 `bash -n ops/local/final-go-live-completion-audit.sh`。
- 已验证 `npm test -- test/final-go-live-completion-audit.test.ts`，2/2 通过。
- 已验证 `npm test -- test/final-go-live-completion-audit.test.ts test/final-go-live-review.test.ts test/final-go-live-runner.test.ts test/oss-readiness.test.ts`，24/24 通过。
- 已验证 `npm run build`。
- 已提交并推送 `f14aa9d ops: add final go-live completion audit`。
- 已部署到 Tom，`update.sh` 通过，5 个 OpenClaw gateway 健康端口、总览页、实例详情页、只读写接口拦截、容器安全边界和 collector 快照均通过。
- 部署后第一次并行 audit smoke 正确发现 approval packet commit mismatch 并阻断；随后执行 `final-go-live-runner.sh prepare` 刷新证据包到当前 Tom commit。
- 刷新后真实只读 completion audit smoke 返回 `blocked_human_approval_required`：5/7 pass，1 warning，1 pending，0 failed。
- 已通过 completion audit 确认：Tom 只读健康、dry-run 管理链路、监控告警、approval packet、运维文档均为 pass；`usage_alerts_review` 为 warning；`final_live_healthcheck` 为 pending。
- 当前唯一硬阻塞是 `最终 live healthcheck 一次性验收: 需要 Anan 显式 approve-and-run`；heartbeat/token 告警仍作为 warning 人工复核项存在。
- audit smoke 安全字段确认 `writesTomRuntime=false`、`writesApprovalFile=false`、`writesOpenClawInstanceDirs=false`、`clearsHeartbeatFiles=false`、`opensLiveGate=false`、`callsManagedActionsLiveApi=false`、`callsModelApis=false`。

## 阶段完成后的下一步

当前可自动推进的部分已经再次收口到人工边界。下一步只能由 Anan 选择：运行 `approve-and-run` 完成最终 live healthcheck，或先处理 heartbeat/token 告警中的可疑实例。

## 本轮新增（deepseek gateway 稳定性阻塞）

- 已把 heartbeat/token warning 明细部署到 Tom，final review 现在能直接显示：`main(periodic_small_growth)`、`deepseek(periodic_small_growth)`、`spark(recent_spike)`。
- Tom `update.sh` 重建 control-center 容器成功，但健康检查曾被 `18795` 阻塞；只读诊断确认 `18795` 对应 `openclaw-deepseek-openclaw-gateway-1`。
- deepseek gateway 日志显示启动失败根因是 `DEEPSEEK_API_KEY` 缺失或为空；运行时检查与 `.env` 文件检查也确认该变量未设置。
- 没有修改、重启或停止任何 OpenClaw 实例；诊断只读取 Docker 状态、日志与健康端口。
- 已增强 `ops/tom-readonly/healthcheck.sh`：除 gateway 端口外，还会检查 gateway 容器 Docker health，避免把重启窗口中的短暂 `/health` 响应误判为稳定健康。
- 已调整 `ops/local/final-go-live-completion-audit.sh`：当前置项失败时，不再把最终 `approve-and-run` 放入 `nextCommands`。
- 当前上线阻塞从“人工批准”回退为“前置项未稳定”：需要先补齐 deepseek 实例的 `DEEPSEEK_API_KEY`，或由 Anan 明确批准临时移除/停用 deepseek 这个实例的健康纳入范围。
