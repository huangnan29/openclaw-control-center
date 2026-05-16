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
