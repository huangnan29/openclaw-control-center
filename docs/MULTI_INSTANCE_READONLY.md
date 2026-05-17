# 多实例只读部署

本模式用于用一个 OpenClaw Control Center 观察多套 OpenClaw 实例。第一版定位是严格只读：只做监控、汇总和排障，不执行发布、审批、暂停、恢复、导入或任务派发。

当前生产拓扑默认是 `OPENCLAW_TOPOLOGY_MODE=local-only`：只管理当前 Oracle 上的多套 OpenClaw 实例，跨服务器远端 collector 不作为上线前置条件。未来要扩展到第二台 Oracle 时，再显式设置 `OPENCLAW_TOPOLOGY_MODE=cross-server` 并启用远端 onboarding、preflight、pull 和 register 链路。

## 安全原则

- 所有 OpenClaw 实例目录使用只读挂载。
- 不挂载 /var/run/docker.sock。
- 不使用 `privileged: true`。
- 保持 `READONLY_MODE=true`。
- 保持 `APPROVAL_ACTIONS_ENABLED=false`。
- 保持 `IMPORT_MUTATION_ENABLED=false`。
- 保持 `TASK_HEARTBEAT_ENABLED=false`。
- 保持 `HALL_RUNTIME_DISPATCH_ENABLED=false` 和 `HALL_RUNTIME_DIRECT_STREAM_ENABLED=false`。
- UI 建议放在内网、SSH tunnel、Tailscale 或带鉴权的反向代理后面。

## Tom 示例目录

Tom 上建议把真实实例目录映射到容器内统一的 `/instances`：

```yaml
volumes:
  - /srv/openclaw/config:/instances/main/config:ro
  - /srv/openclaw/workspace:/instances/main/workspace:ro
  - /srv/openclaw-work/config:/instances/tom/config:ro
  - /srv/openclaw-work/workspace:/instances/tom/workspace:ro
  - /srv/openclaw-third/config:/instances/third/config:ro
  - /srv/openclaw-third/workspace:/instances/third/workspace:ro
  - /srv/openclaw-spark/config:/instances/spark/config:ro
  - /srv/openclaw-spark/workspace:/instances/spark/workspace:ro
  - /srv/openclaw-deepseek/config:/instances/deepseek/config:ro
  - /srv/openclaw-deepseek/workspace:/instances/deepseek/workspace:ro
```

上面路径只是 Tom 的示例。实际部署前先确认每个实例的 `config`、`workspace` 是否存在，并确认容器用户有读取权限。

## instances.json

推荐使用 `OPENCLAW_INSTANCES_FILE` 指向一个只读配置文件，例如 `/app/config/instances.json`：

```json
{
  "instances": [
    {
      "id": "main",
      "name": "Main",
      "openclawHome": "/instances/main/config",
      "workspaceRoot": "/instances/main/workspace"
    },
    {
      "id": "tom",
      "name": "Tom / Work",
      "openclawHome": "/instances/tom/config",
      "workspaceRoot": "/instances/tom/workspace"
    },
    {
      "id": "third",
      "name": "Third",
      "openclawHome": "/instances/third/config",
      "workspaceRoot": "/instances/third/workspace"
    },
    {
      "id": "spark",
      "name": "Spark",
      "openclawHome": "/instances/spark/config",
      "workspaceRoot": "/instances/spark/workspace"
    },
    {
      "id": "deepseek",
      "name": "DeepSeek",
      "openclawHome": "/instances/deepseek/config",
      "workspaceRoot": "/instances/deepseek/workspace"
    }
  ]
}
```

`id` 只允许小写字母、数字、下划线和短横线。`name` 是 UI 显示名。`openclawHome` 用于读取该实例的 OpenClaw 配置，`workspaceRoot` 用于读取 workspace 相关信号。

## 跨服务器 registry

长期管理多台 Oracle 服务器时，推荐把配置升级为 `servers + instances` 模型。控制中心仍然只读：它只是把每个实例归属到某台服务器，并在总览页显示 `服务器健康`、`server=` 筛选链接和实例详情中的服务器元数据。

```json
{
  "servers": [
    {
      "id": "tom-oracle",
      "name": "Tom Oracle",
      "host": "146.235.226.66",
      "region": "oracle-us",
      "instances": [
        {
          "id": "main",
          "name": "Main",
          "openclawHome": "/instances/main/config",
          "workspaceRoot": "/instances/main/workspace"
        },
        {
          "id": "tom",
          "name": "Tom / Work",
          "openclawHome": "/instances/tom/config",
          "workspaceRoot": "/instances/tom/workspace"
        }
      ]
    },
    {
      "id": "second-oracle",
      "name": "Second Oracle",
      "host": "10.0.0.12",
      "instances": [
        {
          "id": "second-main",
          "name": "Second Main",
          "openclawHome": "/instances/second-main/config",
          "workspaceRoot": "/instances/second-main/workspace"
        }
      ]
    }
  ]
}
```

