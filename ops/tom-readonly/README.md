# Tom 多实例只读控制中心运维脚本

这组脚本服务于 Tom 上的灰度部署目录：

```bash
/srv/openclaw-control-center-readonly
```

它们只更新、检查和回滚 OpenClaw Control Center 自身，不会修改任何 OpenClaw 实例目录。实例目录必须继续以 `:ro` 方式挂载。

## 脚本

- `healthcheck.sh`：检查 gateway 容器 Docker health 与端口健康、总览页、实例详情页、写接口 403、容器只读安全边界，以及 collector 快照新鲜度。
- `collector-snapshot.sh`：在 Tom 本地生成 collector JSON 快照，只写控制中心 runtime，不修改任何 OpenClaw 实例目录。
- `install-collector-cron.sh`：幂等安装 Tom collector 快照定时任务，只更新 crontab 中的 OpenClaw 标记块。
- `remote-collector-onboarding.sh`：为第二台 Oracle 生成只读 collector 接入包，默认 `plan` 不写入，`write` 只写 control-center runtime 下的 onboarding 文件。
- `remote-collector-onboarding.example.json`：远端 collector 接入包配置样板。
- `remote-collector-credentials.sh`：把 Tom 本地可读的远端只读 SSH key 安装到 control-center runtime，并生成 onboarding 配置。
- `remote-collector-credentials.example.json`：远端凭据准备配置样板，不包含真实密钥内容。
- `remote-collector-preflight.sh`：对已生成的远端 collector 接入包执行 SSH 只读预检，检查 docker、目录和 gateway 前置条件。
- `remote-collector-node-sync.sh`：把已验证的 onboarding 接入包同步到远端 collector 节点目录，并可显式确认后执行远端 bootstrap plan/write。
- `remote-collector-rollout.sh`：只读取 Tom 本地接入包、preflight、pull 和 registry 状态，输出跨服务器只读接入下一步。
- `remote-collector-rollout-runner.sh`：按 rollout gate 当前阶段自动执行下一步安全脚本；缺凭据、远端 snapshot 未就绪或检查失败时停止。
- `go-live-gate.sh`：最终上线总闸门，默认 `OPENCLAW_TOPOLOGY_MODE=local-only`，汇总 Tom 本机实例 healthcheck、dry-run 证据和 live 管理动作 readiness；显式 `cross-server` 时才把远端 collector 接入作为阻塞项。
- `remote-collector-pull.sh`：从其他 Oracle 服务器只读拉取已经生成好的 collector JSON，校验后写入本机 `runtime/collectors`。
- `remote-collector-pull.sources.example.json`：远端 collector 拉取配置样板，默认 `enabled=false`。
- `register-local-instance.sh`：把当前 Oracle 上的新 OpenClaw 实例注册到 Tom `config/instances.json`，并在 `docker-compose.yml` 中加入只读挂载；默认 `plan` 不写入。
- `register-local-instance.example.json`：本机实例注册配置样板。
- `register-remote-collector.sh`：把已经拉取并校验过的远端 collector snapshot 注册到 Tom `config/instances.json`，默认 `plan` 不写入。
- `register-remote-collector.example.json`：远端 collector 注册配置样板。
- `update.sh`：拉取 `multi-instance-readonly-control-center` 分支，同步部署目录根部 `healthcheck.sh`，重建控制中心容器，随后执行健康检查。
- `rollback.sh`：回滚到指定提交并同步对应版本的 `healthcheck.sh`；如果不传提交，则使用最近一次 `update.sh` 记录的 `previous-good.commit`。
- `../local/discover-remote-oracle-credentials.sh`：在本机只读发现第二台 Oracle 的候选 SSH host/key，`probe` 需显式确认且只执行只读 SSH 探测；拿到明确 host/key 后可用 `write-push-config` 只写本机 push 配置。
- `../local/discover-remote-oracle-credentials.example.json`：本机候选发现配置样板，不包含真实密钥内容。
- `../local/remote-oracle-intake.sh`：本机侧凭据接入编排器；`doctor/plan` 不写文件不联网，`apply` 显式确认后只写本机 push 配置和 Tom control-center runtime，`run` 会继续触发 Tom 端安全 rollout。
- `../local/final-go-live-status.sh`：本机侧最终上线状态汇总入口；默认 `local-only`，`status/check` 读取 Tom `go-live-gate.sh`，不写本机 push 配置、不写 Tom runtime、不连接第二台 Oracle。
- `../local/final-go-live-runner.sh`：本机侧最终上线推进 runner；`prepare` 可自动推进到 Tom 人工批准前，`run-approved` 必须显式确认和本地令牌，并继续交给 Tom runner 校验 approval/readiness；`approve-and-run` 先执行只读 approval review，只有 review 已到 `ready_for_human_approval` 且强确认、批准人、本地令牌齐全时，才记录 approval 并执行一次性演练；`verify-completed` 只读复核演练报告、approval 消费和只读恢复状态。
- `../local/final-go-live-approve-and-run-from-tom-token.sh`：本机侧最终批准包装器；`status` 只读检查 Tom 容器 token 长度和 approval review 状态，不打印 token、不执行 approval；`approve-and-run` 必须显式设置 `CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN` 和 `APPROVED_BY`，然后从 Tom control-center 容器环境读取 `LOCAL_API_TOKEN` 到子进程，不打印、不落盘，并交给既有 `final-go-live-runner.sh approve-and-run`。
- `../local/push-remote-collector-credentials.sh`：在本机把远端只读 SSH key 和 onboarding 配置推送到 Tom control-center runtime，不连接第二台 Oracle。
- `managed-action-healthcheck-rollout.example.json`：只读 healthcheck live 演练的 rollout 样板，不会被默认加载。
- `managed-action-dry-run-gate.sh`：管理动作 dry-run 证据闸门，默认只读检查 readiness 与 audit，显式确认后只创建 dry-run 审计记录。
- `live-healthcheck-approval.sh`：生成、校验或标记 live healthcheck 人工批准记录，不调用 live API。
- `live-healthcheck-approval.example.json`：批准记录样板，默认未批准。
- `live-healthcheck-approval-packet.sh`：生成 live healthcheck 批准前证据包，汇总总闸门、dry-run、approval、live window 状态和影响快照。
- `live-healthcheck-readiness.sh`：只读汇总 live healthcheck 演练 readiness；不生成证据包、不写 approval、不打开 live gate。
- `live-healthcheck-rollout-runner.sh`：自动推进 live 演练阶段；`status` 只读，`prepare` 会准备 approval 模板、生成/校验证据包并刷新 readiness，`run-approved` 只在人工 approval 已批准且显式确认后执行一次性演练窗口，`verify-completed` 只读验收演练报告与恢复状态。
- `live-healthcheck-preflight.sh`：只读检查 healthcheck live 演练条件，不调用 live API。
- `live-healthcheck-smoke.sh`：手动 live healthcheck 演练脚本；只有显式提供本地令牌和确认环境变量才会调用 live API。
- `live-healthcheck-report.sh`：演练报告脚本；读取 approval、impact snapshots 和 operation audit，生成 JSON 与 Markdown 报告。
- `live-healthcheck-window.sh`：一次性演练窗口脚本；临时启用 control-center 的 healthcheck live 配置，失败或结束后恢复只读状态。
- `instance-impact-snapshot.sh`：演练前后实例影响留证脚本；只读取 gateway、监听端口、容器挂载和 readiness。
- `managed-action-text-bridge.sh`：给 OpenClaw/Discord 机器人使用的文本桥接层；把机器人文本写入 control-center runtime，再调用 `managed-action-command-runner.sh parse-text/plan-text/dry-run-text`，输出精简摘要。
- `managed-action-inbox-runner.sh`：读取 OpenClaw workspace 中的文本请求 inbox，调用文本桥接层，并把结果和处理状态只写入 control-center runtime；`run-pending` 可一次处理多个待处理 dry-run 请求。
- `install-managed-action-inbox-cron.sh`：安装 dry-run inbox 批处理定时器；`status/plan` 不写 crontab，`apply/remove` 必须显式确认，只更新当前用户 crontab 中的受控标记块。
- `install-managed-action-agents-instructions.sh`：把 Tom `AGENTS.md` 中的 control-center inbox 使用规范安装为受控标记块；`plan/status` 不写文件，`apply` 必须显式确认并备份原文件。
- `heartbeat-burn-inspector.sh`：只读分析 collector history 中的 token 增量节奏，并可通过 control-center 容器只读查看对应实例 `HEARTBEAT.md` 元数据；用于定位 deepseek 这类 heartbeat/定时轮询消耗，不会清空文件或修改实例。
- `heartbeat-burn-alert-runner.sh`：调用只读 inspector，并把异常用量告警结果写入 control-center runtime；不修改实例、不调用模型。
- `install-heartbeat-burn-alert-cron.sh`：安装 heartbeat/token 异常用量告警定时器；`status/plan` 不写 crontab，`apply/remove` 必须显式确认，只更新当前用户 crontab 中的受控标记块。

