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

## 推荐环境变量

```env
OPENCLAW_INSTANCES_FILE=/app/config/instances.json
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

- `healthcheck.sh`：检查 gateway、只读页面、写接口 403、容器端口、`privileged`、`docker.sock` 和实例只读挂载。
- `update.sh`：拉取 `multi-instance-readonly-control-center` 分支，重建控制中心容器，并自动运行健康检查。
- `rollback.sh`：回滚到指定提交；不传提交时使用最近一次更新前记录的 `previous-good.commit`。

推荐把脚本安装到 Tom 的 `/srv/openclaw-control-center-readonly`，然后每次升级前后执行：

```bash
cd /srv/openclaw-control-center-readonly
./healthcheck.sh
./update.sh
```