解析后，每个实例会携带 `serverId`、`serverName`、`serverHost`、`serverRegion` 等只读元数据。旧版顶层 `instances` 配置继续兼容；没有服务器字段的实例会在 UI 中归入 `Local server`。

当前阶段只是 registry 与 UI 维度升级。跨服务器真实采集仍建议下一阶段通过每台 Oracle 本地 collector 上报快照，而不是让中央控制中心直接拿远端实例目录写权限。

## collector 快照文件

中央 collector 架构的第一步是让每台 Oracle 服务器本地生成只读快照文件，中央 control-center 只读取这个文件中的监控数据。这样中央节点不需要直接挂载远端实例目录，也不会获得远端实例的写权限。

在 server registry 中可以为某台服务器声明 `collectorSnapshotPath`：

```json
{
  "servers": [
    {
      "id": "remote-oracle",
      "name": "Remote Oracle",
      "host": "10.0.0.12",
      "collectorSnapshotPath": "/app/collectors/remote-oracle/snapshot.json",
      "instances": [
        {
          "id": "remote-main",
          "name": "Remote Main"
        }
      ]
    }
  ]
}
```

当某个 server 配置了 `collectorSnapshotPath` 后，该 server 下的实例会优先使用快照文件中的状态，而不是在中央节点执行本地目录扫描。collector-only 远端实例可以只填写 `id` 和 `name`，不需要在中央 registry 中填写远端 `openclawHome` 或 `workspaceRoot`；中央会自动生成仅用于内部标识的 `/collector/<serverId>/<instanceId>/config` 路径。快照文件示例：

```json
{
  "schemaVersion": 1,
  "serverId": "remote-oracle",
  "generatedAt": "2026-05-17T04:00:00.000Z",
  "instances": [
    {
      "id": "remote-main",
      "status": "connected",
      "detail": "collector ok",
      "snapshot": {
        "sessions": [],
        "statuses": [],
        "cronJobs": [],
        "approvals": [],
        "projects": { "projects": [], "updatedAt": "2026-05-17T04:00:00.000Z" },
        "projectSummaries": [],
        "tasks": { "tasks": [], "agentBudgets": [], "updatedAt": "2026-05-17T04:00:00.000Z" },
        "tasksSummary": { "projects": 0, "tasks": 0, "todo": 0, "inProgress": 0, "blocked": 0, "done": 0, "owners": 0, "artifacts": 0 },
        "budgetSummary": { "total": 0, "ok": 0, "warn": 0, "over": 0, "evaluations": [] },
        "generatedAt": "2026-05-17T04:00:00.000Z"
      }
    }
  ]
}
```

当前版本只实现中央读取快照文件的能力。下一步才是在每台 Oracle 服务器上实现本地 collector exporter，由 exporter 定期生成上述 JSON。

### 本地 exporter 命令

服务器本地可以用 `collector:snapshot` 生成上述快照。这个命令只读取当前 registry 里的实例，并把结果写到指定输出文件：

```bash
OPENCLAW_COLLECTOR_SERVER_ID=tom-oracle npm run collector:snapshot -- runtime/collectors/tom-oracle/snapshot.json
```

容器生产环境可以直接运行编译后的命令：

```bash
OPENCLAW_COLLECTOR_SERVER_ID=tom-oracle node dist/index.js collector-snapshot /app/runtime/collectors/tom-oracle/snapshot.json
```

Tom 灰度部署提供了封装脚本：

```bash
cd /srv/openclaw-control-center-readonly
./collector-snapshot.sh
```

### 远端 collector-only 节点

第二台 Oracle 不需要运行完整中央 UI，也不需要把实例目录暴露给 Tom。可以在远端服务器上用 collector-only bootstrap 生成一个只负责产出 snapshot 的部署目录：

```bash
cp ops/collector-node/collector-node.example.json /tmp/collector-node.json
ops/collector-node/bootstrap-collector-node.sh plan /tmp/collector-node.json
CONFIRM_COLLECTOR_NODE_WRITE=I_UNDERSTAND_THIS_ONLY_WRITES_COLLECTOR_NODE_FILES \
ops/collector-node/bootstrap-collector-node.sh write /tmp/collector-node.json
```