## Tom 上的常用命令

```bash
cd /srv/openclaw-control-center-readonly
./healthcheck.sh
./collector-snapshot.sh
./install-collector-cron.sh
repo/ops/tom-readonly/remote-collector-onboarding.sh plan runtime/remote-collector-onboarding.json
repo/ops/tom-readonly/remote-collector-credentials.sh plan runtime/remote-collector-credentials.json
CONFIRM_REMOTE_COLLECTOR_CREDENTIALS=I_UNDERSTAND_THIS_ONLY_WRITES_CONTROL_CENTER_REMOTE_CREDENTIALS \
repo/ops/tom-readonly/remote-collector-credentials.sh apply runtime/remote-collector-credentials.json
CONFIRM_REMOTE_COLLECTOR_ONBOARDING=I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_ONBOARDING_BUNDLE \
repo/ops/tom-readonly/remote-collector-onboarding.sh write runtime/remote-collector-onboarding.json
repo/ops/tom-readonly/remote-collector-onboarding.sh verify runtime/remote-onboarding/<serverId>
repo/ops/tom-readonly/remote-collector-preflight.sh plan runtime/remote-onboarding/<serverId>
CONFIRM_REMOTE_COLLECTOR_PREFLIGHT=I_UNDERSTAND_THIS_ONLY_READS_REMOTE_PREREQUISITES \
repo/ops/tom-readonly/remote-collector-preflight.sh check runtime/remote-onboarding/<serverId>
repo/ops/tom-readonly/remote-collector-preflight.sh status runtime/remote-onboarding/<serverId>
repo/ops/tom-readonly/remote-collector-node-sync.sh plan runtime/remote-onboarding/<serverId>
CONFIRM_REMOTE_COLLECTOR_NODE_SYNC=I_UNDERSTAND_THIS_ONLY_COPIES_COLLECTOR_BUNDLE_TO_REMOTE \
repo/ops/tom-readonly/remote-collector-node-sync.sh sync runtime/remote-onboarding/<serverId>
CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_PLAN=I_UNDERSTAND_THIS_ONLY_RUNS_REMOTE_BOOTSTRAP_PLAN \
repo/ops/tom-readonly/remote-collector-node-sync.sh bootstrap-plan runtime/remote-onboarding/<serverId>
CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_WRITE=I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_COLLECTOR_NODE_FILES \
repo/ops/tom-readonly/remote-collector-node-sync.sh bootstrap-write runtime/remote-onboarding/<serverId>
CONFIRM_REMOTE_COLLECTOR_NODE_SNAPSHOT=I_UNDERSTAND_THIS_RUNS_REMOTE_COLLECTOR_SNAPSHOT_ONLY \
repo/ops/tom-readonly/remote-collector-node-sync.sh snapshot runtime/remote-onboarding/<serverId>
CONFIRM_REMOTE_COLLECTOR_NODE_CRON=I_UNDERSTAND_THIS_ONLY_INSTALLS_REMOTE_COLLECTOR_CRON \
repo/ops/tom-readonly/remote-collector-node-sync.sh install-cron runtime/remote-onboarding/<serverId>
repo/ops/tom-readonly/remote-collector-rollout.sh status runtime/remote-onboarding/<serverId>
repo/ops/tom-readonly/remote-collector-rollout-runner.sh status runtime/remote-onboarding/<serverId>
CONFIRM_REMOTE_COLLECTOR_ROLLOUT_RUNNER=I_UNDERSTAND_THIS_RUNS_SAFE_REMOTE_COLLECTOR_ROLLOUT_STEPS \
repo/ops/tom-readonly/remote-collector-rollout-runner.sh run runtime/remote-onboarding/<serverId>
repo/ops/tom-readonly/go-live-gate.sh status runtime/remote-onboarding/<serverId>
repo/ops/tom-readonly/go-live-gate.sh check runtime/remote-onboarding/<serverId>
OPENCLAW_TOPOLOGY_MODE=cross-server repo/ops/tom-readonly/go-live-gate.sh check runtime/remote-onboarding/<serverId>
repo/ops/tom-readonly/managed-action-dry-run-gate.sh status
repo/ops/tom-readonly/remote-collector-pull.sh plan runtime/remote-collector-pull.sources.json
CONFIRM_REMOTE_COLLECTOR_PULL=I_UNDERSTAND_THIS_ONLY_READS_REMOTE_COLLECTOR_SNAPSHOTS \
repo/ops/tom-readonly/remote-collector-pull.sh pull runtime/remote-collector-pull.sources.json
repo/ops/tom-readonly/remote-collector-pull.sh status runtime/remote-collector-pull.sources.json
cp repo/ops/tom-readonly/register-local-instance.example.json runtime/register-local-instance.json
repo/ops/tom-readonly/register-local-instance.sh plan runtime/register-local-instance.json
CONFIRM_LOCAL_INSTANCE_REGISTER=I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_LOCAL_REGISTRY \
repo/ops/tom-readonly/register-local-instance.sh apply runtime/register-local-instance.json
repo/ops/tom-readonly/register-remote-collector.sh plan runtime/register-remote-collector.json
CONFIRM_REMOTE_COLLECTOR_REGISTER=I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_REGISTRY \
repo/ops/tom-readonly/register-remote-collector.sh apply runtime/register-remote-collector.json
./update.sh
./rollback.sh <commit>
repo/ops/tom-readonly/live-healthcheck-approval.sh prepare runtime/live-healthcheck-approval.json
repo/ops/tom-readonly/live-healthcheck-approval.sh status runtime/live-healthcheck-approval.json
repo/ops/tom-readonly/live-healthcheck-approval.sh check runtime/live-healthcheck-approval.json
repo/ops/tom-readonly/live-healthcheck-approval.sh consume runtime/live-healthcheck-approval.json
repo/ops/tom-readonly/live-healthcheck-approval-packet.sh generate
repo/ops/tom-readonly/live-healthcheck-approval-packet.sh check
repo/ops/tom-readonly/live-healthcheck-readiness.sh status
repo/ops/tom-readonly/live-healthcheck-readiness.sh check
repo/ops/tom-readonly/live-healthcheck-rollout-runner.sh status
repo/ops/tom-readonly/live-healthcheck-rollout-runner.sh prepare
repo/ops/tom-readonly/managed-action-command-runner.sh status
repo/ops/tom-readonly/managed-action-command-runner.sh plan runtime/managed-action-command.json
printf '对 tom 运行 zhihu-human-ops-writing dry-run\n' > runtime/managed-action-command.txt
repo/ops/tom-readonly/managed-action-command-runner.sh parse-text runtime/managed-action-command.txt
repo/ops/tom-readonly/managed-action-command-runner.sh plan-text runtime/managed-action-command.txt
repo/ops/tom-readonly/managed-action-text-bridge.sh parse runtime/managed-action-command.txt
repo/ops/tom-readonly/managed-action-text-bridge.sh plan runtime/managed-action-command.txt
CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CALLS_MANAGED_ACTION_DRY_RUN_API \
LOCAL_API_TOKEN=<本地令牌> \
repo/ops/tom-readonly/managed-action-command-runner.sh dry-run runtime/managed-action-command.json
# 如果 LOCAL_API_TOKEN 只在 control-center 容器里：
CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CALLS_MANAGED_ACTION_DRY_RUN_API \
MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container \
repo/ops/tom-readonly/managed-action-command-runner.sh dry-run-text runtime/managed-action-command.txt
CONFIRM_MANAGED_ACTION_TEXT_BRIDGE=I_UNDERSTAND_THIS_ONLY_RUNS_MANAGED_ACTION_DRY_RUN_TEXT \
MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container \
repo/ops/tom-readonly/managed-action-text-bridge.sh dry-run runtime/managed-action-command.txt
MANAGED_ACTION_INBOX_SOURCE=control-center-container \
MANAGED_ACTION_INBOX_DIR=/instances/tom/workspace/control-center-commands/inbox \
repo/ops/tom-readonly/managed-action-inbox-runner.sh status
MANAGED_ACTION_INBOX_SOURCE=control-center-container \
MANAGED_ACTION_INBOX_DIR=/instances/tom/workspace/control-center-commands/inbox \
repo/ops/tom-readonly/managed-action-inbox-runner.sh plan-next
repo/ops/tom-readonly/install-managed-action-agents-instructions.sh status
repo/ops/tom-readonly/install-managed-action-agents-instructions.sh plan
CONFIRM_MANAGED_ACTION_AGENTS_INSTALL=I_UNDERSTAND_THIS_UPDATES_TOM_AGENTS_INSTRUCTIONS_ONLY \
MANAGED_ACTION_AGENTS_TARGET_SOURCE=openclaw-container \
repo/ops/tom-readonly/install-managed-action-agents-instructions.sh apply
CONFIRM_MANAGED_ACTION_INBOX_RUNNER=I_UNDERSTAND_THIS_READS_OPENCLAW_INBOX_AND_RUNS_DRY_RUN_TEXT \
MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container \
MANAGED_ACTION_INBOX_SOURCE=control-center-container \
MANAGED_ACTION_INBOX_DIR=/instances/tom/workspace/control-center-commands/inbox \
repo/ops/tom-readonly/managed-action-inbox-runner.sh run-next
CONFIRM_MANAGED_ACTION_INBOX_RUNNER=I_UNDERSTAND_THIS_READS_OPENCLAW_INBOX_AND_RUNS_DRY_RUN_TEXT \
MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container \
MANAGED_ACTION_INBOX_SOURCE=control-center-container \
MANAGED_ACTION_INBOX_DIR=/instances/tom/workspace/control-center-commands/inbox \
MANAGED_ACTION_INBOX_MAX_PER_RUN=10 \
repo/ops/tom-readonly/managed-action-inbox-runner.sh run-pending
repo/ops/tom-readonly/install-managed-action-inbox-cron.sh status
repo/ops/tom-readonly/install-managed-action-inbox-cron.sh plan
CONFIRM_MANAGED_ACTION_INBOX_CRON=I_UNDERSTAND_THIS_ONLY_INSTALLS_DRY_RUN_INBOX_CRON \
repo/ops/tom-readonly/install-managed-action-inbox-cron.sh apply
repo/ops/tom-readonly/heartbeat-burn-inspector.sh status
repo/ops/tom-readonly/heartbeat-burn-inspector.sh status deepseek
repo/ops/tom-readonly/heartbeat-burn-inspector.sh check deepseek
repo/ops/tom-readonly/heartbeat-burn-alert-runner.sh status
repo/ops/tom-readonly/heartbeat-burn-alert-runner.sh run
repo/ops/tom-readonly/install-heartbeat-burn-alert-cron.sh status
repo/ops/tom-readonly/install-heartbeat-burn-alert-cron.sh plan
CONFIRM_HEARTBEAT_BURN_ALERT_CRON=I_UNDERSTAND_THIS_ONLY_INSTALLS_READONLY_HEARTBEAT_BURN_ALERT_CRON \
repo/ops/tom-readonly/install-heartbeat-burn-alert-cron.sh apply
CONFIRM_LIVE_HEALTHCHECK_RUNNER=I_UNDERSTAND_THIS_RUNS_APPROVED_LIVE_HEALTHCHECK \
LOCAL_API_TOKEN=<本地令牌> \
repo/ops/tom-readonly/live-healthcheck-rollout-runner.sh run-approved
ops/local/final-go-live-runner.sh status
ops/local/final-go-live-runner.sh prepare
ops/local/final-go-live-review.sh status
ops/local/final-go-live-completion-audit.sh status
CONFIRM_FINAL_GO_LIVE_RUNNER=I_UNDERSTAND_THIS_RUNS_APPROVED_FINAL_GO_LIVE \
LOCAL_API_TOKEN=<本地令牌> \
ops/local/final-go-live-runner.sh run-approved
CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN=I_APPROVE_AND_RUN_FINAL_LIVE_HEALTHCHECK \
APPROVED_BY=Anan \
LOCAL_API_TOKEN=<本地令牌> \
ops/local/final-go-live-runner.sh approve-and-run
ops/local/final-go-live-runner.sh verify-completed
repo/ops/tom-readonly/live-healthcheck-rollout-runner.sh verify-completed
repo/ops/tom-readonly/live-healthcheck-window.sh status
repo/ops/tom-readonly/instance-impact-snapshot.sh snapshot readonly-baseline
```

