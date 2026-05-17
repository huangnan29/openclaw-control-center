# 多实例只读部署

本模式用于用一个 OpenClaw Control Center 观察多套 OpenClaw 实例。第一版定位是严格只读：只做监控、汇总和排障，不执行发布、审批、暂停、恢复、导入或任务派发。

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
cp repo/ops/tom-readonly/remote-collector-onboarding.example.json runtime/remote-collector-onboarding.json
repo/ops/tom-readonly/remote-collector-onboarding.sh plan runtime/remote-collector-onboarding.json
CONFIRM_REMOTE_COLLECTOR_ONBOARDING=I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_ONBOARDING_BUNDLE \
repo/ops/tom-readonly/remote-collector-onboarding.sh write runtime/remote-collector-onboarding.json
repo/ops/tom-readonly/remote-collector-onboarding.sh verify runtime/remote-onboarding/<serverId>
repo/ops/tom-readonly/remote-collector-preflight.sh plan runtime/remote-onboarding/<serverId>
CONFIRM_REMOTE_COLLECTOR_PREFLIGHT=I_UNDERSTAND_THIS_ONLY_READS_REMOTE_PREREQUISITES \
repo/ops/tom-readonly/remote-collector-preflight.sh check runtime/remote-onboarding/<serverId>
repo/ops/tom-readonly/remote-collector-rollout.sh status runtime/remote-onboarding/<serverId>
```

`plan` 只校验配置并输出将生成的文件；`write` 只写 `runtime/remote-onboarding/<serverId>/` 下的接入包，不会 SSH、不会修改 `config/instances.json`、不会修改任何 OpenClaw 实例目录；`verify` 只读取接入包并离线校验 serverId、safety、pull/register 配置、build-context 和 bootstrap plan；`remote-collector-preflight.sh check` 才会 SSH 到远端，但只执行只读检查命令，检查 docker、目录可读性、deploy 目录权限和 gateway 端口，并把结果写入 Tom 本地 `runtime/remote-preflight-state/<serverId>.json`。`remote-collector-rollout.sh status` 只读取 Tom 本地状态，判断当前处于 `needs_remote_credentials`、`needs_remote_preflight`、`needs_remote_collector_pull`、`needs_registry_register` 或 `ready_for_healthcheck`，并输出下一步命令；它不 SSH、不写 registry、不写远端文件、不启动容器。接入包包含：

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