`plan` 只校验配置并输出将生成的文件；`write` 只写入 `docker-compose.collector.yml`、`config/instances.json`、`collector-snapshot.sh` 和 `install-collector-cron.sh`，不会启动容器、不会运行 collector、不会修改任何 OpenClaw 实例目录。生成的 compose 不暴露端口，不挂载 `/var/run/docker.sock`，实例目录只用 `:ro` 方式挂载。

写入完成后，在远端服务器上执行：

```bash
cd /srv/openclaw-collector-node
./collector-snapshot.sh
./install-collector-cron.sh
```

远端 snapshot 生成后，再由 Tom 使用 `remote-collector-pull.sh` 只读拉取。

Tom 进入 collector 灰度切流后，可以安装定时任务持续刷新快照：

```bash
cd /srv/openclaw-control-center-readonly
./install-collector-cron.sh
OPENCLAW_COLLECTOR_CRON_SCHEDULE="*/2 * * * *" ./install-collector-cron.sh
```

`install-collector-cron.sh` 只更新当前用户 crontab 中 `OPENCLAW_COLLECTOR_CRON_BEGIN` 到 `OPENCLAW_COLLECTOR_CRON_END` 之间的受控标记块，重复执行会覆盖旧的 OpenClaw collector 定时任务，不会改动标记块之外的其他 cron。

`healthcheck.sh` 会读取 server registry 中的 `collectorSnapshotPath`，并用 `COLLECTOR_SNAPSHOT_MAX_AGE_SECONDS` 检查快照是否存在、可解析、包含实例且未过期。默认最大年龄是 300 秒。

### 跨服务器只读拉取

中央节点可以用 Tom 运维脚本拉取其他 Oracle 服务器已经生成好的 collector snapshot。这个步骤只通过 SSH 读取远端 JSON 文件，再写入中央节点自己的 `runtime/collectors` 目录；它不会运行远端 collector，不会修改远端 OpenClaw 实例目录，也不会调用 managed action live API。

为了减少真实接入时手工拼配置的风险，Tom 可以先生成一个只读 onboarding 接入包：

```bash
# 如果远端只读 SSH key 还在本机，可以先在本机推送到 Tom control-center runtime：
ops/local/final-go-live-status.sh status
ops/local/final-go-live-status.sh check
REMOTE_ORACLE_HOST=<可达候选 host> REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> \
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

# 如果远端只读 SSH key 已在 Tom 上，可以直接在 Tom 生成 onboarding 配置：
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
repo/ops/tom-readonly/go-live-gate.sh status runtime/remote-onboarding/<serverId>
repo/ops/tom-readonly/go-live-gate.sh check runtime/remote-onboarding/<serverId>
```

