# 常见问题与最佳实践 / FAQ & Best Practices

> Looking for English? See [FAQ Guide (English)](#english-version) below.

## 中文版

### 1. 多 Agent 工作区 — 为什么成员列表看不到职责 / 显示“工作区未写明职责”？

**问题：** 已经在 `SOUL.md` 和 `AGENTS.md` 中写好了角色和职责，但控制中心的员工页面看不到具体分工。

**直接回答：** 员工页当前不会直接把某个配置文件里的 `role` / `mission` 字段原样摘出来显示。它更依赖 workspace 目录、`IDENTITY.md` 这类身份线索，以及 Gateway 返回的运行时元信息。

**常见原因：** 控制中心会参考 OpenClaw 的 workspace 目录和运行时信号。是否能看到完整职责信息，通常取决于：
- OpenClaw Gateway 返回的 session 数据中是否包含 agent 元信息
- `OPENCLAW_WORKSPACE_ROOT` 和 `openclaw.json` 里的 agent `workspace` 配置是否能让控制中心找到每个 agent 的真实工作目录

**解决方法：**

1. **确认 workspace 目录结构正确：**
   ```
   workspace-你的agent名/
   ├── SOUL.md          # 性格和角色定义
   ├── IDENTITY.md      # 名字、emoji 等身份信息
   ├── AGENTS.md        # 多 agent 协作规则
   └── MEMORY.md        # 长期记忆
   ```

2. **检查多 Agent 工作区定位方式：**
   ```bash
   # 标准布局：workspace/agents/<agentId>
   export OPENCLAW_WORKSPACE_ROOT=/path/to/.openclaw/workspace
   ```

   如果你的目录不是默认的 `workspace/agents/<agentId>`，而是像：
   ```text
   /path/to/.openclaw/workspace/a
   /path/to/.openclaw/workspace/b
   ```
   那就不要只设置根目录；还需要在 `openclaw.json` 里给每个 agent 明确写出 `workspace`：
   ```json
   {
     "agents": {
       "list": [
         { "id": "main", "workspace": "/path/to/.openclaw/workspace" },
         { "id": "a", "workspace": "/path/to/.openclaw/workspace/a" },
         { "id": "b", "workspace": "/path/to/.openclaw/workspace/b" }
       ]
     }
   }
   ```

   **控制中心当前的规则是：**
   - 优先使用 `openclaw.json` 里每个 agent 自己的 `workspace`
   - 如果没写，才回退到 `<OPENCLAW_WORKSPACE_ROOT>/agents/<agentId>`
   - 所以像 `workspace/a`、`workspace/b` 这种自定义布局，如果不写 agent 级 `workspace`，控制中心是没法凭空猜到的

3. **确认 Gateway 正在运行：**
   ```bash
   openclaw gateway status
   ```
   控制中心通过 Gateway API 获取 agent 列表和状态。如果 Gateway 没运行，员工页会显示空白或错误。

4. **员工页信息通常会参考这些来源：**
   - **名字/emoji** → 常见做法是放在 `IDENTITY.md`
   - **状态（执行中/空闲）** → 主要来自 Gateway 的 session 运行信号
   - **workspace** → 通常来自 agent 配置中的 `workspace` 字段
   - **具体职责描述** → 当前不会自动把 `SOUL.md` 摘要直接显示成员工卡片文案，更适合作为文档线索保存在 `IDENTITY.md`、`SOUL.md`、`AGENTS.md`
   - **不会直接摘取的内容** → 任意配置文件里自定义的 `role` / `mission` 文本，目前不会被员工卡片逐字渲染成职责说明

> **最佳实践：** 如果你希望控制中心更容易展示身份与职责线索，建议优先把简短身份说明写进 `IDENTITY.md`，并把详细角色说明写进 `SOUL.md` / `AGENTS.md`。

---

### 1.1 多 Agent workspace 目录怎么识别？

**直接回答：** 控制中心支持两种常见方式：
- 默认布局：`<workspaceRoot>/agents/<agentId>`
- 自定义布局：在 `openclaw.json` 里给每个 agent 明确写 `workspace`

**如果你的目录长这样：**
```text
workspace/
├── a/
├── b/
└── shared-files...
```

那就要显式配置：
```json
{
  "agents": {
    "list": [
      { "id": "main", "workspace": "/abs/path/workspace" },
      { "id": "a", "workspace": "/abs/path/workspace/a" },
      { "id": "b", "workspace": "/abs/path/workspace/b" }
    ]
  }
}
```

**不要只依赖：**
- `OPENCLAW_WORKSPACE_ROOT=/abs/path/workspace`

因为如果 agent 自己没有单独的 `workspace` 字段，控制中心会默认回退到：
```text
/abs/path/workspace/agents/a
/abs/path/workspace/agents/b
```

---

### 1.2 协作大厅 / 任务房间 — 现在可以直接上传附件吗？

**直接回答：** 目前还**不支持**在 hall / task room 里直接上传本地文件作为消息附件。

**现在支持什么：**
- agent 在执行过程中可以把产物作为 `artifactRefs` 回写到协作流里
- 你也可以先把文件放到外部可访问的位置，再把链接贴进 hall / room
- 头像上传是单独的设置页能力，不等同于协作消息附件

**建议做法：**
1. 先把文件放到仓库、对象存储、可访问的 URL，或任务产物路径里
2. 再把链接 / 路径贴到 hall 或 task room
3. 如果后续要做“直接上传附件”，它会是一个单独的协作功能，不是当前版本已经隐藏存在的入口

---

### 2. 订阅/账单 — 数据怎么接？限额在哪设置？

**问题：** 用量页面有费用数据，但不知道这些数据从哪来、限额怎么设置。

**数据来源（常见情况）：**

控制中心的主要用量数据通常来自 OpenClaw Gateway，不需要额外接入第三方账单系统。

```
OpenClaw Gateway → 记录每次 API 调用的 token 用量
                 → 根据模型定价计算费用
                 → 控制中心通过 API 拉取显示
```

**限额设置方式（最佳实践）：**

预算/限额通常在你的 OpenClaw 配置里设置，而不是在控制中心 UI 里直接填写。具体字段名和写法，请以你当前使用的 OpenClaw 版本与官方文档为准。

下面这段可以作为**常见示例**理解，不要把它当成所有环境都完全一致的唯一标准：

```yaml
# 常见示例：在 OpenClaw 配置中设置 budget
# 具体字段请以你的 OpenClaw 版本为准

budget:
  # Token 限额
  tokensIn: 1000000
  tokensOut: 500000
  totalTokens: 1500000

  # 费用限额（美元）
  cost: 50.00

  # 预警比例（达到此比例时发出警告）
  warnRatio: 0.8
```

**控制中心显示的内容：**
- **用量页 → Token 消耗：** 按 agent、按模型、按时间段的 token 使用
- **用量页 → 费用：** 基于模型定价的预估费用
- **用量页 → 上下文压力：** 哪些 session 接近上下文窗口上限
- **总览页 → 预算摘要：** 当前用量 vs 限额的进度条

> **最佳实践：** 如果你希望控制中心看到更完整的一致用量，建议尽量通过 OpenClaw Gateway 统一管理 API 调用。

---

### 2.1 某个实例 token 持续上涨，怎么判断是不是 heartbeat 在烧？

**问题：** 用量页看到某个实例一直增加 token，但没有明显任务在跑。

**先看页面：**

打开用量页并筛选实例，例如：

```text
https://openclaw.ananclaw.com/?section=usage-cost&usage_instance=deepseek&lang=zh
```

如果页面出现 **异常用量线索**，重点看三项：

- **线索：** `周期性小额增长` 或 `最近突增`
- **节奏：** 例如 `30 分钟`
- **中位增量：** 例如每次约 `280 token`

这类模式通常说明某个定时检查、heartbeat poll 或自动轮询在反复触发模型调用。

**再用服务器只读复核：**

```bash
cd /srv/openclaw-control-center-readonly
repo/ops/tom-readonly/heartbeat-burn-inspector.sh status deepseek
```

这个命令只读取 collector history 和只读挂载中的 `HEARTBEAT.md` 元数据，不会清空文件、不调用模型、不重启实例。

如果需要把它接成告警，可以用：

```bash
repo/ops/tom-readonly/heartbeat-burn-inspector.sh check deepseek
```

`check` 在发现可疑增长时会返回非 0。

Tom 上也可以安装只读告警 cron：

```bash
cd /srv/openclaw-control-center-readonly
repo/ops/tom-readonly/heartbeat-burn-alert-runner.sh run
repo/ops/tom-readonly/install-heartbeat-burn-alert-cron.sh status
repo/ops/tom-readonly/install-heartbeat-burn-alert-cron.sh plan
CONFIRM_HEARTBEAT_BURN_ALERT_CRON=I_UNDERSTAND_THIS_ONLY_INSTALLS_READONLY_HEARTBEAT_BURN_ALERT_CRON \
repo/ops/tom-readonly/install-heartbeat-burn-alert-cron.sh apply
```

告警 runner 只写 `runtime/heartbeat-burn-alerts/latest.json` 和 `events.ndjson`，不会修改 OpenClaw 实例目录，也不会清空 `HEARTBEAT.md`。

**处理原则：**

先确认 `HEARTBEAT.md` 是否非空，再人工决定是否清空或关闭该实例 heartbeat。不要让控制中心自动改 OpenClaw 实例文件；这一步应由 Anan 明确批准。

---

### 2.2 最终上线前，我应该看哪条短摘要？

在本机仓库运行：

```bash
cd /Users/anan/openclaw-control-center-git
FINAL_GO_LIVE_OUTPUT=summary \
OPENCLAW_TOPOLOGY_MODE=local-only \
ops/local/final-go-live-review.sh status
```

如果输出 `ready_for_human_approval_with_usage_alerts`，含义是最终 live healthcheck 的 approval packet、approval 状态和 cron 前置条件都已就绪，但当前仍有 heartbeat/token 用量告警。用量告警不会自动清空实例文件，也不会替你批准 live healthcheck。

---

### 3. 会话停滞检测 — 怎么判定的？

**问题：** 控制中心显示某个会话"停滞执行"，但找不到是哪个会话，也不确定判定标准。

**判定逻辑（控制中心视角）：**

控制中心会根据当前拿到的运行信号，把会话整理成类似下面这些可读状态：

| 状态 | 英文 | 判定条件 |
|------|------|----------|
| 执行中 | `running` | 会话有活跃的 API 调用或工具执行 |
| 空闲 | `idle` | 会话存在但没有活跃任务 |
| 阻塞 | `blocked` | 会话等待外部输入或资源 |
| 等待审批 | `waiting_approval` | 会话需要用户手动确认才能继续 |
| 错误 | `error` | 会话遇到错误 |

**“停滞执行”通常表示：** 控制中心看到某个会话仍在运行态，但最近缺少新的活动信号，因此将它标记为疑似停滞。常见参考信号包括：

1. **Gateway 层面：** OpenClaw Gateway 跟踪每个 session 的最后活跃时间
2. **控制中心层面：** 定期轮询 Gateway，比较 `running` 状态会话的最后活跃时间
3. **健康检查：** 某些环境里还会结合健康状态或 freshness 信号

**如何进一步确认：**
```bash
# 查看所有 running 状态的 sessions
openclaw sessions list --filter running

# 查看特定 session 的详情
openclaw sessions history <session-key> --limit 5
```

**常见处理方式：**
- 如果是 heartbeat 检查导致的误判，先回到会话详情看最近活动
- 如果确实停滞了，可以尝试手动发消息恢复：
  ```bash
  openclaw sessions send <session-key> "继续"
  ```
- 如果仍无进展，再考虑终止或重启对应 session

> **最佳实践：** 把这套流程理解成控制中心视角下的排查建议更合适，不要把它当成所有 OpenClaw 环境都完全一致的唯一底层判定标准。

---

### 3.1 Docker 部署时，为什么容器里连不上宿主机上的 Gateway？

**最常见原因有两个：**
- 容器里并不能自动解析宿主机地址，需要显式加 `host.docker.internal`
- 把内网直连地址写成了 `wss://...`，但 Gateway 端点本身并没有做 TLS，或者证书与该主机名 / IP 不匹配

**推荐做法：**

1. 在 `docker-compose.example.yml` 里保留：
   ```yaml
   extra_hosts:
     - "host.docker.internal:host-gateway"
   ```

2. 宿主机直连时优先使用：
   ```env
   GATEWAY_URL=ws://host.docker.internal:18789
   ```

3. 只有当 Gateway 前面真的有 TLS 终止层，并且证书与域名匹配时，再改成 `wss://...`

> **经验判断：** 如果你现在用的是 `wss://172.x.x.x:18789/...` 这类裸 IP 地址，连不上时先不要怀疑控制中心本身，优先检查 TLS / 证书匹配和 Docker 主机映射。

**快速自检：**
```bash
docker compose exec control-center getent hosts host.docker.internal
docker compose exec control-center printenv GATEWAY_URL
```

如果第一条没有解析出宿主机地址，或者第二条还是 `wss://172.x.x.x:18789/...` 这类裸 IP TLS 地址，优先先改配置，再看控制中心诊断页。

---

## English Version

### 1. Multi-Agent Workspace — Why Does the Staff Page Show "Role not defined in workspace"?

**Issue:** Roles defined in `SOUL.md` and `AGENTS.md` don't appear in the Control Center staff list.

**Short answer:** The Staff page does not currently render an arbitrary `role` or `mission` field from one config file verbatim. It relies more on workspace discovery, identity hints such as `IDENTITY.md`, and runtime metadata returned by Gateway.

**Common guidance / best practice:**
- Ensure your workspace directory follows the standard structure (`SOUL.md`, `IDENTITY.md`, `AGENTS.md`, `MEMORY.md`)
- Set `OPENCLAW_AGENT_ROOT` environment variable to point to the parent directory of all workspaces
- Confirm OpenClaw Gateway is running (`openclaw gateway status`)
- A practical best practice is to put short identity/role hints in `IDENTITY.md`, and longer role definitions in `SOUL.md` / `AGENTS.md`
- Do not expect a custom `role` / `mission` field from an arbitrary config file to appear as the exact Staff-card responsibility text

### 2. Billing & Budget — How to Connect Data and Set Limits?

**Data source (common case):** Most usage data shown in the Control Center comes from OpenClaw Gateway. No third-party billing integration is usually required.

**Setting limits:** A common best practice is to configure budget thresholds in your OpenClaw config. The exact field names depend on your OpenClaw version and setup.

The example below is a common pattern, not a universal schema for every environment:
```yaml
budget:
  totalTokens: 1500000
  cost: 50.00
  warnRatio: 0.8
```

### 3. Session Stall Detection — How Does It Work?

A session is usually treated as "stalled" when the Control Center still sees it as running but recent activity signals stop updating for a while. Use `openclaw sessions list --filter running` to review candidates.

Best-practice next step: inspect recent session activity first, then optionally send a message to the session (`openclaw sessions send <key> "continue"`). If it still does not recover, terminate or restart the session. Treat this as operator guidance from the Control Center perspective, not as the only possible OpenClaw runtime rule.
