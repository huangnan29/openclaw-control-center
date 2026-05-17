# Tom 多实例只读控制中心运维脚本

这组脚本服务于 Tom 上的灰度部署目录：

```bash
/srv/openclaw-control-center-readonly
```

它们只更新、检查和回滚 OpenClaw Control Center 自身，不会修改任何 OpenClaw 实例目录。实例目录必须继续以 `:ro` 方式挂载。

## 脚本

- `healthcheck.sh`：检查 gateway 健康、总览页、实例详情页、写接口 403、容器只读安全边界。
- `update.sh`：拉取 `multi-instance-readonly-control-center` 分支，重建控制中心容器，随后执行健康检查。
- `rollback.sh`：回滚到指定提交；如果不传提交，则使用最近一次 `update.sh` 记录的 `previous-good.commit`。

## Tom 上的常用命令

```bash
cd /srv/openclaw-control-center-readonly
./healthcheck.sh
./update.sh
./rollback.sh <commit>
```

如果需要临时覆盖默认值，可以使用环境变量：

```bash
BASE_URL=http://127.0.0.1:4311 INSTANCE_IDS="main tom third deepseek spark" ./healthcheck.sh
BRANCH=multi-instance-readonly-control-center ./update.sh
```

## 验收标准

一次可接受的 Tom 灰度发布至少要满足：

- `./healthcheck.sh` 通过。
- 控制中心容器端口只绑定 `127.0.0.1:4311`。
- 容器未启用 `privileged`。
- 容器未挂载 `/var/run/docker.sock`。
- 所有实例目录挂载均为只读。
- `PATCH /api/ui/preferences` 返回 403。