如果需要临时覆盖默认值，可以使用环境变量：

```bash
BASE_URL=http://127.0.0.1:4311 INSTANCE_IDS="main tom third deepseek spark" ./healthcheck.sh
SERVER_ID=tom-oracle OUTPUT_PATH=/app/runtime/collectors/tom-oracle/snapshot.json ./collector-snapshot.sh
OPENCLAW_COLLECTOR_CRON_SCHEDULE="*/2 * * * *" ./install-collector-cron.sh
COLLECTOR_SNAPSHOT_MAX_AGE_SECONDS=300 ./healthcheck.sh
BRANCH=multi-instance-readonly-control-center ./update.sh
```

`ops/local/final-go-live-runner.sh prepare` 是给 openclaw 调用的本机侧总 runner：它先执行 `final-go-live-status.sh check`，只有当总闸门下一步是 Tom `live-healthcheck-rollout-runner.sh prepare` 时，才 SSH 到 Tom 准备 approval 模板和批准前证据包，然后重新检查最终状态并停在人工批准前。如果总闸门仍提示 `prepare`，本机 runner 会先只读询问 Tom runner 当前 readiness；已经处在人工批准边界或已批准待执行边界时，重复执行 `prepare` 会幂等返回当前边界，不会再次写 Tom runtime。到达人工批准边界后，`prepare` 还会只读执行 Tom `live-healthcheck-approval-review.sh check`，并把 `approve-and-run` 单命令作为下一步；如果 review 不 ready，则在批准前阻断。它不会批准 approval、不会打开 live gate、不会调用 managed action live API。`run-approved` 还必须显式设置 `CONFIRM_FINAL_GO_LIVE_RUNNER` 和 `LOCAL_API_TOKEN`，并会继续交给 Tom runner 再校验 approval/readiness。`approve-and-run` 是人工批准后的单命令入口：先运行 Tom `live-healthcheck-approval-review.sh check`，只在 `ready_for_human_approval` 时用 `APPROVED_BY` 写入 approval，再调用原 `run-approved` 链路；未确认、未提供批准人/令牌、review 未 ready 时都会在批准前阻断。`run-approved` 和 `approve-and-run` 成功后会自动调用 Tom `verify-completed`，要求最新报告通过、approval 已消费、只读状态已恢复；也可以单独运行本机 `verify-completed` 做演练后复核。