本机侧 `remote-oracle-intake.sh doctor` 只读取本机 SSH config、host hint 和 key 文件元数据，并在显式提供 `REMOTE_ORACLE_HOST/REMOTE_ORACLE_KEY_PATH` 时离线渲染配置摘要；它不写文件、不联网、不连接 Tom 或第二台 Oracle。`remote-oracle-intake.sh plan` 只渲染将要推送到 Tom 的配置摘要，不写文件、不联网；`apply` 必须显式确认，只串联本机 `write-push-config`、本机 `push-remote-collector-credentials.sh plan` 和推送 Tom runtime，不连接第二台 Oracle、不写 registry、不修改任何实例目录；`run` 还必须显式确认，会在 `apply` 后 SSH 到 Tom 触发 `remote-collector-rollout-runner.sh run`，继续推进已满足安全门禁的阶段，期间可能通过 Tom 对第二台 Oracle 做只读 preflight/pull，并可能更新 Tom control-center registry，但不会写远端实例目录、不会启动容器、不会调用 live API。本机侧 `discover-remote-oracle-credentials.sh scan` 只读取本机 SSH config、候选 key 文件元数据和显式 host hint 文件，不联网、不写文件、不输出私钥内容；`probe` 必须显式确认，只对候选 host/key 执行只读 SSH 探测，不写远端文件、不写 Tom runtime；`render-push-config` 只按显式 `REMOTE_ORACLE_HOST` 和 `REMOTE_ORACLE_KEY_PATH` 输出本机 push 配置 JSON；`write-push-config` 必须显式确认，只把同一份 push 配置写到本机 `runtime/` 下。本机侧 `push-remote-collector-credentials.sh plan` 不联网、不写文件；`apply` 只通过 SSH 写 Tom control-center runtime 下的远端只读 SSH key 和 onboarding 配置，不连接第二台 Oracle，不写 registry，不修改任何实例目录。Tom 侧 `remote-collector-credentials.sh plan` 只校验真实远端 host/user/port 和 Tom 本地 source key 路径，不写文件、不联网；`apply` 只复制远端只读 SSH key 到 Tom control-center 的 `runtime/ssh/`，并生成 `runtime/remote-collector-onboarding.json`。`remote-collector-onboarding.sh plan` 只校验配置并输出将生成的文件；`write` 只写 `runtime/remote-onboarding/<serverId>/` 下的接入包，不会 SSH、不会修改 `config/instances.json`、不会修改任何 OpenClaw 实例目录；`verify` 只读取接入包并离线校验 serverId、safety、pull/register 配置、build-context 和 bootstrap plan；`remote-collector-preflight.sh check` 才会 SSH 到远端，但只执行只读检查命令，检查 docker、目录可读性、deploy 目录权限和 gateway 端口，并把结果写入 Tom 本地 `runtime/remote-preflight-state/<serverId>.json`。`remote-collector-node-sync.sh plan` 只读取 Tom 本地接入包；`sync` 必须显式确认，只通过 SSH+tar 把接入包复制到远端 collector deploy 目录；`bootstrap-plan/bootstrap-write` 必须分别显式确认，只执行远端接入包里的 bootstrap 计划或写入 collector-only 部署文件，不启动容器、不安装 cron、不修改任何 OpenClaw 实例目录；`snapshot/install-cron` 必须分别显式确认，只启动/使用 collector-only 容器生成 snapshot，并安装当前用户 crontab 中的 collector 受控块，不启动或重启 OpenClaw 实例容器。`remote-collector-rollout.sh status` 只读取 Tom 本地状态，判断当前处于 `needs_remote_credentials`、`needs_remote_preflight`、`needs_remote_collector_pull`、`needs_registry_register` 或 `ready_for_healthcheck`，并输出下一步命令；它不 SSH、不写 registry、不写远端文件、不启动 OpenClaw 实例容器。`remote-collector-rollout-runner.sh run` 在显式确认后会复用这些脚本自动推进已满足安全门禁的阶段：刷新 onboarding、执行只读 preflight、同步远端 collector 节点、生成远端 snapshot、只读 pull、registry 注册和 healthcheck；遇到缺凭据或任一检查失败会停止。`go-live-gate.sh status/check` 是最终上线总闸门；默认 `OPENCLAW_TOPOLOGY_MODE=local-only` 时汇总 Tom 本机实例 healthcheck、dry-run 证据和 live 管理动作 readiness，不要求第二台 Oracle；显式 `OPENCLAW_TOPOLOGY_MODE=cross-server` 时才把跨服务器只读监控阶段纳入上线阻塞。总闸门只输出下一步命令，不调用 live API。接入包包含：

- `collector-node.json`：复制到远端 Oracle 后供 `bootstrap-collector-node.sh` 使用。
- `bootstrap-collector-node.sh`：远端 collector-only 节点引导脚本。
- `remote-collector-pull.sources.json`：Tom 只读拉取配置。
- `register-remote-collector.json`：Tom registry 注册配置。
- `RUNBOOK.md`：从复制接入包到远端、生成 snapshot、Tom 拉取、Tom 注册、健康检查的顺序命令。
- `build-context/`：当没有显式配置 `collectorNode.buildContext` 时自动生成，包含构建 collector image 所需的最小源码与 Dockerfile，远端不必预先克隆完整仓库。

配置样板：

```bash
cp repo/ops/tom-readonly/remote-collector-pull.sources.example.json runtime/remote-collector-pull.sources.json
```

先只查看计划：

```bash
repo/ops/tom-readonly/remote-collector-pull.sh plan runtime/remote-collector-pull.sources.json
```

确认后再拉取：

```bash
CONFIRM_REMOTE_COLLECTOR_PULL=I_UNDERSTAND_THIS_ONLY_READS_REMOTE_COLLECTOR_SNAPSHOTS \
repo/ops/tom-readonly/remote-collector-pull.sh pull runtime/remote-collector-pull.sources.json
```

拉取脚本会校验：

- 远端 JSON `schemaVersion` 必须为 `1`。
- 远端 JSON `serverId` 必须匹配配置中的 `serverId`。
- `generatedAt` 必须可解析。
- `instances` 必须是非空数组。
- 本地写入路径必须位于中央节点的 `runtime/collectors/` 下。

最近一次拉取结果会写入 `runtime/collector-pull-state/<serverId>.json`，可以用下面命令查看：

