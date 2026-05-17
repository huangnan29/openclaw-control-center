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
- `update.sh`：拉取 `multi-instance-readonly-control-center` 分支，重建控制中心容器，随后执行健康检查。
- `rollback.sh`：回滚到指定提交；如果不传提交，则使用最近一次 `update.sh` 记录的 `previous-good.commit`。
- `managed-action-healthcheck-rollout.example.json`：只读 healthcheck live 演练的 rollout 样板，不会被默认加载。
- `live-healthcheck-approval.sh`：生成或校验 live healthcheck 人工批准记录，不调用 live API。
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
./update.sh
./rollback.sh <commit>
repo/ops/tom-readonly/live-healthcheck-approval.sh prepare runtime/live-healthcheck-approval.json
repo/ops/tom-readonly/live-healthcheck-approval.sh status runtime/live-healthcheck-approval.json
repo/ops/tom-readonly/live-healthcheck-approval.sh check runtime/live-healthcheck-approval.json
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

只读 healthcheck live 演练必须先人工准备 live gate、executor 和 rollout 配置；默认 Tom 不启用。确认后才可手动运行：

```bash
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
# 人工编辑 runtime/live-healthcheck-approval.json：
# - approved=true
# - approvedAt=<当前 ISO 时间>
# - approvedBy=<批准人>
# - checklist 全部为 true
repo/ops/tom-readonly/live-healthcheck-approval.sh status runtime/live-healthcheck-approval.json
repo/ops/tom-readonly/live-healthcheck-approval.sh check runtime/live-healthcheck-approval.json

CONFIRM_LIVE_HEALTHCHECK_WINDOW=I_UNDERSTAND_THIS_TEMPORARILY_ENABLES_LIVE_GATE \
CONFIRM_LIVE_HEALTHCHECK=I_UNDERSTAND_THIS_CALLS_LIVE_API \
LOCAL_API_TOKEN=<本地令牌> \
INSTANCE_ID=tom \
OPERATOR=Anan \
repo/ops/tom-readonly/live-healthcheck-window.sh run
```

`run` 模式会自动生成 before/after 实例影响快照，位置默认为：

```bash
/srv/openclaw-control-center-readonly/runtime/impact-snapshots/
```

快照比较要求演练后恢复为只读状态、gateway 健康保持正常、监听端口保持稳定、实例挂载仍是只读、live gate 和 executor 均关闭。

`run` 成功后还会生成演练报告，位置默认为：

```bash
/srv/openclaw-control-center-readonly/runtime/live-healthcheck-reports/
```

报告通过条件包括：approval 已批准、dry-run 审计存在、live result 审计为 `executed`、`mutatesOpenClawInstance=false`，以及 after 快照恢复只读。

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