如果不想手工导出 `LOCAL_API_TOKEN`，可以在本机使用包装器。它仍然要求人工确认短语和批准人；缺少确认时不会连接 Tom。它只从 Tom 容器环境读取令牌到子进程，不打印、不写文件：

```bash
ops/local/final-go-live-approve-and-run-from-tom-token.sh status

CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN=I_APPROVE_AND_RUN_FINAL_LIVE_HEALTHCHECK \
APPROVED_BY=Anan \
FINAL_GO_LIVE_OUTPUT=summary \
ops/local/final-go-live-approve-and-run-from-tom-token.sh approve-and-run
```

`ops/local/final-go-live-review.sh status` 是人工批准前的短摘要入口。它只读 SSH 到 Tom，聚合 Tom commit、live healthcheck readiness、approval packet、approval、dry-run inbox cron、heartbeat burn alert cron 和最新 heartbeat 告警。它不会写 Tom runtime、不会批准 approval、不会打开 live gate、不会调用 live API、不会修改 OpenClaw 实例目录。`FINAL_GO_LIVE_OUTPUT=summary` 可输出更短的审批摘要；如果只剩 heartbeat/token 用量告警，它会返回 `ready_for_human_approval_with_usage_alerts`，把告警作为 warning 而不是自动阻断 live healthcheck 审查。

`ops/local/final-go-live-completion-audit.sh status` 是最终目标完成度审计入口。它只读运行 review，并让 Tom 执行 `./healthcheck.sh`，把目标拆成 Tom 只读健康、dry-run 管理链路、监控告警、approval packet、运维文档、heartbeat 告警人工复核、最终 live healthcheck 验收等条目。heartbeat/token 告警会作为 `warning` 展示，避免和真正阻塞上线的人工 approval 混在一起；当前如果只剩最终 live healthcheck 人工批准，它会返回 `blocked_human_approval_required`，明确指出最终 live healthcheck 仍是 pending，而不是误报完成。

`LOCAL_API_TOKEN` 是 control-center 本地 API 令牌。Tom 当前部署将它注入到 `openclaw-control-center-readonly` 容器环境中，而不是放在部署目录 `.env`。本机执行最终 live healthcheck 前，可从容器环境读取到当前 shell，命令本身不会打印真实 token：

```bash
export LOCAL_API_TOKEN="$(ssh -i ~/.ssh/oracle-oracle.key ubuntu@146.235.226.66 \
'docker inspect openclaw-control-center-readonly --format "{{range .Config.Env}}{{println .}}{{end}}" | sed -n "s/^LOCAL_API_TOKEN=//p"')"
python - <<'PY'
import os
print("LOCAL_API_TOKEN length =", len(os.environ.get("LOCAL_API_TOKEN", "")))
PY
```

