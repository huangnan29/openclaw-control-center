# 只读多实例控制中心设计

## 背景

当前 `openclaw-control-center` 面向单个 OpenClaw 运行环境：配置里只有一套 `GATEWAY_URL`、一套 `OPENCLAW_HOME`、一套 `OPENCLAW_CONFIG_PATH` 和一份 `runtime/last-snapshot.json`。这适合本地单实例控制台，但无法直接满足 Oracle Tom 上多套 OpenClaw 实例的统一管理需求。

Tom 服务器当前至少存在以下 OpenClaw 实例目录：

- `/srv/openclaw`
- `/srv/openclaw-work`
- `/srv/openclaw-third`
- `/srv/openclaw-spark`
- `/srv/openclaw-deepseek`

第一版目标是把控制台升级为严格只读的多实例观察台：能看到所有实例的总体状态，也能进入任一实例的完整详情页，但不执行任何写操作。

## 目标

- 支持通过配置声明多个 OpenClaw 实例。
- 首页提供多实例总览，展示每个实例的健康、会话、阻塞、错误、审批和 cron 概况。
- 保留现有完整详情页能力，并通过 `?instance=<id>&section=<section>` 进入指定实例上下文。
- 未配置多实例时继续沿用当前单实例模式，避免破坏现有用户。
- 第一版强制只读，禁止审批、任务派发、导入变更、heartbeat、文档保存和记忆保存。

## 非目标

- 不做 Oracle 云主机创建、开关机、扩容或安全组管理。
- 不替代 Prometheus/Grafana/Node exporter 的基础设施监控。
- 不支持跨实例写操作。
- 不在第一版实现 approve/reject、agent run、import live mutation、task heartbeat 或 hall runtime dispatch。
- 不挂载 Docker socket，不要求容器 privileged。

## 配置设计

新增两种多实例配置入口：

- `OPENCLAW_INSTANCES_FILE`：指向 JSON 文件。
- `OPENCLAW_INSTANCES_JSON`：直接内联 JSON，适合轻量部署。

文件和环境变量使用相同结构：

```json
{
  "instances": [
    {
      "id": "main",
      "name": "Main",
      "openclawHome": "/instances/main/config",
      "workspaceRoot": "/instances/main/workspace",
      "gatewayUrl": "ws://127.0.0.1:18789"
    },
    {
      "id": "tom",
      "name": "Tom / Work",
      "openclawHome": "/instances/tom/config",
      "workspaceRoot": "/instances/tom/workspace",
      "gatewayUrl": "ws://127.0.0.1:18790"
    }
  ]
}
```

实例字段规则：

- `id`：必填，只允许小写字母、数字、短横线和下划线，用于 URL、缓存键和日志。
- `name`：必填，显示名称。
- `openclawHome`：必填，指向该实例的 OpenClaw home/config 挂载目录。
- `workspaceRoot`：可选；缺省时从 `openclaw.json` 推断，推断失败则使用 `<openclawHome>/workspace`。
- `gatewayUrl`：可选；第一版主要用于展示和未来扩展，不开启跨实例写控制。

兼容策略：

- 如果没有配置 `OPENCLAW_INSTANCES_FILE` 或 `OPENCLAW_INSTANCES_JSON`，系统自动生成一个 `default` 实例，使用现有 `GATEWAY_URL`、`OPENCLAW_HOME`、`OPENCLAW_CONFIG_PATH` 和 `OPENCLAW_WORKSPACE_ROOT`。
- 如果配置文件存在但解析失败，控制台应启动并显示配置错误状态，不应该崩溃退出。
- 如果某个实例目录不可读，只标记该实例为 `partial` 或 `not_connected`，不影响其他实例显示。

## 数据模型

新增类型：

```ts
export type InstanceConnectionStatus = "connected" | "partial" | "not_connected";

export interface OpenClawInstanceConfig {
  id: string;
  name: string;
  gatewayUrl?: string;
  openclawHome: string;
  openclawConfigPath: string;
  workspaceRoot?: string;
}

export interface InstanceSnapshot {
  instance: OpenClawInstanceConfig;
  status: InstanceConnectionStatus;
  detail: string;
  snapshot: ReadModelSnapshot;
}

export interface MultiInstanceSnapshot {
  generatedAt: string;
  selectedInstanceId: string;
  instances: InstanceSnapshot[];
  totals: {
    instances: number;
    connected: number;
    partial: number;
    notConnected: number;
    sessions: number;
    running: number;
    blocked: number;
    errors: number;
    pendingApprovals: number;
    cronJobs: number;
  };
}
```

第一版不修改 `ReadModelSnapshot` 内部结构，避免牵动现有渲染、用量、任务和协作模块。多实例层只包裹多个 `ReadModelSnapshot`。

## 服务端架构

新增模块建议：

