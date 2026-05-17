# Tom 多实例只读控制中心运维脚本

这组脚本服务于 Tom 上的灰度部署目录：

```bash
/srv/openclaw-control-center-readonly
```

它们只更新、检查和回滚 OpenClaw Control Center 自身，不会修改任何 OpenClaw 实例目录。实例目录必须继续以 `:ro` 方式挂载。

## 脚本

- `healthcheck.sh`：检查 gateway 健康、总览页、实例详情页、写接口 403、容器只读安全边界，以及 collector 快照新鲜度。
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
- `go-live-gate.sh`：最终上线总闸门，汇总 Tom 本体 healthcheck、跨服务器只读监控、dry-run 证据和 live 管理动作 readiness。
- `remote-collector-pull.sh`：从其他 Oracle 服务器只读拉取已经生成好的 collector JSON，校验后写入本机 `runtime/collectors`。
- `remote-collector-pull.sources.example.json`：远端 collector 拉取配置样板，默认 `enabled=false`。
- `register-remote-collector.sh`：把已经拉取并校验过的远端 collector snapshot 注册到 Tom `config/instances.json`，默认 `plan` 不写入。
- `register-remote-collector.example.json`：远端 collector 注册配置样板。
- `update.sh`：拉取 `multi-instance-readonly-control-center` 分支，重建控制中心容器，随后执行健康检查。
- `rollback.sh`：回滚到指定提交；如果不传提交，则使用最近一次 `update.sh` 记录的 `previous-good.commit`。
- `../local/discover-remote-oracle-credentials.sh`：在本机只读发现第二台 Oracle 的候选 SSH host/key，`probe` 需显式确认且只执行只读 SSH 探测；拿到明确 host/key 后可用 `write-push-config` 只写本机 push 配置。
- `../local/discover-remote-oracle-credentials.example.json`：本机候选发现配置样板，不包含真实密钥内容。
- `../local/remote-oracle-intake.sh`：本机侧凭据接入编排器；`doctor/plan` 不写文件不联网，`apply` 显式确认后只写本机 push 配置和 Tom control-center runtime，`run` 会继续触发 Tom 端安全 rollout。
- `../local/final-go-live-status.sh`：本机侧最终上线状态汇总入口；`status/check` 同时读取本机 `remote-oracle-intake.sh doctor` 和 Tom `go-live-gate.sh`，不写本机 push 配置、不写 Tom runtime、不连接第二台 Oracle。
- `../local/push-remote-collector-credentials.sh`：在本机把远端只读 SSH key 和 onboarding 配置推送到 Tom control-center runtime，不连接第二台 Oracle。
- `managed-action-healthcheck-rollout.example.json`：只读 healthcheck live 演练的 rollout 样板，不会被默认加载。
- `managed-action-dry-run-gate.sh`：管理动作 dry-run 证据闸门，默认只读检查 readiness 与 audit，显式确认后只创建 dry-run 审计记录。
- `live-healthcheck-approval.sh`：生成、校验或标记 live healthcheck 人工批准记录，不调用 live API。
- `live-healthcheck-approval.example.json`：批准记录样板，默认未批准。
- `live-healthcheck-preflight.sh`：只读检查 healthcheck live 演练条件，不调用 live API。
- `live-healthcheck-smoke.sh`：手动 live healthcheck 演练脚本；只有显式提供本地令牌和确认环境变量才会调用 live API。
- `live-healthcheck-report.sh`：演练报告脚本；读取 approval、impact snapshots 和 operation audit，生成 JSON 与 Markdown 报告。
- `live-healthcheck-window.sh`：一次性演练窗口脚本；临时启用 control-center 的 healthcheck live 配置，失败或结束后恢复只读状态。
- `instance-impact-snapshot.sh`：演练前后实例影响留证脚本；只读取 gateway、监听端口、容器挂载和 readiness。

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
repo/ops/tom-readonly/managed-action-dry-run-gate.sh status
repo/ops/tom-readonly/remote-collector-pull.sh plan runtime/remote-collector-pull.sources.json
CONFIRM_REMOTE_COLLECTOR_PULL=I_UNDERSTAND_THIS_ONLY_READS_REMOTE_COLLECTOR_SNAPSHOTS \
repo/ops/tom-readonly/remote-collector-pull.sh pull runtime/remote-collector-pull.sources.json
repo/ops/tom-readonly/remote-collector-pull.sh status runtime/remote-collector-pull.sources.json
repo/ops/tom-readonly/register-remote-collector.sh plan runtime/register-remote-collector.json
CONFIRM_REMOTE_COLLECTOR_REGISTER=I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_REGISTRY \
repo/ops/tom-readonly/register-remote-collector.sh apply runtime/register-remote-collector.json
./update.sh
./rollback.sh <commit>
repo/ops/tom-readonly/live-healthcheck-approval.sh prepare runtime/live-healthcheck-approval.json
repo/ops/tom-readonly/live-healthcheck-approval.sh status runtime/live-healthcheck-approval.json
repo/ops/tom-readonly/live-healthcheck-approval.sh check runtime/live-healthcheck-approval.json
repo/ops/tom-readonly/live-healthcheck-approval.sh consume runtime/live-healthcheck-approval.json
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

接第二台 Oracle 前，可以先在 Tom 生成一个可审查的 onboarding 接入包：

```bash
# 如果远端只读 SSH key 还在本机，可以先在本机执行：
ops/local/final-go-live-status.sh status
ops/local/final-go-live-status.sh check
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
repo/ops/tom-readonly/live-healthcheck-approval.sh prepare runtime/live-healthcheck-approval.json
CONFIRM_APPROVAL_RECORD=I_APPROVE_LIVE_HEALTHCHECK_RECORD \
APPROVED_BY=Anan \
repo/ops/tom-readonly/live-healthcheck-approval.sh approve runtime/live-healthcheck-approval.json
repo/ops/tom-readonly/live-healthcheck-approval.sh status runtime/live-healthcheck-approval.json
repo/ops/tom-readonly/live-healthcheck-approval.sh check runtime/live-healthcheck-approval.json

CONFIRM_LIVE_HEALTHCHECK_WINDOW=I_UNDERSTAND_THIS_TEMPORARILY_ENABLES_LIVE_GATE \
CONFIRM_LIVE_HEALTHCHECK=I_UNDERSTAND_THIS_CALLS_LIVE_API \
LOCAL_API_TOKEN=<本地令牌> \
INSTANCE_ID=tom \
OPERATOR=Anan \
repo/ops/tom-readonly/live-healthcheck-window.sh run
```

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