`managed-action-command-runner.sh` 是给 OpenClaw/Discord 机器人调用的 dry-run 命令入口。`plan` 只读取命令 JSON 并校验字段，不联网、不写审计；`parse-text/plan-text` 会把“对 tom 运行 zhihu-human-ops-writing dry-run”这类文本解析成受控 payload，且要求文本必须明确包含 dry-run/预览/演练并拒绝 live、发布、重启、approval 等高风险词；`dry-run/dry-run-text` 必须设置 `CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN`，并通过 `LOCAL_API_TOKEN` 或显式 `MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container` 取得本地令牌，只调用 `/api/managed-actions/dry-run` 生成预览与审计记录，不打开 live gate、不执行实例命令。`skill_run` 命令必须带 `skillName`。服务端已经具备 `skill_run` 真实执行器，但 live 执行必须同时满足 live 白名单、rollout、dry-run 引用、确认短语，以及 `MANAGED_ACTIONS_LIVE_SKILL_RUN_ALLOWED_SKILLS` 和 `MANAGED_ACTIONS_LIVE_SKILL_RUN_ALLOWED_INSTANCES` 两层 allowlist；Tom 默认不配置这两个 allowlist，因此仍只允许 dry-run 预览。

`managed-action-text-bridge.sh` 是更适合机器人直接调用的一层封装。它可以接收 `<command.txt>`、标准输入、`MANAGED_ACTION_TEXT` 或 `MANAGED_ACTION_TEXT_FILE`，统一写入 `runtime/managed-action-command.txt`，再调用底层 runner 的 `parse-text`、`plan-text` 或 `dry-run-text`，最后返回包含 `runnerStatus`、`target`、`operationRequestId`、`commandPreview` 和安全字段的精简 JSON。`dry-run` 模式必须设置 `CONFIRM_MANAGED_ACTION_TEXT_BRIDGE=I_UNDERSTAND_THIS_ONLY_RUNS_MANAGED_ACTION_DRY_RUN_TEXT`；桥接层只会自动补齐底层 runner 的 dry-run 确认，不会打开 live gate、不修改 OpenClaw 实例目录、不重启实例。

`managed-action-inbox-runner.sh` 是 OpenClaw/Discord 真正接入时的安全收件箱。Tom 机器人只需要在自己的 workspace 写入一条 `.txt` 请求，例如 `/home/node/.openclaw/workspace/control-center-commands/inbox/001.txt`；control-center 通过只读挂载 `/instances/tom/workspace/control-center-commands/inbox` 读取它。`status` 只列出待处理请求；`plan-next` 只调用桥接层 `plan`，不标记处理；`run-next` 必须设置 `CONFIRM_MANAGED_ACTION_INBOX_RUNNER`，只调用桥接层 `dry-run`，并把处理状态和结果写到 `runtime/managed-action-inbox-runner/`。`run-pending` 同样必须显式确认，一次最多处理 `MANAGED_ACTION_INBOX_MAX_PER_RUN` 条待处理请求，适合后续接 cron 或手动一键处理，但仍只创建 dry-run 审计。`run-live-next` 是 dry-run 后的人工晋升入口：必须设置 `CONFIRM_MANAGED_ACTION_INBOX_LIVE_RUNNER=I_UNDERSTAND_THIS_PROMOTES_LATEST_INBOX_DRY_RUN_TO_SKILL_RUN_LIVE`，并同时具备底层 live 与 skill_run live 确认；它只读取最近一次尚未晋升过的成功 dry-run 结果，复用其中的 payload 与 `operationRequestId` 调用 `managed-action-command-runner.sh live`，已 live 的 dry-run 不会重复执行。该 runner 不移动、不删除、不修改 OpenClaw workspace 中的请求文件，不打开 live gate、不重启实例。

`install-managed-action-inbox-cron.sh` 用于把 `run-pending` 安装成当前用户 crontab 中的受控定时任务。`status/plan` 只读取 crontab 并展示将安装的 `OPENCLAW_MANAGED_ACTION_INBOX_CRON` 标记块；`apply/remove` 必须设置 `CONFIRM_MANAGED_ACTION_INBOX_CRON=I_UNDERSTAND_THIS_ONLY_INSTALLS_DRY_RUN_INBOX_CRON`。该 cron 只会执行 `managed-action-inbox-runner.sh run-pending`，不会打开 live gate、不会重启实例、不会修改 OpenClaw workspace 请求文件或实例目录。

`install-managed-action-agents-instructions.sh` 用于让 Tom 的 Discord 行为稳定落到上述 inbox。`status/plan` 会读取目标 `AGENTS.md` 并展示受控标记块是否需要更新；`apply` 必须设置 `CONFIRM_MANAGED_ACTION_AGENTS_INSTALL=I_UNDERSTAND_THIS_UPDATES_TOM_AGENTS_INSTRUCTIONS_ONLY`。Tom 上推荐用 `MANAGED_ACTION_AGENTS_TARGET_SOURCE=openclaw-container`，通过 `openclaw-work-openclaw-gateway-1` 容器只更新 `/home/node/.openclaw/workspace/AGENTS.md` 中的 `OPENCLAW_CONTROL_CENTER_MANAGED_ACTIONS` 标记块，并在同目录 `.backup/control-center-agents/` 下备份原文件。它不修改 `openclaw.json`、不重启 OpenClaw、不调用任何 managed action API。

`heartbeat-burn-inspector.sh` 是异常用量线索的命令行复核入口。它从 `runtime/collectors/tom-oracle/history.json` 读取实例 token 增量，识别“每隔几十分钟小额增长”的模式；默认还会通过 `openclaw-control-center-readonly` 容器只读读取 `/instances/<id>/workspace/HEARTBEAT.md` 的大小、非空状态和首个非空行。它只读元数据，不会清空 `HEARTBEAT.md`，不会写 OpenClaw 实例目录，不会调用模型，不会重启实例。`status` 适合人工查看；`check` 发现可疑增长时返回非 0，适合后续接告警。发现 deepseek 这类实例可疑后，先用 `status deepseek` 复核，再由 Anan 人工决定是否清空或关闭对应实例的 `HEARTBEAT.md`。

`heartbeat-burn-alert-runner.sh` 是上述检查器的告警写入层。`run` 会调用 inspector，并把最新结果写入 `runtime/heartbeat-burn-alerts/latest.json`；如果发现可疑增长，会追加 `runtime/heartbeat-burn-alerts/events.ndjson` 并以非 0 退出，方便 cron 或外部监控识别。该 runner 只写 control-center runtime，不写 OpenClaw 实例目录、不清空 `HEARTBEAT.md`、不调用模型、不重启实例。