- `src/runtime/instance-config.ts`
  - 读取和校验多实例配置。
  - 提供单实例兼容 fallback。
  - 生成 `openclawConfigPath`。

- `src/clients/scoped-openclaw-live-client.ts`
  - 在单个实例上下文里读取 session、cron、approval 和 history。
  - 不依赖全局 `process.env.OPENCLAW_HOME`。
  - 第一版只读，不实现写操作；写操作统一返回安全错误。

- `src/adapters/multi-instance-readonly.ts`
  - 为每个实例构建只读 snapshot。
  - 聚合为 `MultiInstanceSnapshot`。
  - 单个实例失败时保留错误状态，继续返回其他实例结果。

- `src/runtime/multi-instance-summary.ts`
  - 计算总览卡需要的 connected/partial/not_connected、running、blocked、errors、pending approvals、cron jobs。

现有 `OpenClawReadonlyAdapter` 可继续作为单实例 adapter。多实例 adapter 内部可以复用它，也可以直接复用相同 map/summary 函数。

## UI 设计

首页行为：

- 如果配置了多实例，默认首页显示多实例总览。
- 总览顶部展示全局健康摘要。
- 每个实例一张状态卡：
  - 名称和 id
  - 连接状态
  - running / blocked / errors / pending approvals / cron jobs
  - 最近 snapshot 时间
  - 进入详情按钮

详情页 URL：

```text
/?instance=tom&section=overview
/?instance=tom&section=team
/?instance=tom&section=tasks
/?instance=tom&section=usage
```

详情页行为：

- 现有 section 导航保留。
- 页面顶部增加实例切换器。
- 所有现有 dashboard section 使用选中实例的 `ReadModelSnapshot`。
- 如果 `instance` 参数不存在，默认选择配置列表第一个实例。
- 如果 `instance` 不存在，显示错误提示并提供返回总览入口。

## 安全设计

第一版强制只读：

- `READONLY_MODE=true`
- `APPROVAL_ACTIONS_ENABLED=false`
- `APPROVAL_ACTIONS_DRY_RUN=true`
- `IMPORT_MUTATION_ENABLED=false`
- `IMPORT_MUTATION_DRY_RUN=true`
- `TASK_HEARTBEAT_ENABLED=false`
- `HALL_RUNTIME_DISPATCH_ENABLED=false`
- `HALL_RUNTIME_DIRECT_STREAM_ENABLED=false`
- `LOCAL_TOKEN_AUTH_REQUIRED=true`

服务端还要在代码层防守：

- 多实例模式下写操作默认禁用。
- 文档和记忆保存接口在只读模式返回明确错误。
- approval action 在只读模式返回明确错误。
- hall runtime dispatch 在只读模式返回明确错误。

部署层安全要求：

- 所有 `/srv/openclaw*` 目录以只读方式挂载。
- 不挂载 `/var/run/docker.sock`。
- 不使用 `privileged: true`。
- UI 不直接暴露公网；先走本地端口、内网或反向代理鉴权。

## Tom 部署映射

建议 Tom 上挂载为：

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

对应配置：

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

## 测试策略

单元测试：

- `instance-config` 能解析文件配置、内联 JSON 和单实例 fallback。
- 无效 id、缺失必填字段、重复 id 能返回可读错误。
- 多实例聚合器在单个实例失败时不影响其他实例。
- 总览计数能正确聚合 running、blocked、errors、pending approvals 和 cron jobs。

UI smoke 测试：

- 多实例总览能渲染实例卡。
- `?instance=tom&section=overview` 能渲染选中实例详情。
- 无效实例 id 能显示错误和返回入口。
- 只读模式下写操作按钮或接口不会进入真实修改。

回归测试：

- 未配置多实例时，现有单实例 smoke 测试继续通过。
- `npm run build` 通过。
- `npm test` 通过。

## 风险与缓解

- 风险：`src/ui/server.ts` 文件很大，直接改动容易牵连广。
  - 缓解：多实例逻辑优先放到新模块，UI 只接入必要入口和渲染函数。

- 风险：现有模块读取全局 `process.env.OPENCLAW_HOME`。
  - 缓解：第一版先让多实例 summary 和详情 snapshot 走 scoped client；后续再逐步清理全局依赖。

- 风险：误开启写操作影响 OpenClaw 集群。
  - 缓解：第一版代码和部署双层只读，写接口在只读模式明确拒绝。

- 风险：某个实例文件权限不可读导致页面整体失败。
  - 缓解：实例级错误隔离，单实例失败只影响该卡片。

## 验收标准

- 本地可用 mock/fixture 配置启动多实例总览。
- 未配置多实例时，原单实例 UI 和测试保持兼容。
- 多实例总览可显示至少 5 个 Tom 实例卡片。
- 点击实例卡可进入该实例详情页。
- 所有写操作在第一版默认不可用。
- 构建和测试通过。
