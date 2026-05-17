# Tom collector 快照定时化计划

## 目标

让 Tom 上的只读 collector 快照进入可持续运行状态：

- 安装幂等 cron 任务，定时执行 `collector-snapshot.sh`。
- `healthcheck.sh` 检查 `collectorSnapshotPath` 快照是否存在、可解析、未过期。
- 文档明确安装、覆盖、验收和回滚方式。

## 不做

- 不新增写操作或管理动作。
- 不接入 Tom 之外的 Oracle 服务器。
- 不引入 HTTP collector 服务。
- 不改变 OpenClaw 实例目录的只读挂载边界。

## 步骤

1. 先在 readiness 测试中加入 cron 脚本、环境变量和 freshness gate 断言，并确认测试失败。
2. 新增 `ops/tom-readonly/install-collector-cron.sh`，使用标记块幂等更新 crontab。
3. 更新 `ops/tom-readonly/healthcheck.sh`，检查配置了 `collectorSnapshotPath` 的服务器快照新鲜度。
4. 更新 `.env.example`、`docs/MULTI_INSTANCE_READONLY.md`、`ops/tom-readonly/README.md` 和 `task.md`。
5. 运行定向测试和 build。
6. 提交推送并部署到 Tom。
7. 在 Tom 安装 cron，手动刷新一次快照，再运行健康检查。