`install-heartbeat-burn-alert-cron.sh` 用于把异常用量检查安装成当前用户 crontab 中的受控定时任务。`status/plan` 只读取 crontab 并展示将安装的 `OPENCLAW_HEARTBEAT_BURN_ALERT_CRON` 标记块；`apply/remove` 必须设置 `CONFIRM_HEARTBEAT_BURN_ALERT_CRON=I_UNDERSTAND_THIS_ONLY_INSTALLS_READONLY_HEARTBEAT_BURN_ALERT_CRON`。默认每 15 分钟检查全部实例；也可以设置 `HEARTBEAT_BURN_ALERT_INSTANCE_IDS="deepseek"` 只盯某个实例。它安装的 cron 只会执行 `heartbeat-burn-alert-runner.sh run`，不会打开 live gate、不会修改 OpenClaw 实例目录。

当前只有一台 Oracle 时，新增实例优先走本机注册入口：

```bash
cd /srv/openclaw-control-center-readonly
cp repo/ops/tom-readonly/register-local-instance.example.json runtime/register-local-instance.json
# 编辑 runtime/register-local-instance.json，填入新实例 id/name/gatewayUrl/configDir/workspaceDir。
repo/ops/tom-readonly/register-local-instance.sh plan runtime/register-local-instance.json
CONFIRM_LOCAL_INSTANCE_REGISTER=I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_LOCAL_REGISTRY \
repo/ops/tom-readonly/register-local-instance.sh apply runtime/register-local-instance.json
docker compose up -d control-center
./collector-snapshot.sh
./healthcheck.sh
```

`register-local-instance.sh plan` 只读取配置、registry、compose 和实例目录元数据，不写文件；`apply` 会先备份 `config/instances.json` 与 `docker-compose.yml`，再把新实例挂载为 `:ro` 并写入 registry。它不会修改任何 OpenClaw 实例目录，不会重启任何 OpenClaw 实例，不会调用 managed action live API。`docker compose up -d control-center` 只用于让控制中心容器重新加载新增的只读挂载。

接第二台 Oracle 前，可以先在 Tom 生成一个可审查的 onboarding 接入包：

```bash
# 如果远端只读 SSH key 还在本机，可以先在本机执行：
ops/local/final-go-live-status.sh status
ops/local/final-go-live-status.sh check
ops/local/final-go-live-runner.sh prepare
REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> \
ops/local/remote-oracle-intake.sh doctor
REMOTE_ORACLE_HOST=<可达候选 host> REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> \
ops/local/remote-oracle-intake.sh doctor
REMOTE_ORACLE_HOST=<可达候选 host> REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> \
ops/local/remote-oracle-intake.sh plan
CONFIRM_REMOTE_ORACLE_INTAKE=I_UNDERSTAND_THIS_WRITES_LOCAL_PUSH_CONFIG_AND_TOM_RUNTIME_ONLY \
REMOTE_ORACLE_HOST=<可达候选 host> REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> \
ops/local/remote-oracle-intake.sh apply
CONFIRM_REMOTE_ORACLE_INTAKE=I_UNDERSTAND_THIS_WRITES_LOCAL_PUSH_CONFIG_AND_TOM_RUNTIME_ONLY \
CONFIRM_REMOTE_ORACLE_INTAKE_RUNNER=I_UNDERSTAND_THIS_PUSHES_CREDENTIALS_AND_RUNS_TOM_SAFE_ROLLOUT \
REMOTE_ORACLE_HOST=<可达候选 host> REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> \
ops/local/remote-oracle-intake.sh run
ops/local/discover-remote-oracle-credentials.sh scan ops/local/discover-remote-oracle-credentials.example.json
CONFIRM_REMOTE_ORACLE_DISCOVERY=I_UNDERSTAND_THIS_ONLY_PROBES_SSH_READONLY \
ops/local/discover-remote-oracle-credentials.sh probe ops/local/discover-remote-oracle-credentials.example.json
REMOTE_ORACLE_HOST=<可达候选 host> REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> \
ops/local/discover-remote-oracle-credentials.sh render-push-config ops/local/discover-remote-oracle-credentials.example.json > runtime/push-remote-collector-credentials.json
CONFIRM_REMOTE_ORACLE_PUSH_CONFIG_WRITE=I_UNDERSTAND_THIS_ONLY_WRITES_LOCAL_PUSH_CONFIG \
REMOTE_ORACLE_HOST=<可达候选 host> REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> \
ops/local/discover-remote-oracle-credentials.sh write-push-config ops/local/discover-remote-oracle-credentials.example.json
ops/local/push-remote-collector-credentials.sh plan runtime/push-remote-collector-credentials.json
CONFIRM_PUSH_REMOTE_COLLECTOR_CREDENTIALS=I_UNDERSTAND_THIS_ONLY_PUSHES_REMOTE_COLLECTOR_CREDENTIALS_TO_TOM_RUNTIME \
ops/local/push-remote-collector-credentials.sh apply runtime/push-remote-collector-credentials.json

# 如果远端只读 SSH key 已在 Tom 上，则在 Tom 执行：
cp repo/ops/tom-readonly/remote-collector-onboarding.example.json runtime/remote-collector-onboarding.json
cp repo/ops/tom-readonly/remote-collector-credentials.example.json runtime/remote-collector-credentials.json
repo/ops/tom-readonly/remote-collector-credentials.sh plan runtime/remote-collector-credentials.json
CONFIRM_REMOTE_COLLECTOR_CREDENTIALS=I_UNDERSTAND_THIS_ONLY_WRITES_CONTROL_CENTER_REMOTE_CREDENTIALS \
repo/ops/tom-readonly/remote-collector-credentials.sh apply runtime/remote-collector-credentials.json
repo/ops/tom-readonly/remote-collector-onboarding.sh plan runtime/remote-collector-onboarding.json
CONFIRM_REMOTE_COLLECTOR_ONBOARDING=I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_ONBOARDING_BUNDLE \
repo/ops/tom-readonly/remote-collector-onboarding.sh write runtime/remote-collector-onboarding.json
repo/ops/tom-readonly/remote-collector-onboarding.sh verify runtime/remote-onboarding/<serverId>
repo/ops/tom-readonly/remote-collector-preflight.sh plan runtime/remote-onboarding/<serverId>
CONFIRM_REMOTE_COLLECTOR_PREFLIGHT=I_UNDERSTAND_THIS_ONLY_READS_REMOTE_PREREQUISITES \
repo/ops/tom-readonly/remote-collector-preflight.sh check runtime/remote-onboarding/<serverId>
repo/ops/tom-readonly/remote-collector-node-sync.sh plan runtime/remote-onboarding/<serverId>
CONFIRM_REMOTE_COLLECTOR_NODE_SYNC=I_UNDERSTAND_THIS_ONLY_COPIES_COLLECTOR_BUNDLE_TO_REMOTE \
repo/ops/tom-readonly/remote-collector-node-sync.sh sync runtime/remote-onboarding/<serverId>
CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_PLAN=I_UNDERSTAND_THIS_ONLY_RUNS_REMOTE_BOOTSTRAP_PLAN \
repo/ops/tom-readonly/remote-collector-node-sync.sh bootstrap-plan runtime/remote-onboarding/<serverId>
CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_WRITE=I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_COLLECTOR_NODE_FILES \
repo/ops/tom-readonly/remote-collector-node-sync.sh bootstrap-write runtime/remote-onboarding/<serverId>
CONFIRM_REMOTE_COLLECTOR_NODE_SNAPSHOT=I_UNDERSTAND_THIS_RUNS_REMOTE_COLLECTOR_SNAPSHOT_ONLY \
repo/ops/tom-readonly/remote-collector-node-sync.sh snapshot runtime/remote-onboarding/<serverId>
CONFIRM_REMOTE_COLLECTOR_NODE_CRON=I_UNDERSTAND_THIS_ONLY_INSTALLS_REMOTE_COLLECTOR_CRON \
repo/ops/tom-readonly/remote-collector-node-sync.sh install-cron runtime/remote-onboarding/<serverId>
repo/ops/tom-readonly/remote-collector-rollout.sh status runtime/remote-onboarding/<serverId>
CONFIRM_REMOTE_COLLECTOR_ROLLOUT_RUNNER=I_UNDERSTAND_THIS_RUNS_SAFE_REMOTE_COLLECTOR_ROLLOUT_STEPS \
repo/ops/tom-readonly/remote-collector-rollout-runner.sh run runtime/remote-onboarding/<serverId>
```