```bash
repo/ops/tom-readonly/remote-collector-pull.sh status runtime/remote-collector-pull.sources.json
```

拉取成功后，再把这个 collector server 注册进 Tom 的 `config/instances.json`。注册脚本会读取本机已拉取的 snapshot，校验 `serverId` 与实例列表，并在写入前备份原 registry：

```bash
cp repo/ops/tom-readonly/register-remote-collector.example.json runtime/register-remote-collector.json
repo/ops/tom-readonly/register-remote-collector.sh plan runtime/register-remote-collector.json
CONFIRM_REMOTE_COLLECTOR_REGISTER=I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_REGISTRY \
repo/ops/tom-readonly/register-remote-collector.sh apply runtime/register-remote-collector.json
./healthcheck.sh
```

`plan` 不写文件；`apply` 只更新 control-center registry，不修改任何 OpenClaw 实例目录，不重启实例，不调用 managed action live API。

### 管理动作 dry-run 证据

真实管理动作上线前，先用 dry-run 证据闸门确认最近一次 dry-run 审计可作为人工批准和 live 引用的前置证据：

```bash
repo/ops/tom-readonly/managed-action-dry-run-gate.sh status
```

如果没有有效 dry-run 审计，显式确认后只创建 dry-run 审计记录：

```bash
CONFIRM_MANAGED_ACTION_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CREATES_DRY_RUN_AUDIT_RECORD \
LOCAL_API_TOKEN=<本地令牌> \
repo/ops/tom-readonly/managed-action-dry-run-gate.sh run
```

该脚本不会调用 `/api/managed-actions/live`，不会修改 OpenClaw 实例目录，只会读取 readiness/audit 或创建 `managed_action_dry_run` 审计记录。

## 推荐环境变量

```env
OPENCLAW_INSTANCES_FILE=/app/config/instances.json
OPENCLAW_COLLECTOR_SERVER_ID=tom-oracle
OPENCLAW_COLLECTOR_OUTPUT=/app/runtime/collectors/tom-oracle/snapshot.json
OPENCLAW_COLLECTOR_CRON_SCHEDULE="*/2 * * * *"
COLLECTOR_SNAPSHOT_MAX_AGE_SECONDS=300
READONLY_MODE=true
APPROVAL_ACTIONS_ENABLED=false
APPROVAL_ACTIONS_DRY_RUN=true
IMPORT_MUTATION_ENABLED=false
IMPORT_MUTATION_DRY_RUN=true
TASK_HEARTBEAT_ENABLED=false
HALL_RUNTIME_DISPATCH_ENABLED=false
HALL_RUNTIME_DIRECT_STREAM_ENABLED=false
LOCAL_TOKEN_AUTH_REQUIRED=true
```

也可以使用 `OPENCLAW_INSTANCES_JSON` 做小规模内联配置，但生产部署更推荐文件方式，方便审查和备份。

## 启动前检查

- `docker-compose.example.yml` 中实例目录全部以 `:ro` 结尾。
- 未挂载 `/var/run/docker.sock`。
- 未启用 `privileged: true`。
- `OPENCLAW_INSTANCES_FILE` 指向容器内真实存在的 JSON 文件。
- UI 能看到多实例总览；进入单个实例详情后，只显示只读状态、会话、待审批和 Cron 信息。
- 任意写接口在默认配置下返回 403，并提示修改类接口已禁用。

## 回滚

如果多实例配置异常，先移除 `OPENCLAW_INSTANCES_FILE` / `OPENCLAW_INSTANCES_JSON` 并重启控制中心。系统会回退到单实例 fallback 配置，但只要 `READONLY_MODE=true`，写接口仍会保持禁用。

## Tom 灰度运维脚本

Tom 的长期灰度部署可以使用 `ops/tom-readonly/` 下的脚本：

- `healthcheck.sh`：检查 gateway、只读页面、写接口 403、容器端口、`privileged`、`docker.sock`、实例只读挂载和 collector 快照新鲜度。
- `install-collector-cron.sh`：安装 Tom collector 快照定时任务。
- `update.sh`：拉取 `multi-instance-readonly-control-center` 分支，重建控制中心容器，并自动运行健康检查。
- `rollback.sh`：回滚到指定提交；不传提交时使用最近一次更新前记录的 `previous-good.commit`。

推荐把脚本安装到 Tom 的 `/srv/openclaw-control-center-readonly`，然后每次升级前后执行：

```bash
cd /srv/openclaw-control-center-readonly
./healthcheck.sh
./install-collector-cron.sh
./update.sh
```