本机侧 `remote-oracle-intake.sh doctor` 只读取本机 SSH config、host hint 和 key 文件元数据，并在显式提供 `REMOTE_ORACLE_HOST/REMOTE_ORACLE_KEY_PATH` 时离线渲染配置摘要；它不写文件、不联网、不连接 Tom 或第二台 Oracle。`remote-oracle-intake.sh plan` 只渲染将要推送到 Tom 的配置摘要，不写文件、不联网；`apply` 必须显式确认，只串联本机 `write-push-config`、本机 `push-remote-collector-credentials.sh plan` 和推送 Tom runtime，不连接第二台 Oracle、不写 registry、不修改任何实例目录；`run` 还必须显式确认，会在 `apply` 后 SSH 到 Tom 触发 `remote-collector-rollout-runner.sh run`，继续推进已满足安全门禁的阶段，期间可能通过 Tom 对第二台 Oracle 做只读 preflight/pull，并可能更新 Tom control-center registry，但不会写远端实例目录、不会启动容器、不会调用 live API。本机侧 `discover-remote-oracle-credentials.sh scan` 只读取本机 SSH config、候选 key 文件元数据和显式 host hint 文件，不联网、不写文件、不输出私钥内容；`probe` 必须显式确认，只对候选 host/key 执行 `id -un`、`uname -n`、`uname -s` 这类只读 SSH 探测，并使用 `/dev/null` 作为 known hosts 文件，避免悄悄写本机状态；`render-push-config` 只按显式 `REMOTE_ORACLE_HOST` 和 `REMOTE_ORACLE_KEY_PATH` 输出本机 push 配置 JSON；`write-push-config` 必须显式确认，只把同一份 push 配置写到本机 `runtime/` 下。本机侧 `push-remote-collector-credentials.sh apply` 只通过 SSH 写 Tom control-center runtime 下的远端只读 SSH key 和 onboarding 配置；它不会连接第二台 Oracle，不会写 registry，不会修改任何实例目录。Tom 侧 `remote-collector-credentials.sh apply` 只复制 Tom 本地已有的远端只读 SSH key 到 `runtime/ssh/`，并生成 `runtime/remote-collector-onboarding.json`；它不会联网，不会写远端文件，不会写 registry。接入包默认写入 `runtime/remote-onboarding/<serverId>/`，包含远端 `collector-node.json`、远端 bootstrap 脚本、Tom 拉取配置、Tom 注册配置和 `RUNBOOK.md`。如果没有配置 `collectorNode.buildContext`，脚本会默认把构建 collector image 所需的最小 `build-context/` 一并放进接入包，远端不需要预先克隆完整仓库。`verify` 只读取接入包并离线校验，不 SSH、不写 registry。`preflight check` 会 SSH 到远端执行只读检查命令，只检查 docker、目录可读性、deploy 目录权限和 gateway 端口，不写远端文件、不启动容器、不调用 live API，并把结果写入 Tom 本地 `runtime/remote-preflight-state/<serverId>.json`。`remote-collector-node-sync.sh plan` 只读取 Tom 本地接入包；`sync` 必须显式确认，只把接入包复制到远端 collector deploy 目录；`bootstrap-plan/bootstrap-write` 必须分别显式确认，只在远端 collector deploy 目录执行 bootstrap 计划或写入 collector-only 部署文件，不启动容器、不安装 cron、不修改 OpenClaw 实例目录；`snapshot/install-cron` 必须分别显式确认，只启动/使用 collector-only 容器生成 snapshot，并安装当前用户 crontab 中的 collector 受控块，不启动或重启 OpenClaw 实例容器。`remote-collector-rollout.sh status` 不联网、不写文件，用来确认下一步是补远端凭据、preflight、同步远端 collector 节点、pull、register 还是 healthcheck。`remote-collector-rollout-runner.sh run` 会按这个阶段顺序自动调用对应安全脚本，但必须显式提供确认令牌；它不会跳过缺凭据、缺远端 snapshot 或失败检查。

远端 collector 拉取只读取远端 snapshot 文件，远端服务器必须先自行生成 collector JSON。拉取命令不会执行远端 collector、不会修改远端实例目录，也不会调用 `/api/managed-actions/live`。本地写入路径必须位于：

```bash
/srv/openclaw-control-center-readonly/runtime/collectors/
```

拉取成功后，用 `register-remote-collector.sh plan` 审查将要加入 `config/instances.json` 的 server 和实例；`apply` 会先备份原 registry，再原子写入新 registry。该脚本只更新 control-center registry，不修改 OpenClaw 实例目录。

最终上线前优先看总闸门：

```bash
repo/ops/tom-readonly/go-live-gate.sh status runtime/remote-onboarding/<serverId>
repo/ops/tom-readonly/go-live-gate.sh check runtime/remote-onboarding/<serverId>
```

`status` 只汇总 rollout、dry-run 证据和 live readiness；`check` 会额外运行 `./healthcheck.sh` 验证 Tom 现有实例仍正常、只读边界仍有效。总闸门只输出下一步命令，不会调用 live API，不会修改实例目录。

只读 healthcheck live 演练必须先人工准备 live gate、executor 和 rollout 配置；默认 Tom 不启用。确认后才可手动运行：

```bash
repo/ops/tom-readonly/managed-action-dry-run-gate.sh status
CONFIRM_MANAGED_ACTION_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CREATES_DRY_RUN_AUDIT_RECORD \
LOCAL_API_TOKEN=<本地令牌> \
repo/ops/tom-readonly/managed-action-dry-run-gate.sh run

./live-healthcheck-preflight.sh

EXPECT_LIVE_READY=true \
ROLLOUT_FILE=/srv/openclaw-control-center-readonly/runtime/managed-action-healthcheck-rollout.json \
./live-healthcheck-preflight.sh

CONFIRM_LIVE_HEALTHCHECK=I_UNDERSTAND_THIS_CALLS_LIVE_API \
LOCAL_API_TOKEN=<本地令牌> \
INSTANCE_ID=tom \
OPERATOR=Anan \
./live-healthcheck-smoke.sh
```

更推荐使用一次性演练窗口，脚本会在退出前自动恢复只读状态：

```bash
repo/ops/tom-readonly/live-healthcheck-rollout-runner.sh prepare
CONFIRM_APPROVAL_RECORD=I_APPROVE_LIVE_HEALTHCHECK_RECORD \
APPROVED_BY=Anan \
repo/ops/tom-readonly/live-healthcheck-approval.sh approve runtime/live-healthcheck-approval.json

CONFIRM_LIVE_HEALTHCHECK_RUNNER=I_UNDERSTAND_THIS_RUNS_APPROVED_LIVE_HEALTHCHECK \
LOCAL_API_TOKEN=<本地令牌> \
repo/ops/tom-readonly/live-healthcheck-rollout-runner.sh run-approved
```

`live-healthcheck-rollout-runner.sh prepare` 可以自动推进到人工批准前：先确认 dry-run 证据 ready，再准备 approval 模板，生成并校验批准前证据包，最后运行 readiness `check`。它不会批准 approval、不会打开 live gate、不会调用 managed action live API。`live-healthcheck-rollout-runner.sh status` 只读取 readiness，不写文件。人工 approval 已批准后，`run-approved` 会再次检查 readiness 必须为 `approved_ready_for_live_window`，并要求 `CONFIRM_LIVE_HEALTHCHECK_RUNNER` 和 `LOCAL_API_TOKEN`，随后才调用一次性演练窗口；窗口完成后 runner 会自动执行 `verify-completed`，只读确认 readiness 为 `approval_consumed`、最新报告 `passed`、approval 已消费、impact 检查通过且 `mutatesOpenClawInstance=false`。如果被前置条件、人工批准或演练后验收挡住，runner 会返回非 0 退出码，避免自动化误判为已执行成功。

`live-healthcheck-readiness.sh status/check` 会只读汇总总闸门、dry-run 证据、批准前证据包、approval 和 live window 状态，输出 `waiting_human_approval`、`approved_ready_for_live_window` 或 `blocked_preconditions` 等状态；它给出的下一步命令统一指向 `live-healthcheck-rollout-runner.sh prepare/run-approved` 主链路。它不会生成新证据包、不会写 approval、不会打开 live gate、不会调用 managed action live API。

`live-healthcheck-approval-review.sh status/check` 是给人工批准前使用的只读汇总入口。它聚合 readiness、approval packet、approval、dry-run inbox cron 和 inbox pending 状态，输出 `ready_for_human_approval`、`approved_ready_for_live_window` 或 `blocked_preconditions`。`status` 不运行 healthcheck；`check` 只让 readiness 执行只读 healthcheck。它不会生成新证据包、不会批准 approval、不会打开 live gate、不会调用 managed action live API，也不会修改 OpenClaw 实例目录。

`live-healthcheck-approval-packet.sh generate` 会写入：

```bash
/srv/openclaw-control-center-readonly/runtime/live-healthcheck-approval-packets/
```

它会运行总闸门 `check`、dry-run 证据 `status`、approval `status`、live window `status`，并生成一份 `pre-live-approval-packet` 影响快照。`check` 会校验最新证据包是否匹配当前 commit、目标实例、dry-run 证据、只读状态和影响快照。该脚本不会批准 live healthcheck，不会打开 live gate，不会调用 managed action live API。`live-healthcheck-approval.sh approve` 会先执行证据包 `check` 才写 approval；`live-healthcheck-window.sh enable/run` 会先执行证据包 `check`，再校验 approval 文件。

`run` 模式会在 live healthcheck 调用成功后把 approval 标记为已使用，后续必须重新 `approve` 才能再次演练；它也会自动生成 before/after 实例影响快照，位置默认为：

```bash
/srv/openclaw-control-center-readonly/runtime/impact-snapshots/
```

快照比较要求演练后恢复为只读状态、gateway 健康保持正常、监听端口保持稳定、实例挂载仍是只读、live gate 和 executor 均关闭。

`run` 成功后还会生成演练报告，位置默认为：

```bash
/srv/openclaw-control-center-readonly/runtime/live-healthcheck-reports/
```

报告通过条件包括：approval 已批准且已标记为已使用、dry-run 审计存在、live result 审计为 `executed`、`mutatesOpenClawInstance=false`，以及 after 快照恢复只读。

如果只需要手动打开或关闭演练窗口：

```bash
CONFIRM_LIVE_HEALTHCHECK_WINDOW=I_UNDERSTAND_THIS_TEMPORARILY_ENABLES_LIVE_GATE \
APPROVAL_FILE=/srv/openclaw-control-center-readonly/runtime/live-healthcheck-approval.json \
repo/ops/tom-readonly/live-healthcheck-window.sh enable

repo/ops/tom-readonly/live-healthcheck-window.sh disable
```

## 验收标准

一次可接受的 Tom 灰度发布至少要满足：

- `./healthcheck.sh` 通过。
- 控制中心容器端口只绑定 `127.0.0.1:4311`。
- 容器未启用 `privileged`。
- 容器未挂载 `/var/run/docker.sock`。
- 所有实例目录挂载均为只读。
- `MANAGED_ACTIONS_LIVE_ENABLED` 与 `MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED` 不得为 `true`。
- `PATCH /api/ui/preferences` 返回 403。
- 如果 registry 配置了 `collectorSnapshotPath`，快照必须存在、可解析、包含实例且未超过 `COLLECTOR_SNAPSHOT_MAX_AGE_SECONDS`。
