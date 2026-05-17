# 当前任务记录

## 当前目标

最终上线 OpenClaw 控制中心：当前只有一台 Oracle，因此先完成 Tom 这一台 Oracle 上现有 OpenClaw 实例的只读监控与受控管理上线；实例数量可继续通过 registry/collector 扩展。跨服务器只读 collector 保留为后续显式 `OPENCLAW_TOPOLOGY_MODE=cross-server` 扩展项，不再作为当前上线阻塞。

## 本轮任务

单 Oracle 上线收口：把最终上线总闸门切到默认 `local-only` 拓扑，只管理当前 Oracle 上的实例；补齐本机新增实例的安全注册入口；跨服务器远端凭据检查改为显式可选模式。

## 本轮不做

- 不执行任何真实管理动作。
- 不修改任何 OpenClaw 实例目录。
- 不重启、不停止、不发布、不触发任何 OpenClaw 实例任务。
- 不让中央控制中心直接挂载远端实例目录。

## 当前下一步

Tom 单 Oracle 上线下一步：

- 每次判断最终上线距离时，先在本机运行总控状态入口：
  `ops/local/final-go-live-status.sh status`
- 需要同时验证 Tom 现有实例只读安全边界时，运行：
  `ops/local/final-go-live-status.sh check`
- 当前默认 `OPENCLAW_TOPOLOGY_MODE=local-only`，不要求第二台 Oracle host/key；如果未来要接第二台 Oracle，再显式运行：
  `OPENCLAW_TOPOLOGY_MODE=cross-server ops/local/final-go-live-status.sh check`
- 本机实例扩展已走显式安全脚本：
  `repo/ops/tom-readonly/register-local-instance.sh plan runtime/register-local-instance.json`
  确认后再运行：
  `CONFIRM_LOCAL_INSTANCE_REGISTER=I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_LOCAL_REGISTRY repo/ops/tom-readonly/register-local-instance.sh apply runtime/register-local-instance.json`
  然后只重建 control-center 容器、刷新 collector snapshot，并跑 `./healthcheck.sh`。
- 当前 managed action dry-run 证据已存在；local-only healthcheck 通过后，下一阶段统一走 runner 主链路：先自动准备证据包并停在人工 approval 前，人工批准后再显式运行一次性 live healthcheck 演练。
- 查看 live healthcheck 下一步 readiness：
  `repo/ops/tom-readonly/live-healthcheck-readiness.sh status`
  需要同时验证 Tom 现有实例只读健康时运行：
  `repo/ops/tom-readonly/live-healthcheck-readiness.sh check`
  readiness 脚本只读汇总总闸门、dry-run、证据包、approval 和 live window；它输出的下一步已统一指向 `live-healthcheck-rollout-runner.sh prepare/run-approved` 主链路，不生成证据包、不写 approval、不打开 live gate。
- 自动推进到人工批准前：
  `ops/local/final-go-live-runner.sh prepare`
  该本机总 runner 会先跑最终上线 `check`，确认 Tom 现有实例健康且下一步确实是 Tom runner prepare 后，才 SSH 到 Tom 执行准备动作并复核最终状态。
- Tom 侧自动推进到人工批准前：
  `repo/ops/tom-readonly/live-healthcheck-rollout-runner.sh prepare`
  该 runner 会检查 dry-run、准备 approval 模板、生成并校验证据包、刷新 readiness，然后停在人工批准前；不会批准 approval、不会打开 live gate。
- 人工批准命令：
  `CONFIRM_APPROVAL_RECORD=I_APPROVE_LIVE_HEALTHCHECK_RECORD APPROVED_BY=Anan repo/ops/tom-readonly/live-healthcheck-approval.sh approve runtime/live-healthcheck-approval.json`
- 人工 approval 已批准后，自动执行一次性演练：
  `CONFIRM_FINAL_GO_LIVE_RUNNER=I_UNDERSTAND_THIS_RUNS_APPROVED_FINAL_GO_LIVE LOCAL_API_TOKEN=<本地令牌> ops/local/final-go-live-runner.sh run-approved`
  `CONFIRM_LIVE_HEALTHCHECK_RUNNER=I_UNDERSTAND_THIS_RUNS_APPROVED_LIVE_HEALTHCHECK LOCAL_API_TOKEN=<本地令牌> repo/ops/tom-readonly/live-healthcheck-rollout-runner.sh run-approved`
  该模式会先确认 readiness 为 `approved_ready_for_live_window`，否则不会打开 live gate，并以非 0 退出码让 openclaw 调度侧知道本次被人工批准边界挡住。

后续跨服务器扩展预留步骤：

- 为第二台 Oracle 服务器准备本地 collector exporter，让该服务器自行生成 collector JSON。
- 先在本机只读发现候选 SSH host/key：
  `ops/local/discover-remote-oracle-credentials.sh scan ops/local/discover-remote-oracle-credentials.example.json`
- 如果 scan 找到候选 host/key，可以显式确认后做只读 SSH 探测：
  `CONFIRM_REMOTE_ORACLE_DISCOVERY=I_UNDERSTAND_THIS_ONLY_PROBES_SSH_READONLY ops/local/discover-remote-oracle-credentials.sh probe ops/local/discover-remote-oracle-credentials.example.json`
- 找到可达候选后，直接生成本机 push 配置：
  `REMOTE_ORACLE_HOST=<可达候选 host> REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> ops/local/discover-remote-oracle-credentials.sh render-push-config ops/local/discover-remote-oracle-credentials.example.json > runtime/push-remote-collector-credentials.json`
- 或显式确认后只写本机 push 配置文件：
  `CONFIRM_REMOTE_ORACLE_PUSH_CONFIG_WRITE=I_UNDERSTAND_THIS_ONLY_WRITES_LOCAL_PUSH_CONFIG REMOTE_ORACLE_HOST=<可达候选 host> REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> ops/local/discover-remote-oracle-credentials.sh write-push-config ops/local/discover-remote-oracle-credentials.example.json`
- 如果已明确知道第二台 Oracle host/key，优先用 intake 编排器先预览再接入 Tom runtime：
  `REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> ops/local/remote-oracle-intake.sh doctor`
  `REMOTE_ORACLE_HOST=<可达候选 host> REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> ops/local/remote-oracle-intake.sh doctor`
  `REMOTE_ORACLE_HOST=<可达候选 host> REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> ops/local/remote-oracle-intake.sh plan`
  `CONFIRM_REMOTE_ORACLE_INTAKE=I_UNDERSTAND_THIS_WRITES_LOCAL_PUSH_CONFIG_AND_TOM_RUNTIME_ONLY REMOTE_ORACLE_HOST=<可达候选 host> REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> ops/local/remote-oracle-intake.sh apply`
- 要在凭据接入后自动触发 Tom 端安全 rollout runner，使用：
  `CONFIRM_REMOTE_ORACLE_INTAKE=I_UNDERSTAND_THIS_WRITES_LOCAL_PUSH_CONFIG_AND_TOM_RUNTIME_ONLY CONFIRM_REMOTE_ORACLE_INTAKE_RUNNER=I_UNDERSTAND_THIS_PUSHES_CREDENTIALS_AND_RUNS_TOM_SAFE_ROLLOUT REMOTE_ORACLE_HOST=<可达候选 host> REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> ops/local/remote-oracle-intake.sh run`
- 在 Tom 先复制 `repo/ops/tom-readonly/remote-collector-onboarding.example.json` 到 `runtime/remote-collector-onboarding.json`，填入第二台 Oracle 的 SSH 信息和实例路径。
- 任何阶段不确定下一步时，先运行：
  `repo/ops/tom-readonly/remote-collector-rollout.sh status runtime/remote-onboarding/<serverId>`
- 如果已经准备好真实远端凭据、onboarding、远端 snapshot 等前置条件，优先让 Tom 自动推进安全阶段：
  `CONFIRM_REMOTE_COLLECTOR_ROLLOUT_RUNNER=I_UNDERSTAND_THIS_RUNS_SAFE_REMOTE_COLLECTOR_ROLLOUT_STEPS repo/ops/tom-readonly/remote-collector-rollout-runner.sh run runtime/remote-onboarding/<serverId>`
- 每次判断最终上线距离时，先看总闸门：
  `repo/ops/tom-readonly/go-live-gate.sh status runtime/remote-onboarding/<serverId>`
- 需要同时验证 Tom 现有实例只读安全边界时，运行：
  `repo/ops/tom-readonly/go-live-gate.sh check runtime/remote-onboarding/<serverId>`
- 如果 rollout gate 返回 `needs_remote_credentials`，必须先补齐真实远端 host/user/port 和 Tom 上可读的只读 SSH key，不能用样板 `10.0.0.12` 硬跑 preflight。
- 如果远端只读 SSH key 还在本机，推荐先复制 `ops/local/push-remote-collector-credentials.example.json` 到 `runtime/push-remote-collector-credentials.json`，填入真实 `remote.sourceSshKeyPath` 后运行：
  `ops/local/push-remote-collector-credentials.sh plan runtime/push-remote-collector-credentials.json`
- 确认后运行：
  `CONFIRM_PUSH_REMOTE_COLLECTOR_CREDENTIALS=I_UNDERSTAND_THIS_ONLY_PUSHES_REMOTE_COLLECTOR_CREDENTIALS_TO_TOM_RUNTIME ops/local/push-remote-collector-credentials.sh apply runtime/push-remote-collector-credentials.json`
- 推荐先复制 `repo/ops/tom-readonly/remote-collector-credentials.example.json` 到 `runtime/remote-collector-credentials.json`，填入真实 `sourceSshKeyPath` 后运行：
  `repo/ops/tom-readonly/remote-collector-credentials.sh plan runtime/remote-collector-credentials.json`
- 确认后运行：
  `CONFIRM_REMOTE_COLLECTOR_CREDENTIALS=I_UNDERSTAND_THIS_ONLY_WRITES_CONTROL_CENTER_REMOTE_CREDENTIALS repo/ops/tom-readonly/remote-collector-credentials.sh apply runtime/remote-collector-credentials.json`
- 如果远端已经有可用的 control-center 源码目录，可以设置 `collectorNode.buildContext`；否则保持默认 `collectorNode.bundleBuildContext=true`，让接入包携带最小构建上下文。
- 先执行 `repo/ops/tom-readonly/remote-collector-onboarding.sh plan runtime/remote-collector-onboarding.json`，确认只生成接入包计划、不写文件。
- 确认后执行：
  `CONFIRM_REMOTE_COLLECTOR_ONBOARDING=I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_ONBOARDING_BUNDLE repo/ops/tom-readonly/remote-collector-onboarding.sh write runtime/remote-collector-onboarding.json`
- 写入后先执行：
  `repo/ops/tom-readonly/remote-collector-onboarding.sh verify runtime/remote-onboarding/<serverId>`
- verify 通过后执行远端只读 preflight：
  `repo/ops/tom-readonly/remote-collector-preflight.sh plan runtime/remote-onboarding/<serverId>`
- 确认后执行：
  `CONFIRM_REMOTE_COLLECTOR_PREFLIGHT=I_UNDERSTAND_THIS_ONLY_READS_REMOTE_PREREQUISITES repo/ops/tom-readonly/remote-collector-preflight.sh check runtime/remote-onboarding/<serverId>`
- preflight 通过后执行 rollout gate，确认阶段进入 `needs_remote_collector_pull`：
  `repo/ops/tom-readonly/remote-collector-rollout.sh status runtime/remote-onboarding/<serverId>`
- 审查 `runtime/remote-onboarding/<serverId>/RUNBOOK.md`、`collector-node.json`、`remote-collector-pull.sources.json`、`register-remote-collector.json`、`build-context-manifest.json` 和 `safety.json`。
- 先用 Tom 侧同步器审查远端 collector 节点同步计划：
  `repo/ops/tom-readonly/remote-collector-node-sync.sh plan runtime/remote-onboarding/<serverId>`
- 确认后只把接入包复制到远端 collector deploy 目录：
  `CONFIRM_REMOTE_COLLECTOR_NODE_SYNC=I_UNDERSTAND_THIS_ONLY_COPIES_COLLECTOR_BUNDLE_TO_REMOTE repo/ops/tom-readonly/remote-collector-node-sync.sh sync runtime/remote-onboarding/<serverId>`
- 在远端 collector deploy 目录内先执行 bootstrap plan：
  `CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_PLAN=I_UNDERSTAND_THIS_ONLY_RUNS_REMOTE_BOOTSTRAP_PLAN repo/ops/tom-readonly/remote-collector-node-sync.sh bootstrap-plan runtime/remote-onboarding/<serverId>`
- 确认后只写远端 collector-only 部署文件：
  `CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_WRITE=I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_COLLECTOR_NODE_FILES repo/ops/tom-readonly/remote-collector-node-sync.sh bootstrap-write runtime/remote-onboarding/<serverId>`
- 生成远端 collector snapshot：
  `CONFIRM_REMOTE_COLLECTOR_NODE_SNAPSHOT=I_UNDERSTAND_THIS_RUNS_REMOTE_COLLECTOR_SNAPSHOT_ONLY repo/ops/tom-readonly/remote-collector-node-sync.sh snapshot runtime/remote-onboarding/<serverId>`
- 安装远端 collector cron：
  `CONFIRM_REMOTE_COLLECTOR_NODE_CRON=I_UNDERSTAND_THIS_ONLY_INSTALLS_REMOTE_COLLECTOR_CRON repo/ops/tom-readonly/remote-collector-node-sync.sh install-cron runtime/remote-onboarding/<serverId>`
- 使用接入包里的 `remote-collector-pull.sources.json`，只配置远端 snapshot 路径和本地 `runtime/collectors/<serverId>/snapshot.json`。
- 先执行 `repo/ops/tom-readonly/remote-collector-pull.sh plan runtime/remote-onboarding/<serverId>/remote-collector-pull.sources.json` 审查来源。
- 只有确认远端 snapshot 文件存在后，才执行：
  `CONFIRM_REMOTE_COLLECTOR_PULL=I_UNDERSTAND_THIS_ONLY_READS_REMOTE_COLLECTOR_SNAPSHOTS repo/ops/tom-readonly/remote-collector-pull.sh pull runtime/remote-onboarding/<serverId>/remote-collector-pull.sources.json`
- pull 成功后执行 rollout gate，确认阶段进入 `needs_registry_register`：
  `repo/ops/tom-readonly/remote-collector-rollout.sh status runtime/remote-onboarding/<serverId>`
- 拉取成功后，使用接入包里的 `register-remote-collector.json`，先执行：
  `repo/ops/tom-readonly/register-remote-collector.sh plan runtime/remote-onboarding/<serverId>/register-remote-collector.json`
- 确认 registry diff 后再执行：
  `CONFIRM_REMOTE_COLLECTOR_REGISTER=I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_REGISTRY repo/ops/tom-readonly/register-remote-collector.sh apply runtime/remote-onboarding/<serverId>/register-remote-collector.json`
- register 成功后执行 rollout gate，确认阶段进入 `ready_for_healthcheck`。
- 最后运行 `./healthcheck.sh` 验收新增 server、collector snapshot 新鲜度和页面只读状态。
- 远端 server 的实例配置可以只写 `id` 和 `name`；只要 server 配置了 `collectorSnapshotPath`，中央会生成内部 `/collector/<serverId>/<instanceId>/config` 占位路径。

受控管理动作下一步仍是人工批准后执行一次只读 healthcheck live 演练：

- 先检查 dry-run 证据：
  `repo/ops/tom-readonly/managed-action-dry-run-gate.sh status`
- 如果没有有效 dry-run 审计，显式确认并带本地令牌创建 dry-run 记录：
  `CONFIRM_MANAGED_ACTION_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CREATES_DRY_RUN_AUDIT_RECORD LOCAL_API_TOKEN=<本地令牌> repo/ops/tom-readonly/managed-action-dry-run-gate.sh run`
- 使用 `repo/ops/tom-readonly/live-healthcheck-window.sh run`。
- 必须显式提供 `CONFIRM_LIVE_HEALTHCHECK_WINDOW`、`CONFIRM_LIVE_HEALTHCHECK` 和 `LOCAL_API_TOKEN`。
- 演练窗口会临时启用 control-center live healthcheck 配置，动作仍限制为 `healthcheck`。
- 必须先生成并批准 `runtime/live-healthcheck-approval.json`，通过 `live-healthcheck-approval.sh check` 后才允许打开窗口。
- 批准前先生成并校验 `live-healthcheck-approval-packet.sh generate/check` 证据包，确认总闸门、dry-run、approval、live window、当前 commit 和影响快照都在预期状态；`live-healthcheck-approval.sh approve` 已强制先校验证据包才写 approval，`live-healthcheck-window.sh enable/run` 也会先校验证据包，再校验 approval 文件。
- 可用 `live-healthcheck-readiness.sh status/check` 汇总当前是否为 `waiting_human_approval` 或 `approved_ready_for_live_window`。
- 可用 `live-healthcheck-rollout-runner.sh prepare` 自动完成证据包准备并停在人工批准前。
- 人工批准后可用 `live-healthcheck-rollout-runner.sh run-approved` 自动执行一次性 healthcheck live 演练。
- 推荐批准方式：
  `CONFIRM_APPROVAL_RECORD=I_APPROVE_LIVE_HEALTHCHECK_RECORD APPROVED_BY=Anan repo/ops/tom-readonly/live-healthcheck-approval.sh approve runtime/live-healthcheck-approval.json`
- 当前 Tom 已生成 approval 草稿，状态为 `needs_manual_approval`。
- 当前 Tom 已具备 `approve` 命令，但尚未执行批准命令。
- 脚本退出前必须恢复只读状态，并重新通过 `healthcheck.sh`。
- 脚本会自动生成 before/after 实例影响快照并比较。
- live 调用成功后会自动将 approval 标记为 `consumed=true`，再次演练必须重新 approve。
- 脚本成功后会自动生成 live healthcheck 演练报告，汇总 approval、dry-run 审计、live result 审计和影响快照；报告要求 approval 已批准且已使用。
- 未获得人工批准前，不执行 `/api/managed-actions/live`。

## 最近完成

- 已为 `ops/local/remote-oracle-intake.sh` 新增 `doctor` 模式。
- `remote-oracle-intake.sh doctor` 只读取本机 SSH config、host hint 和 key 文件元数据；如果显式提供 `REMOTE_ORACLE_HOST/REMOTE_ORACLE_KEY_PATH`，只离线渲染配置摘要，不写文件、不联网、不连接 Tom、不连接第二台 Oracle。
- `doctor` 会输出 `needs_remote_host`、`needs_remote_key`、`candidates_found` 或 `ready_for_apply`，并给出下一步 `plan/apply/run` 命令。
- 本机执行 `ops/local/remote-oracle-intake.sh doctor`，当前状态为 `needs_remote_host`；发现 3 个本机 key 候选，但没有发现第二台 Oracle host。
- 已验证 `npm test -- test/remote-oracle-intake.test.ts test/discover-remote-oracle-credentials.test.ts test/oss-readiness.test.ts`，21/21 通过。
- 已验证跨服务器只读、总闸门、dry-run、凭据接入和远端 collector 自动引导回归集，58/58 通过。
- 已验证 `npm run build`。
- 已新增 `ops/tom-readonly/remote-collector-node-sync.sh`，用于把 Tom 已生成并校验过的 onboarding 接入包同步到第二台 Oracle 的 collector deploy 目录。
- `remote-collector-node-sync.sh plan` 只读取 Tom 本地接入包，不联网、不写文件。
- `remote-collector-node-sync.sh sync` 必须设置 `CONFIRM_REMOTE_COLLECTOR_NODE_SYNC=I_UNDERSTAND_THIS_ONLY_COPIES_COLLECTOR_BUNDLE_TO_REMOTE`，只通过 SSH+tar 写远端 collector deploy 目录，不写 OpenClaw 实例目录。
- `bootstrap-plan/bootstrap-write` 分别需要显式确认；`bootstrap-write` 只执行远端接入包里的 `bootstrap-collector-node.sh write`，写 collector-only 部署文件，不启动容器、不安装 cron、不调用 live API。
- `snapshot/install-cron` 分别需要显式确认；`snapshot` 只启动/使用 collector-only 容器生成远端 snapshot，`install-cron` 只安装当前用户 crontab 中的 collector 受控块，二者都不修改 OpenClaw 实例目录、不调用 live API。
- 已让 `remote-collector-rollout.sh` 在 `needs_remote_collector_pull` 阶段输出 `remote-collector-node-sync.sh` 的 plan/sync/bootstrap/snapshot/cron 命令，减少后续手工复制和远端手工执行风险。
- 已让 `remote-collector-rollout-runner.sh` 在 `needs_remote_collector_pull` 阶段自动串联远端接入包同步、bootstrap plan/write、snapshot、cron 和 Tom 只读 pull；缺凭据、远端检查或 snapshot 失败时会停住。
- 已新增并扩展 `test/remote-collector-node-sync.test.ts`，覆盖 plan 不联网、sync 必须确认、bootstrap plan/write、snapshot/cron 仍保持 collector-only 边界。
- 已扩展 `test/remote-collector-rollout-runner.test.ts`，覆盖 runner 在 pull 前先准备远端 collector 节点并生成 snapshot。
- 已验证 `npm test -- test/remote-collector-node-sync.test.ts test/remote-collector-rollout-runner.test.ts test/remote-collector-rollout.test.ts test/go-live-gate.test.ts test/oss-readiness.test.ts`，20/20 通过。
- 已验证跨服务器只读、总闸门、dry-run、凭据接入和远端 collector 自动引导回归集，56/56 通过。
- 已验证 `bash -n ops/tom-readonly/remote-collector-node-sync.sh` 和 `bash -n ops/tom-readonly/remote-collector-rollout.sh`。
- 已验证 `npm test -- test/remote-collector-node-sync.test.ts test/oss-readiness.test.ts`，10/10 通过。
- 已验证跨服务器只读、总闸门、dry-run 和凭据接入回归集，54/54 通过。
- 已验证 `npm run build`。
- 已新增 `ops/local/remote-oracle-intake.sh`，作为本机侧第二台 Oracle 凭据接入编排器。
- `remote-oracle-intake.sh plan` 只渲染 push 配置摘要，不写文件、不联网、不连接 Tom、不连接第二台 Oracle。
- `remote-oracle-intake.sh apply` 必须设置 `CONFIRM_REMOTE_ORACLE_INTAKE=I_UNDERSTAND_THIS_WRITES_LOCAL_PUSH_CONFIG_AND_TOM_RUNTIME_ONLY`，只串联本机 push 配置写入和 Tom runtime 凭据推送。
- `remote-oracle-intake.sh apply` 不连接第二台 Oracle、不写 Tom registry、不修改任何 OpenClaw 实例目录、不调用 managed action live API。
- `remote-oracle-intake.sh run` 还必须设置 `CONFIRM_REMOTE_ORACLE_INTAKE_RUNNER=I_UNDERSTAND_THIS_PUSHES_CREDENTIALS_AND_RUNS_TOM_SAFE_ROLLOUT`，会在 `apply` 后触发 Tom 端 `remote-collector-rollout-runner.sh run`，继续推进已满足安全门禁的阶段。
- `remote-oracle-intake.sh run` 可能通过 Tom 对第二台 Oracle 做只读 preflight/pull，并可能更新 Tom control-center registry；它不会写远端实例目录、不会启动容器、不会调用 managed action live API。
- 已新增 `test/remote-oracle-intake.test.ts`，覆盖 plan 不写不推、apply 缺确认被拒、apply 只写本机配置并只推 Tom runtime、run 缺二次确认被拒、run 触发 Tom 安全 rollout。
- 已验证 `bash -n ops/local/remote-oracle-intake.sh`。
- 已验证 `npm test -- test/remote-oracle-intake.test.ts`，5/5 通过。
- 已验证 intake、rollout、发现、push 和 OSS 安全断言组合，24/24 通过。
- 已验证 intake、rollout、OSS 安全断言组合，16/16 通过。
- 已验证跨服务器只读上线相关回归集，51/51 通过。
- 已验证 `npm run build`。
- 已增强 `ops/local/discover-remote-oracle-credentials.sh`，新增 `write-push-config` 模式。
- `write-push-config` 必须设置 `CONFIRM_REMOTE_ORACLE_PUSH_CONFIG_WRITE=I_UNDERSTAND_THIS_ONLY_WRITES_LOCAL_PUSH_CONFIG`，只根据显式 `REMOTE_ORACLE_HOST` 和 `REMOTE_ORACLE_KEY_PATH` 写本机 `runtime/push-remote-collector-credentials.json`。
- `write-push-config` 不联网、不连接 Tom、不连接第二台 Oracle、不写 Tom runtime、不写 registry、不修改任何 OpenClaw 实例目录，也不输出私钥内容。
- `remote-collector-rollout.sh` 的 `needs_remote_credentials` 下一步提示已同步加入 `write-push-config`，避免总闸门继续引导手工复制样板。
- 已扩展 `test/discover-remote-oracle-credentials.test.ts`，覆盖 `write-push-config` 缺确认被拒、显式确认后只写本机 push 配置且不泄露 key 内容。
- 已验证 `bash -n ops/local/discover-remote-oracle-credentials.sh`。
- 已验证 `npm test -- test/discover-remote-oracle-credentials.test.ts test/push-remote-collector-credentials.test.ts test/oss-readiness.test.ts`，17/17 通过。
- 已验证 `bash -n ops/tom-readonly/remote-collector-rollout.sh`。
- 已验证 `npm test -- test/remote-collector-rollout.test.ts test/remote-collector-rollout-runner.test.ts test/discover-remote-oracle-credentials.test.ts test/oss-readiness.test.ts`，18/18 通过。
- 已验证跨服务器只读上线相关回归集，46/46 通过。
- 已验证 `npm run build`。
- 已新增 `ops/tom-readonly/managed-action-dry-run-gate.sh`，作为管理动作 dry-run 证据闸门。
- `managed-action-dry-run-gate.sh status` 只读取 readiness 与 dry-run audit，不写文件、不调用 live API。
- `managed-action-dry-run-gate.sh run` 必须设置 `CONFIRM_MANAGED_ACTION_DRY_RUN=I_UNDERSTAND_THIS_ONLY_CREATES_DRY_RUN_AUDIT_RECORD` 且提供 `LOCAL_API_TOKEN`，只调用 `/api/managed-actions/dry-run` 创建 dry-run 审计记录。
- `go-live-gate.sh` 已纳入 `managedActionDryRunEvidence` 阶段；跨服务器只读和现有实例 healthcheck 通过后，如果缺少有效 dry-run 审计，会先阻塞在 `blocked_managed_action_dry_run`。
- 已新增 `test/managed-action-dry-run-gate.test.ts`，覆盖已有有效审计、run 缺确认被拒、run 只调用 dry-run 不调用 live。
- 已扩展 `test/go-live-gate.test.ts`，覆盖总闸门在缺少 dry-run 证据时先阻塞 `blocked_managed_action_dry_run`。
- 已验证 `bash -n ops/tom-readonly/managed-action-dry-run-gate.sh` 与 `bash -n ops/tom-readonly/go-live-gate.sh`。
- 已验证 `npm test -- test/managed-action-dry-run-gate.test.ts test/go-live-gate.test.ts test/oss-readiness.test.ts`，14/14 通过。
- 已验证跨服务器只读上线相关回归集，44/44 通过。
- 已验证 managed action 核心回归集，16/16 通过。
- 已验证 `npm run build`。
- 已新增 `ops/local/discover-remote-oracle-credentials.sh` 和 `discover-remote-oracle-credentials.example.json`，用于本机只读发现第二台 Oracle 候选 SSH host/key。
- `discover-remote-oracle-credentials.sh scan` 只读取本机 SSH config 和候选 key 文件元数据，不联网、不写文件、不输出私钥内容。
- `discover-remote-oracle-credentials.sh probe` 必须设置 `CONFIRM_REMOTE_ORACLE_DISCOVERY=I_UNDERSTAND_THIS_ONLY_PROBES_SSH_READONLY`，只执行 `id -un`、`uname -n`、`uname -s` 这类只读 SSH 探测，不写远端文件、不写 Tom runtime。
- `discover-remote-oracle-credentials.sh render-push-config` 只根据显式 `REMOTE_ORACLE_HOST` 和 `REMOTE_ORACLE_KEY_PATH` 输出本机 push 配置 JSON，不联网、不写文件。
- 已增强 `test/discover-remote-oracle-credentials.test.ts`，覆盖 scan 不泄露 key 内容、host hint 文件抽取、probe 必须确认、probe 使用只读 SSH 参数、render-push-config 不泄露 key 内容。
- 已验证 `bash -n ops/local/discover-remote-oracle-credentials.sh`。
- 已验证 `npm test -- test/discover-remote-oracle-credentials.test.ts test/push-remote-collector-credentials.test.ts test/oss-readiness.test.ts`，15/15 通过。
- 已验证 `npm test -- test/discover-remote-oracle-credentials.test.ts test/go-live-gate.test.ts test/remote-collector-rollout-runner.test.ts test/push-remote-collector-credentials.test.ts test/remote-collector-credentials.test.ts test/remote-collector-rollout.test.ts test/remote-collector-preflight.test.ts test/remote-collector-onboarding.test.ts test/remote-collector-pull.test.ts test/register-remote-collector.test.ts test/collector-node-bootstrap.test.ts test/oss-readiness.test.ts`，40/40 通过。
- 已验证 `npm run build`。
- 本机执行 `ops/local/discover-remote-oracle-credentials.sh scan ops/local/discover-remote-oracle-credentials.example.json`，当前发现 3 个候选 key，但没有发现 Tom 以外的候选 host，状态为 `needs_remote_host`。
- 已新增 `ops/tom-readonly/go-live-gate.sh`，作为最终上线总闸门。
- `go-live-gate.sh status` 只汇总跨服务器 rollout runner 状态、managed action dry-run 证据与 live healthcheck window readiness，不运行 healthcheck、不写文件、不调用 live API。
- `go-live-gate.sh check` 会额外运行 `./healthcheck.sh`，用于验证 Tom 现有实例仍正常、只读边界仍有效。
- 总闸门会输出 `blocked_existing_instances`、`blocked_cross_server_readonly`、`ready_for_existing_instance_healthcheck`、`blocked_managed_actions` 或 `ready_for_live_healthcheck`，并附带下一步命令。
- 已新增 `test/go-live-gate.test.ts`，覆盖缺远端凭据、只读监控通过后进入管理动作阻塞、现有实例 healthcheck 失败时优先阻塞。
- 已验证 `bash -n ops/tom-readonly/go-live-gate.sh`。
- 已验证 `npm test -- test/go-live-gate.test.ts test/remote-collector-rollout-runner.test.ts test/oss-readiness.test.ts`，13/13 通过。
- 已验证 `npm test -- test/go-live-gate.test.ts test/remote-collector-rollout-runner.test.ts test/push-remote-collector-credentials.test.ts test/remote-collector-credentials.test.ts test/remote-collector-rollout.test.ts test/remote-collector-preflight.test.ts test/remote-collector-onboarding.test.ts test/remote-collector-pull.test.ts test/register-remote-collector.test.ts test/collector-node-bootstrap.test.ts test/oss-readiness.test.ts`，35/35 通过。
- 已验证 `npm run build`。
- 已新增 `ops/tom-readonly/remote-collector-rollout-runner.sh`，按 rollout gate 当前阶段自动调用 onboarding refresh、只读 preflight、只读 pull、registry register 和 healthcheck。
- `remote-collector-rollout-runner.sh status/plan` 只读取 rollout gate；`step/run` 必须设置 `CONFIRM_REMOTE_COLLECTOR_ROLLOUT_RUNNER=I_UNDERSTAND_THIS_RUNS_SAFE_REMOTE_COLLECTOR_ROLLOUT_STEPS`。
- runner 缺少 Tom 本地 `runtime/remote-collector-onboarding.json` 或真实远端 SSH key 时会停在 `needs_remote_credentials`，不会硬跑 SSH。
- 已新增 `test/remote-collector-rollout-runner.test.ts`，覆盖 status 只读代理、step 必须显式确认、刷新 onboarding 后推进到 preflight。
- 已验证 `bash -n ops/tom-readonly/remote-collector-rollout-runner.sh`。
- 已验证 `npm test -- test/remote-collector-rollout-runner.test.ts test/remote-collector-rollout.test.ts test/oss-readiness.test.ts`，11/11 通过。
- 已验证 `npm test -- test/remote-collector-rollout-runner.test.ts test/push-remote-collector-credentials.test.ts test/remote-collector-credentials.test.ts test/remote-collector-rollout.test.ts test/remote-collector-preflight.test.ts test/remote-collector-onboarding.test.ts test/remote-collector-pull.test.ts test/register-remote-collector.test.ts test/collector-node-bootstrap.test.ts test/oss-readiness.test.ts`，32/32 通过。
- 已验证 `npm run build`。
- 已尝试 `npm test` 全量套件；协作大厅相关用例出现多处失败并长时间未退出，已中断。失败集中在 hall execution / handoff / runtime-backed discussion，与本轮新增的跨服务器脚本链路无直接交叉，后续需要单独处理大厅测试稳定性。
- 已新增 `ops/tom-readonly/remote-collector-rollout.sh`，作为跨服务器只读 collector 接入总控闸门。
- 已新增 `ops/tom-readonly/remote-collector-credentials.sh` 和 `remote-collector-credentials.example.json`，用于把 Tom 本地已有的远端只读 SSH key 安装到 control-center runtime，并生成 `runtime/remote-collector-onboarding.json`。
- `remote-collector-credentials.sh plan` 不写文件、不联网；`apply` 必须设置 `CONFIRM_REMOTE_COLLECTOR_CREDENTIALS=I_UNDERSTAND_THIS_ONLY_WRITES_CONTROL_CENTER_REMOTE_CREDENTIALS`，只写 Tom control-center runtime，不 SSH、不写 registry、不修改实例目录。
- 已新增 `ops/local/push-remote-collector-credentials.sh` 和 `push-remote-collector-credentials.example.json`，用于从本机把远端只读 SSH key 和 onboarding 配置推送到 Tom control-center runtime。
- `push-remote-collector-credentials.sh plan` 不写文件、不联网；`apply` 必须设置 `CONFIRM_PUSH_REMOTE_COLLECTOR_CREDENTIALS=I_UNDERSTAND_THIS_ONLY_PUSHES_REMOTE_COLLECTOR_CREDENTIALS_TO_TOM_RUNTIME`，只通过 SSH 写 Tom runtime，不连接第二台 Oracle、不写 registry、不修改实例目录。
- 已新增 `test/push-remote-collector-credentials.test.ts`，覆盖 plan 不 SSH、apply 必须确认、payload 不在 SSH 命令行泄露、拒绝写出 Tom runtime。
- 已新增 `test/remote-collector-credentials.test.ts`，覆盖 plan 不写 runtime、apply 必须确认、key 权限 600、生成 onboarding config、默认拒绝覆盖和拒绝写出 runtime。
- `remote-collector-rollout.sh status/plan` 只读取 Tom 本地 onboarding bundle、preflight 状态、pull 状态、snapshot 和 registry，不 SSH、不写 registry、不写远端文件、不启动容器、不调用 live API。
- 已让 rollout gate 在 SSH key 缺失、source 未启用、host/user 缺失或 known_hosts 路径异常时停在 `needs_remote_credentials`，避免直接运行会失败的 SSH preflight。
- rollout gate 会输出 `needs_remote_credentials`、`needs_remote_preflight`、`needs_remote_collector_pull`、`needs_registry_register` 或 `ready_for_healthcheck`，并给出下一步命令。
- 已让 `remote-collector-preflight.sh check` 把结果写入 Tom 本地 `runtime/remote-preflight-state/<serverId>.json`，同时新增 `status` 模式用于只读查看。
- 已新增 `test/remote-collector-rollout.test.ts`，覆盖从缺 preflight 到 ready for healthcheck 的阶段推进。
- 已更新 `test/remote-collector-preflight.test.ts`，覆盖 preflight 状态文件与只读 status。
- 已验证 `bash -n ops/tom-readonly/remote-collector-preflight.sh` 和 `bash -n ops/tom-readonly/remote-collector-rollout.sh`。
- 已验证 `npm test -- test/remote-collector-preflight.test.ts test/remote-collector-rollout.test.ts test/remote-collector-onboarding.test.ts test/remote-collector-pull.test.ts test/register-remote-collector.test.ts test/oss-readiness.test.ts`，20/20 通过。
- 已验证 `bash -n ops/tom-readonly/remote-collector-credentials.sh`。
- 已验证 `npm test -- test/remote-collector-credentials.test.ts test/remote-collector-rollout.test.ts test/remote-collector-preflight.test.ts test/remote-collector-onboarding.test.ts test/remote-collector-pull.test.ts test/register-remote-collector.test.ts test/oss-readiness.test.ts`，24/24 通过。
- 已验证 `bash -n ops/local/push-remote-collector-credentials.sh`。
- 已验证 `npm test -- test/push-remote-collector-credentials.test.ts`，3/3 通过。
- 已验证 `npm test -- test/push-remote-collector-credentials.test.ts test/remote-collector-credentials.test.ts test/remote-collector-rollout.test.ts test/remote-collector-preflight.test.ts test/remote-collector-onboarding.test.ts test/remote-collector-pull.test.ts test/register-remote-collector.test.ts test/oss-readiness.test.ts`，27/27 通过。
- 已验证 `npm run build`。
- 已新增长期推进计划：`implementation_plan.md`。
- 已新增 `ops/tom-readonly/remote-collector-onboarding.sh`，用于在 Tom 生成第二台 Oracle 的只读 collector 接入包。
- 已新增 `ops/tom-readonly/remote-collector-onboarding.example.json` 样板。
- `remote-collector-onboarding.sh plan` 只校验配置并输出将生成的文件，不写文件、不 SSH。
- `remote-collector-onboarding.sh write` 必须设置 `CONFIRM_REMOTE_COLLECTOR_ONBOARDING=I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_ONBOARDING_BUNDLE`，只写 `runtime/remote-onboarding/<serverId>/` 下的接入包。
- 接入包包含 `collector-node.json`、`bootstrap-collector-node.sh`、`remote-collector-pull.sources.json`、`register-remote-collector.json`、`RUNBOOK.md` 和 `safety.json`。
- 已新增 `test/remote-collector-onboarding.test.ts`，覆盖 plan 不写文件、write 必须确认、只写 onboarding 目录、拒绝越界 outputDir、生成接入包可跑远端 bootstrap plan。
- 已验证 `bash -n ops/tom-readonly/remote-collector-onboarding.sh`。
- 已验证 `npm test -- test/remote-collector-onboarding.test.ts test/oss-readiness.test.ts`，10/10 通过。
- 已验证 `ops/tom-readonly/remote-collector-onboarding.sh plan ops/tom-readonly/remote-collector-onboarding.example.json`，输出 `writesActiveRegistry=false`、`connectsSsh=false`、`mutatesOpenClawInstance=false`、`callsLiveApi=false`。
- 已验证 `npm test -- test/remote-collector-onboarding.test.ts test/register-remote-collector.test.ts test/remote-collector-pull.test.ts test/collector-node-bootstrap.test.ts test/oss-readiness.test.ts`，16/16 通过。
- 已验证 `npm test -- test/multi-instance-readonly.test.ts test/readonly-multi-instance-safety.test.ts test/ui-render-smoke.test.ts`，39/39 通过。
- 已验证 `npm run build`。
- 已提交并推送 `43a6abc ops: bundle remote collector onboarding`。
- 已部署到 Tom，并验证运行提交 `43a6abc`。
- 已在 Tom 验证 `remote-collector-onboarding.sh plan` 返回 `writesActiveRegistry=false`、`connectsSsh=false`、`mutatesOpenClawInstance=false`、`callsLiveApi=false`，未执行 write，未生成真实接入包。
- 已验证 Tom `healthcheck.sh` 通过，现有 5 个实例仍只读；live window status 仍为 `needs_manual_approval`、`READONLY_MODE=true`、`readiness.status=blocked`，未调用 live API。
- 已让 `remote-collector-onboarding.sh` 在未配置 `collectorNode.buildContext` 时默认生成 `build-context/` 和 `build-context-manifest.json`，并把生成的 `collector-node.json` 指向远端 `/srv/openclaw-collector-node/build-context`。
- build context 只包含构建 collector image 所需的最小文件：`Dockerfile`、`.dockerignore`、`package.json`、`package-lock.json`、`tsconfig.json`、`.env.example`、`README*`、`HALL.md`、`src/`、`scripts/` 和 `docs/`。
- 已更新 onboarding RUNBOOK，复制接入包时会带上 `build-context/`，远端执行前会放入 collector deploy 目录。
- 已新增测试覆盖无显式 `buildContext` 时自动打包 build context、生成 manifest、更新 collector-node `buildContext` 和 safety 记录。
- 已验证 `ops/tom-readonly/remote-collector-onboarding.sh plan ops/tom-readonly/remote-collector-onboarding.example.json` 返回 `warnings=[]`、`bundlesBuildContext=true`、`remoteBuildContext=/srv/openclaw-collector-node/build-context`、`buildContextFiles=88`。
- 已验证 `npm test -- test/remote-collector-onboarding.test.ts test/register-remote-collector.test.ts test/remote-collector-pull.test.ts test/collector-node-bootstrap.test.ts test/oss-readiness.test.ts`，17/17 通过。
- 已验证 `npm test -- test/multi-instance-readonly.test.ts test/readonly-multi-instance-safety.test.ts test/ui-render-smoke.test.ts`，39/39 通过。
- 已验证 `npm run build`。
- 已提交并推送 `1e9adcb ops: bundle remote collector build context`。
- 已部署到 Tom，并验证运行提交 `1e9adcb`。
- 已在 Tom 验证 onboarding 样板 `plan` 返回 `warnings=[]`、`bundlesBuildContext=true`、`remoteBuildContext=/srv/openclaw-collector-node/build-context`、`buildContextFiles=88`，未执行 write，未生成真实接入包。
- 已验证 Tom `healthcheck.sh` 通过，现有 5 个实例仍只读；live window status 仍为 `needs_manual_approval`、`READONLY_MODE=true`、`readiness.status=blocked`，未调用 live API。
- 已新增 `remote-collector-onboarding.sh verify <bundle-dir>`，只读取已生成接入包并离线校验，不 SSH、不写文件、不改 registry。
- `verify` 会校验必需文件、serverId 一致性、safety 布尔边界、pull/register 路径、build-context manifest，并调用接入包内 `bootstrap-collector-node.sh plan` 确认不启动容器、不修改实例。
- 已新增测试覆盖 `verify` 成功路径和篡改 `safety.connectsSsh=true` 后失败。
- 已提交并推送 `f1b4960 ops: verify remote collector onboarding bundles`。
- 已部署到 Tom，并验证运行提交 `f1b4960`。
- 已在 Tom 用样板配置执行 onboarding `write`，只写入 `runtime/remote-onboarding/remote-oracle/`，未 SSH、未写 active registry、未修改任何 OpenClaw 实例。
- 已在 Tom 对样板接入包执行 `verify`，返回 `status=verified`、`bundlesBuildContext=true`、`buildContextFiles=88`、`bootstrapStartsContainers=false`、`writesActiveRegistry=false`、`connectsSsh=false`、`mutatesOpenClawInstance=false`、`callsLiveApi=false`。
- 已验证 Tom `healthcheck.sh` 通过，现有 5 个实例仍只读；live window status 仍为 `needs_manual_approval`、`READONLY_MODE=true`、`readiness.status=blocked`，未调用 live API。
- 已新增 `ops/tom-readonly/remote-collector-preflight.sh`，用于在真实复制到远端前做 SSH 只读预检。
- `remote-collector-preflight.sh plan` 只读取 onboarding bundle，不联网、不写文件。
- `remote-collector-preflight.sh check` 必须设置 `CONFIRM_REMOTE_COLLECTOR_PREFLIGHT=I_UNDERSTAND_THIS_ONLY_READS_REMOTE_PREREQUISITES`，只通过 SSH 检查远端 docker、docker compose、crontab、deploy 目录或父目录权限、实例目录可读性和 gateway 端口。
- preflight 不写远端文件、不启动容器、不修改任何 OpenClaw 实例目录、不调用 managed action live API。
- 已新增 `test/remote-collector-preflight.test.ts`，覆盖 plan 不 SSH、check 必须确认、只读检查成功、必需检查失败时 blocked。
- 已验证 `bash -n ops/tom-readonly/remote-collector-preflight.sh`。
- 已验证 `npm test -- test/remote-collector-preflight.test.ts`，3/3 通过。
- 已验证 `npm test -- test/remote-collector-preflight.test.ts test/remote-collector-onboarding.test.ts test/register-remote-collector.test.ts test/remote-collector-pull.test.ts test/collector-node-bootstrap.test.ts test/oss-readiness.test.ts`，21/21 通过。
- 已验证 `npm test -- test/multi-instance-readonly.test.ts test/readonly-multi-instance-safety.test.ts test/ui-render-smoke.test.ts`，39/39 通过。
- 已验证 `npm run build`。
- 已提交并推送 `2d2dfa5 ops: preflight remote collector prerequisites`。
- 已部署到 Tom，并验证运行提交 `2d2dfa5`。
- 已在 Tom 对样板接入包执行 `remote-collector-preflight.sh plan`，返回 `connectsSsh=false`、`writesRemoteFiles=false`、`startsContainers=false`、`mutatesOpenClawInstance=false`、`callsLiveApi=false`。
- 已在 Tom 再次执行 onboarding `verify`，返回 `status=verified`、`bootstrapStartsContainers=false`、`writesActiveRegistry=false`、`connectsSsh=false`。
- 已验证 Tom `healthcheck.sh` 通过，现有 5 个实例仍只读；live window status 仍为 `needs_manual_approval`、`READONLY_MODE=true`、`readiness.status=blocked`，未调用 live API。
- 已新增 `ops/tom-readonly/register-remote-collector.sh`，用于把已拉取的远端 collector snapshot 注册到 Tom `config/instances.json`。
- 已新增 `ops/tom-readonly/register-remote-collector.example.json` 样板。
- `register-remote-collector.sh plan` 只读取配置、Tom registry 和本机 snapshot，不写文件。
- `register-remote-collector.sh apply` 必须设置 `CONFIRM_REMOTE_COLLECTOR_REGISTER=I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_REGISTRY`，会先备份原 registry，再原子写入新 registry。
- 注册脚本会校验 snapshot `serverId`、`generatedAt`、实例列表、重复 server/instance id，并保证新增实例是 collector-only。
- 已新增 `test/register-remote-collector.test.ts`，覆盖 plan 不写文件、apply 必须确认、自动备份、collector-only server 写入和 serverId 不匹配失败。
- 已验证 `bash -n ops/tom-readonly/register-remote-collector.sh`。
- 已验证 `npm test -- test/register-remote-collector.test.ts test/remote-collector-pull.test.ts test/instance-config.test.ts test/oss-readiness.test.ts`，23/23 通过。
- 已验证 `npm test -- test/register-remote-collector.test.ts test/remote-collector-pull.test.ts test/collector-node-bootstrap.test.ts test/collector-exporter.test.ts test/multi-instance-readonly.test.ts test/readonly-multi-instance-safety.test.ts`，16/16 通过。
- 已验证 `npm run build`。
- 已提交并推送 `d6a332b ops: register remote collector snapshots`。
- 已部署到 Tom，并验证运行提交 `d6a332b`。
- 已在 Tom 临时目录验证 `register-remote-collector.sh plan` 返回 `status=planned`、`mutatesOpenClawInstance=false`、`callsLiveApi=false`，未对真实 registry 执行 apply。
- 已验证 Tom `healthcheck.sh` 通过，现有 5 个实例仍只读；live window status 仍为 `needs_manual_approval`、`READONLY_MODE=true`、`readiness.status=blocked`，未调用 live API。
- 已新增 `ops/collector-node/bootstrap-collector-node.sh`，用于远端 Oracle collector-only 节点引导。
- 已新增 `ops/collector-node/collector-node.example.json` 样板。
- `bootstrap-collector-node.sh plan` 只校验配置并输出将生成的文件，不写入、不启动容器。
- `bootstrap-collector-node.sh write` 必须设置 `CONFIRM_COLLECTOR_NODE_WRITE=I_UNDERSTAND_THIS_ONLY_WRITES_COLLECTOR_NODE_FILES`，只写 `docker-compose.collector.yml`、`config/instances.json`、`collector-snapshot.sh` 和 `install-collector-cron.sh`。
- 生成的 collector-only compose 不暴露端口、不挂载 `/var/run/docker.sock`、不启用 privileged，实例目录全部 `:ro`。
- 已新增 `test/collector-node-bootstrap.test.ts`，覆盖 plan 不写文件、write 必须确认、生成文件只读安全边界。
- 已验证 `bash -n ops/collector-node/bootstrap-collector-node.sh`。
- 已验证 `ops/collector-node/bootstrap-collector-node.sh plan ops/collector-node/collector-node.example.json`。
- 已验证 `npm test -- test/collector-node-bootstrap.test.ts test/remote-collector-pull.test.ts test/oss-readiness.test.ts`，11/11 通过。
- 已验证 `npm test -- test/collector-node-bootstrap.test.ts test/remote-collector-pull.test.ts test/collector-exporter.test.ts test/instance-config.test.ts test/multi-instance-readonly.test.ts test/readonly-multi-instance-safety.test.ts`，26/26 通过。
- 已验证 `npm run build`。
- 已提交并推送 `53c9bef ops: scaffold collector-only remote nodes`。
- 已部署到 Tom，并验证运行提交 `53c9bef`。
- 已验证 Tom 上 bootstrap `plan` 返回 `startsContainers=false`、`mutatesOpenClawInstance=false`，没有执行 write、没有启动 collector-only 容器。
- 已验证 Tom `healthcheck.sh` 通过，现有 5 个实例仍只读；live window status 仍为 `needs_manual_approval`、`READONLY_MODE=true`、`readiness.status=blocked`，未调用 live API。
- 已让 `parseOpenClawInstanceConfigText` 支持 collector-only 远端实例：server 配置 `collectorSnapshotPath` 后，实例可以省略 `openclawHome/workspaceRoot`。
- 已为 collector-only 实例生成内部占位路径 `/collector/<serverId>/<instanceId>/config`，中央仍只从 collector snapshot 读取数据。
- 已更新 `docs/MULTI_INSTANCE_READONLY.md`，远端 collector 示例不再要求填写远端目录路径。
- 已验证 `npm test -- test/instance-config.test.ts test/multi-instance-readonly.test.ts test/remote-collector-pull.test.ts test/oss-readiness.test.ts`，25/25 通过。
- 已验证 `npm run build`。
- 已提交并推送 `fcc996f feat: allow collector-only remote instances`。
- 已部署到 Tom，并验证运行提交 `fcc996f`。
- 已在 Tom 容器内验证 collector-only registry 解析结果为 `status=ok`，内部路径为 `/collector/remote-oracle/remote-main/config`。
- 已验证 Tom `healthcheck.sh` 通过，现有 5 个实例仍只读；live window status 仍为 `needs_manual_approval`、`READONLY_MODE=true`、`readiness.status=blocked`，未调用 live API。
- 已新增跨服务器只读拉取脚本 `ops/tom-readonly/remote-collector-pull.sh`。
- 已新增拉取配置样板 `ops/tom-readonly/remote-collector-pull.sources.example.json`，默认 `enabled=false`。
- `remote-collector-pull.sh plan` 只校验配置和输出计划，不联网。
- `remote-collector-pull.sh pull` 必须设置 `CONFIRM_REMOTE_COLLECTOR_PULL=I_UNDERSTAND_THIS_ONLY_READS_REMOTE_COLLECTOR_SNAPSHOTS`，只通过 SSH `cat` 读取远端 collector JSON。
- 已让拉取脚本校验 `schemaVersion=1`、`serverId` 匹配、`generatedAt` 可解析、`instances` 非空，并限制本地写入路径必须位于 `runtime/collectors/`。
- 已让拉取脚本写入 `runtime/collector-pull-state/<serverId>.json`，方便审计最近一次拉取状态。
- 已新增 `test/remote-collector-pull.test.ts`，覆盖计划、确认短语、假 SSH 拉取、原子写入、状态记录和 serverId 不匹配失败。
- 已验证 `bash -n ops/tom-readonly/remote-collector-pull.sh`。
- 已验证 `ops/tom-readonly/remote-collector-pull.sh plan ops/tom-readonly/remote-collector-pull.sources.example.json`。
- 已验证 `npm test -- test/remote-collector-pull.test.ts test/collector-exporter.test.ts test/oss-readiness.test.ts`。
- 已验证 `npm test -- test/multi-instance-readonly.test.ts test/instance-config.test.ts test/ui-render-smoke.test.ts test/readonly-multi-instance-safety.test.ts test/remote-collector-pull.test.ts`，共 52/52 通过。
- 已验证 `npm run build`。
- 已提交并推送 `fcdd104 ops: add readonly remote collector pull`。
- 已部署到 Tom，并验证运行提交 `fcdd104`。
- 已验证 Tom `remote-collector-pull.sh plan` 对样板配置返回 `status=planned`，样板源 `enabled=false`，没有执行远端拉取。
- 已验证 Tom `healthcheck.sh` 通过，collector 快照正常，仍只读；Tom live window status 仍为 `needs_manual_approval`、`READONLY_MODE=true`、`readiness.status=blocked`，未调用 live API。
- 已新增 `live-healthcheck-approval.sh consume`，让批准记录在 live healthcheck 调用成功后变为一次性已使用状态，后续 `check` 会要求重新 approve。
- 已让 `live-healthcheck-window.sh run` 在 smoke 成功后自动调用 `consume`，再恢复只读并生成影响快照和报告。
- 已让演练报告要求 `approval.consumed === true`，确保报告证明批准记录不会被复用。
- 已验证 approval 本地临时目录生命周期：未批准时 `check` 失败，approve 后 `check` 通过，consume 后 `status=consumed` 且 `check` 再次失败。
- 已验证 `bash -n ops/tom-readonly/live-healthcheck-approval.sh`、`live-healthcheck-window.sh`、`live-healthcheck-report.sh`。
- 已验证 `npm test -- test/oss-readiness.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-gate.test.ts test/managed-action-live-audit.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `6644cfb ops: consume live healthcheck approvals after use`。
- 已部署到 Tom，并验证运行提交 `6644cfb`。
- 已在 Tom 临时目录验证 approval 生命周期，未改真实 runtime approval。
- 已验证 Tom 真实 approval 仍为 `needs_manual_approval`、`consumed=false`，`READONLY_MODE=true`，live gate/executor 未启用，`readiness.status=blocked`，未调用 live API。
- 已新增 `live-healthcheck-approval.sh approve`，要求 `CONFIRM_APPROVAL_RECORD=I_APPROVE_LIVE_HEALTHCHECK_RECORD` 和 `APPROVED_BY=<批准人>`，只写 approval 文件，不启用 live gate。
- 已验证 approve 辅助命令本地临时目录流程：缺少确认短语会失败，确认短语和批准人齐全后写入 `approved=true` 并通过 `status/check`。
- 已验证 `bash -n ops/tom-readonly/live-healthcheck-approval.sh`。
- 已验证 `npm test -- test/oss-readiness.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-gate.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `4467e9a ops: add explicit approval record command`。
- 已部署到 Tom，并验证运行提交 `4467e9a`。
- 已验证 Tom `healthcheck.sh` 通过，collector 快照正常，5 个实例仍在只读监控范围内。
- 已验证 Tom approval 仍为 `needs_manual_approval`，`READONLY_MODE=true`，`MANAGED_ACTIONS_LIVE_ENABLED` 和 `MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED` 均未启用。
- 已验证 Tom `live-healthcheck-window.sh status` 仍为 `readiness.status=blocked`，未调用 live API。
- 已新增 Superpowers 执行计划：`docs/superpowers/plans/2026-05-17-control-center-data-trust.md`。
- 已为总览页和单实例详情页增加数据来源标注。
- 已验证 `npm test -- test/ui-render-smoke.test.ts`。
- 已验证 `npm test -- test/readonly-multi-instance-safety.test.ts`。
- 已验证 `npm run build`。
- 已新增 Agent 配置名录接入计划：`docs/superpowers/plans/2026-05-17-agent-config-roster.md`。
- 已让只读 snapshot 携带实例级 `agentRoster`。
- 已让 UI Agent 名录优先展示配置 Agent，并把推导来源作为补充。
- 已验证 `npm test -- test/agent-roster.test.ts`。
- 已验证 `npm test -- test/multi-instance-readonly.test.ts`。
- 已新增真实 runtime 日志接入计划：`docs/superpowers/plans/2026-05-17-runtime-log-ingestion.md`。
- 已新增只读 runtime 日志扫描器：`src/runtime/runtime-logs.ts`。
- 已让只读 snapshot 携带实例级 `runtimeLogs`。
- 已让 UI 最近日志真实日志优先，无真实日志时 fallback 到合成事件。
- 已验证 `npm test -- test/runtime-logs.test.ts`。
- 已新增跨服务器 registry 计划：`docs/superpowers/plans/2026-05-17-cross-server-registry.md`。
- 已让 `OPENCLAW_INSTANCES_FILE` 支持旧版 `instances` 与新版 `servers[].instances`。
- 已让 UI 显示服务器健康、服务器筛选和实例详情中的服务器元数据。
- 已新增 collector 快照接入计划：`docs/superpowers/plans/2026-05-17-collector-snapshot-ingestion.md`。
- 已让 server registry 支持 `collectorSnapshotPath`。
- 已新增 collector 快照文件解析器：`src/runtime/collector-snapshot.ts`。
- 已让多实例只读 adapter 对配置了 `collectorSnapshotPath` 的实例优先使用 collector 快照。
- 已新增 collector exporter：`src/runtime/collector-exporter.ts`。
- 已新增命令：`npm run collector:snapshot -- <output-path>` 与 `node dist/index.js collector-snapshot <output-path>`。
- 已新增 Tom 快照脚本：`ops/tom-readonly/collector-snapshot.sh`。
- 已在 Tom 备份切流前 registry：`runtime/deploy-state/instances.before-collector-cutover.20260517044631.json.bak`。
- 已在 Tom 生成最新 collector 快照：`/app/runtime/collectors/tom-oracle/snapshot.json`。
- 已把 Tom `config/instances.json` 的 `tom-oracle` 指向 `collectorSnapshotPath`。
- 已验证总览页和实例详情页出现 `collector ok`，Tom `healthcheck.sh` 通过。
- 已新增 Tom collector 定时化计划：`docs/superpowers/plans/2026-05-17-collector-snapshot-scheduling.md`。
- 已新增 `ops/tom-readonly/install-collector-cron.sh`，通过 `OPENCLAW_COLLECTOR_CRON_BEGIN` 标记块幂等安装快照 cron。
- 已让 `ops/tom-readonly/healthcheck.sh` 检查 `collectorSnapshotPath` 快照新鲜度，默认 `COLLECTOR_SNAPSHOT_MAX_AGE_SECONDS=300`。
- 已提交并推送 `200660d feat: schedule tom collector snapshots`。
- 已部署到 Tom，并验证运行代码提交 `200660d`。
- 已在 Tom 安装 cron：`*/2 * * * *`。
- 已确认 cron 自动刷新快照：`generatedAt` 从 `2026-05-17T04:58:07.916Z` 更新到 `2026-05-17T05:00:01.779Z`。
- 已验证 Tom 新版 `healthcheck.sh` 通过，collector 快照检查为 `server=tom-oracle`、`instances=5`。
- 已让 `InstanceSnapshot` 携带 collector 元数据：`sourcePath`、`serverId`、`generatedAt`、`status`、`detail`。
- 已在多实例总览和实例详情页新增 `Collector 快照` 面板，展示来源路径、生成时间、年龄/上限和新鲜度。
- 已验证 `npm test -- test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts`。
- 已验证 `npm run build`。
- 已发现 Tom 之外的候选 Oracle 主机暂不能安全接入：22 端口可达，但 SSH banner 阶段超时；本轮不强行修改该主机。
- 已新增只读多实例模式下的管理动作 dry-run API：`GET /api/managed-actions` 与 `POST /api/managed-actions/dry-run`。
- 已新增白名单动作预览：`healthcheck`、`collector_refresh`、`skill_run`。
- 已确保 dry-run 返回 `liveExecution:false`、`dryRun:true`，并声明 `mutatesOpenClawInstance:false`。
- 已让 dry-run API 写入控制中心审计日志 `managed_action_dry_run`，不调用 OpenClaw 实例命令。
- 已把 `notification-center` 与导出包目录统一到 `OPENCLAW_RUNTIME_DIR` 兼容路径，修复测试隔离下的命令回归。
- 已验证 `npm test -- test/managed-actions-dry-run.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts`。
- 已验证 `npm test -- test/phase9-routes-commands.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `fc044df feat: add readonly managed action dry-run previews`。
- 已部署到 Tom，并验证运行提交 `fc044df`。
- 已验证 Tom `GET /api/managed-actions` 返回 3 个白名单动作：`healthcheck`、`collector_refresh`、`skill_run`。
- 已验证 Tom 未带本地令牌的 `POST /api/managed-actions/dry-run` 返回 401。
- 已验证 Tom 授权 dry-run 返回 `status=dry_run_ready`、`dryRun=true`、`liveExecution=false`、`mutatesOpenClawInstance=false`。
- 已验证 Tom 审计日志出现 `managed_action_dry_run`，目标实例为 `tom`。
- 已新增多实例总览页 `管理动作预览` UI，支持选择实例、动作、skill、原因和本地令牌。
- 已确保实例详情页仍不挂载管理动作 UI。
- 已提交并推送 `f09f899 feat: add managed action dry-run UI`。
- 已部署到 Tom，并验证运行提交 `f09f899`。
- 已验证页面包含 `管理动作预览`，浏览器页面树可见该入口。
- 已验证 `npm test -- test/ui-render-smoke.test.ts test/managed-actions-dry-run.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts`。
- 已验证 `npm run build`。
- 已让 dry-run API 要求 `operator`、`reason`、`confirmedText=DRY-RUN-ONLY`。
- 已让 dry-run 结果返回 `review.operationRequestId`、`review.operator`、`review.reason`、`review.confirmationTextMatched` 和 `review.targetConfigSnapshot`。
- 已让 dry-run 审计日志记录操作申请 ID、操作者、原因、确认结果和目标配置快照。
- 已让总览页 `管理动作预览` UI 增加操作者与确认短语输入。
- 已验证错误确认短语在带本地令牌时返回 400。
- 已验证 Tom 授权 dry-run 返回 `confirmationTextMatched=true`、`targetConfigSnapshot=tom`、`mutatesOpenClawInstance=false`。
- 已验证 Tom 审计日志包含 `operationRequestId`、`operator`、`confirmationTextMatched` 和 `targetConfigSnapshot`。
- 已提交并推送 `d86bfdd feat: require review metadata for managed action previews`。
- 已部署到 Tom，并验证运行提交 `d86bfdd`。
- 已验证 `npm test -- test/managed-actions-dry-run.test.ts test/ui-render-smoke.test.ts test/phase9-routes-commands.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts`。
- 已验证 `npm run build`。
- 已新增只读审计读取层：`src/runtime/managed-action-audit.ts`。
- 已新增 `GET /api/managed-actions/audit`，支持 `limit`、`instanceId`、`operator`、`action` 过滤。
- 已在多实例总览页新增 `管理动作审计` 面板，展示最近 dry-run 申请。
- 已让审计记录包含动作名、目标实例、操作者、原因、确认结果、命令预览和申请 ID。
- 已验证 `npm test -- test/managed-actions-dry-run.test.ts test/ui-render-smoke.test.ts test/phase9-routes-commands.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts`。
- 已验证 `npm run build`。
- 已新增配置项：`MANAGED_ACTIONS_LIVE_ENABLED=false` 默认关闭，`MANAGED_ACTIONS_LIVE_ALLOWED_ACTIONS` 默认为空。
- 已新增真实执行确认短语：`LIVE-ACTION-APPROVED`。
- 已新增 `/api/managed-actions/live`，当前只做闸门判断，不实现执行器。
- 已确保 live gate 默认返回 `blocked_disabled`、`liveExecution=false`。
- 已让 live gate 阻断记录写入 `managed_action_live_blocked` 审计。
- 已验证 `npm test -- test/managed-actions-dry-run.test.ts test/phase9-routes-commands.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `0f26baa feat: add disabled managed action live gate`。
- 已部署到 Tom，并验证运行提交 `0f26baa`。
- 已验证 Tom `/api/managed-actions/live` 在带本地令牌和 `LIVE-ACTION-APPROVED` 时仍返回 `blocked_disabled`。
- 已验证 Tom live gate 返回 `liveExecution=false`、`enabled=false`、`readonlyMode=true`、`allowedActions=[]`。
- 已验证 Tom 页面仍只有 `管理动作预览` 与 `管理动作审计`，没有真实执行入口。
- 已验证 Tom 审计日志写入 `managed_action_live_blocked`，且 `liveExecution=false`。
- 已新增执行器接口：`src/runtime/managed-action-executor.ts`。
- 已新增测试用 mock healthcheck executor。
- 已验证 gate 未 ready 时不会调用执行器。
- 已验证只有测试环境传入 mock executor 且 `gateReady=true` 时才会得到 `executed_mock`。
- 已验证未注册动作返回 `executor_missing` 且 `liveExecution=false`。
- 已验证 `npm test -- test/managed-action-executor.test.ts test/managed-actions-dry-run.test.ts test/phase9-routes-commands.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `9b2e52e feat: add managed action executor test seam`。
- 已部署到 Tom，并验证运行提交 `9b2e52e`。
- 已验证 Tom `/api/managed-actions/live` 仍返回 `blocked_disabled`、`liveExecution=false`、`enabled=false`、`readonlyMode=true`。
- 已验证 Tom 页面仍无真实执行入口。
- 已新增真实执行审计结果类型模块：`src/runtime/managed-action-live-audit.ts`。
- 已新增 `managed_action_live_result` 审计 action 类型。
- 已定义真实执行审计 metadata：`operationRequestId`、`operator`、`reason`、`executor`、`target`、`gate`、`commandPreview`、`durationMs`、`rollback`、`result`、`error`、`skip`。
- 已覆盖四类审计结果：`executed`、`failed`、`rolled_back`、`skipped`。
- 已验证 `executed` 与 `skipped` 为 `ok=true`，`failed` 与 `rolled_back` 为 `ok=false`。
- 已验证 `skipped` 不标记真实执行，`executed/failed/rolled_back` 标记 `liveExecution=true`。
- 已验证 `npm test -- test/managed-action-live-audit.test.ts test/managed-action-executor.test.ts test/managed-actions-dry-run.test.ts test/phase9-routes-commands.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts`。
- 已验证 `npm run build`。
- 已新增 dry-run 引用校验：按 `operationRequestId` 查找 `managed_action_dry_run` 审计记录。
- 已校验 live 请求引用的 dry-run 动作一致、目标实例一致、确认短语已通过、未超过默认 24 小时有效期。
- 已让 `/api/managed-actions/live` 返回 `dryRunReference` 摘要，包含 `valid`、`status`、`operationRequestId`、`ageMs`、`maxAgeMs` 和匹配记录摘要。
- 已让 live 阻断审计记录包含 `dryRunReference` 摘要。
- 已验证有效引用时 `dryRunReference.status=valid`。
- 已验证缺失引用时 `dryRunReference.status=missing`。
- 已验证动作不一致时 `dryRunReference.status=action_mismatch`。
- 已验证目标实例不一致时 `dryRunReference.status=target_mismatch`。
- 已验证 `npm test -- test/managed-actions-dry-run.test.ts test/managed-action-live-audit.test.ts test/managed-action-executor.test.ts test/phase9-routes-commands.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `0ec55da feat: validate live requests against dry-run audits`。
- 已部署到 Tom，并验证运行提交 `0ec55da`。
- 已验证 Tom 有效 dry-run 引用返回 `dryRunReference.status=valid`。
- 已验证 Tom 缺失引用返回 `dryRunReference.status=missing`。
- 已验证 Tom 动作不一致返回 `dryRunReference.status=action_mismatch`。
- 已验证 Tom `/api/managed-actions/live` 仍返回 `blocked_disabled`、`liveExecution=false`、`enabled=false`。
- 已验证 Tom 页面仍无真实执行入口。
- 已新增配置项：`MANAGED_ACTIONS_LIVE_ROLLOUT_FILE`。
- 已新增灰度配置解析模块：`src/runtime/managed-action-live-rollout.ts`。
- 已定义灰度规则字段：`action`、`instanceId`、`operators`、`risk`、`enabled`、`maxDryRunAgeMinutes`。
- 已验证默认配置为禁用且无规则。
- 已验证窄匹配规则只允许指定动作、实例和操作者。
- 已验证 `operators:["*"]` 支持通配操作者，但禁用规则不会放行。
- 已验证非法规则进入 `issues`，且不会被允许。
- 已验证可以从 JSON 文件加载灰度配置。
- 已验证 `npm test -- test/managed-action-live-rollout.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-audit.test.ts test/managed-action-executor.test.ts test/phase9-routes-commands.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `5a95f91 feat: add managed action live rollout config`。
- 已部署到 Tom，并验证运行提交 `5a95f91`。
- 已验证 Tom 没有配置 `MANAGED_ACTIONS_LIVE_ROLLOUT_FILE`。
- 已验证 Tom `/api/managed-actions/live` 仍返回 `blocked_disabled`、`liveExecution=false`、`enabled=false`。
- 已验证 Tom 页面仍无真实执行入口。
- 已将 rollout 决策接入 `/api/managed-actions/live` 响应和 `managed_action_live_blocked` 审计。
- 已新增 `blocked_rollout_not_allowed` gate 状态。
- 已验证全部安全检查通过但 rollout 不匹配时会被 `blocked_rollout_not_allowed` 拦截。
- 已验证全部安全检查和 rollout 都通过时仍返回 `ready_not_implemented`，因为当前没有生产执行器。
- 已验证 live 响应包含 `rollout.allowed`、`rollout.status`、`rollout.message` 和可选规则摘要。
- 已验证 `npm test -- test/managed-action-live-gate.test.ts test/managed-action-live-rollout.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-audit.test.ts test/managed-action-executor.test.ts test/phase9-routes-commands.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `342105c feat: surface rollout decisions in live gate`。
- 已部署到 Tom，并验证运行提交 `342105c`。
- 已验证 Tom live 响应返回 `dryRunReference=valid`、`rollout.status=disabled`。
- 已验证 Tom live 仍返回 `blocked_disabled`、`liveExecution=false`、`enabled=false`。
- 已验证 Tom 页面仍无真实执行入口。
- 已新增只读 readiness 建模：`src/runtime/managed-action-live-readiness.ts`。
- 已新增 `GET /api/managed-actions/readiness`。
- 已在多实例总览页和单实例详情页新增 `真实执行上线条件` 卡片。
- 已验证 readiness 卡片只读展示 live gate、rollout、dry-run 审计和执行器接入状态。
- 已验证 readiness API 返回 `liveExecutionAttempted=false`、`mutatesOpenClawInstance=false`。
- 已验证页面卡片不调用 `/api/managed-actions/live`，不提供真实执行按钮。
- 已验证 `npm test -- test/managed-action-live-readiness.test.ts test/managed-action-live-gate.test.ts test/managed-action-live-rollout.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-audit.test.ts test/managed-action-executor.test.ts test/phase9-routes-commands.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `0fc5fbe feat: add managed action live readiness diagnostics`。
- 已部署到 Tom，并验证运行提交 `0fc5fbe`。
- 已验证 Tom `healthcheck.sh` 通过，5 个 gateway 健康端口通过。
- 已验证 Tom readiness 返回 `status=blocked`、`liveExecutionAvailable=false`、`liveExecutionAttempted=false`、`mutatesOpenClawInstance=false`。
- 已验证 Tom readiness 返回 `gate.enabled=false`、`gate.readonlyMode=true`、`rollout.enabled=false`、`executor.productionWired=false`。
- 已验证 Tom 总览页和实例详情页都出现 `真实执行上线条件`。
- 已验证 Tom 总览页不包含 `/api/managed-actions/live` 前端调用，也不包含真实执行确认短语。
- 已新增生产执行器骨架：`src/runtime/managed-action-production-executor.ts`。
- 已验证生产执行器骨架只注册只读 `healthcheck`，不注册 `collector_refresh` 和 `skill_run`。
- 已验证该骨架当前仅被测试引用，未接入 live 路由。
- 已验证 `npm test -- test/managed-action-executor.test.ts test/managed-action-live-readiness.test.ts test/managed-actions-dry-run.test.ts test/phase9-routes-commands.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `ce71ff0 feat: add production managed action executor skeleton`。
- 已部署到 Tom，并验证运行提交 `ce71ff0`。
- 已验证 Tom `healthcheck.sh` 通过，5 个 gateway 健康端口通过，容器只读边界通过。
- 已验证 Tom readiness 仍返回 `status=blocked`、`liveExecutionAvailable=false`、`liveExecutionAttempted=false`、`mutatesOpenClawInstance=false`。
- 已验证 Tom readiness 仍返回 `executor.productionWired=false`、`executor.status=missing`。
- 已验证 Tom 总览页仍无 `/api/managed-actions/live` 前端调用，也无真实执行确认短语。
- 已新增 `MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED=false` 默认配置。
- 已让 live gate 在 `executorWired=true` 且所有安全条件通过时返回 `ready`；默认仍返回 `ready_not_implemented`。
- 已将生产执行器挂载开关接入 `/api/managed-actions/live`。
- 已验证显式打开开关、live gate、dry-run 引用、rollout 和确认短语全部通过时，只读 `healthcheck` 返回 `executed_readonly_healthcheck`。
- 已验证只读 `healthcheck` 响应声明 `safety.mutatesOpenClawInstance=false`。
- 已让 readiness 根据挂载开关显示 `executor.productionWired`。
- 已更新 Tom `healthcheck.sh`，如果 `MANAGED_ACTIONS_LIVE_ENABLED=true` 或 `MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED=true` 会直接失败。
- 已验证 `npm test -- test/managed-action-live-gate.test.ts test/managed-actions-dry-run.test.ts test/managed-action-executor.test.ts test/managed-action-live-audit.test.ts test/managed-action-live-readiness.test.ts test/phase9-routes-commands.test.ts test/readonly-multi-instance-safety.test.ts test/multi-instance-readonly.test.ts test/ui-render-smoke.test.ts test/oss-readiness.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `5ee4b43 feat: gate live managed action executor wiring`。
- 已部署到 Tom，并验证运行提交 `5ee4b43`。
- 已验证 Tom `healthcheck.sh` 通过，新增 live 开关安全检查通过。
- 已验证 Tom 容器没有启用 `MANAGED_ACTIONS_LIVE_ENABLED=true` 或 `MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED=true`。
- 已验证 Tom readiness 返回 `status=blocked`、`liveExecutionAvailable=false`、`liveExecutionAttempted=false`、`executor.productionWired=false`。
- 已验证 Tom 总览页仍包含 `真实执行上线条件`，但不包含 `/api/managed-actions/live` 前端调用，也不包含真实执行确认短语。
- 已新增只读 healthcheck live rollout 样板：`ops/tom-readonly/managed-action-healthcheck-rollout.example.json`。
- 已新增人工 smoke 脚本：`ops/tom-readonly/live-healthcheck-smoke.sh`。
- 已让 smoke 脚本必须设置 `CONFIRM_LIVE_HEALTHCHECK=I_UNDERSTAND_THIS_CALLS_LIVE_API` 和 `LOCAL_API_TOKEN` 后才会继续。
- 已让 smoke 脚本先检查 readiness，未允许 live execution 时不会调用 `/api/managed-actions/live`。
- 已验证 `npm test -- test/oss-readiness.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-gate.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `cbc04f9 ops: add live healthcheck smoke plan`。
- 已部署到 Tom，并验证运行提交 `cbc04f9`。
- 已验证 Tom `healthcheck.sh` 通过。
- 已验证 Tom 存在可执行 `live-healthcheck-smoke.sh` 和 rollout 样板。
- 已验证 Tom `bash -n repo/ops/tom-readonly/live-healthcheck-smoke.sh` 通过。
- 已验证 Tom readiness 仍返回 `liveExecutionAvailable=false`、`executor.productionWired=false`。
- 已新增只读 preflight 脚本：`ops/tom-readonly/live-healthcheck-preflight.sh`，用于检查 rollout 样板、容器 live 开关和 readiness。
- 已发现 Tom preflight 首次失败原因：rollout 校验运行在容器内，未接收到 `INSTANCE_ID` 和 `OPERATOR`。
- 已修复 preflight 环境变量传递位置，只在 `check_rollout_file()` 的容器校验中传入 `INSTANCE_ID` 与 `OPERATOR`。
- 已增强 `test/oss-readiness.test.ts`，精确断言 `check_rollout_file()` 段包含 `-e INSTANCE_ID` 与 `-e OPERATOR`。
- 已验证 `bash -n ops/tom-readonly/live-healthcheck-preflight.sh`。
- 已验证 `npm test -- test/oss-readiness.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-gate.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `28ee982 fix: pass rollout inputs to live preflight`。
- 已部署到 Tom，并验证运行提交 `28ee982`。
- 已验证 Tom `healthcheck.sh` 通过，5 个 OpenClaw gateway 健康端口、容器只读边界和 collector 快照检查通过。
- 已验证 Tom preflight 通过，rollout 样板匹配 `action=healthcheck`、`instanceId=tom`、`operator=Anan`。
- 已验证 Tom 容器仍为 `READONLY_MODE=true`，`MANAGED_ACTIONS_LIVE_ENABLED` 与 `MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED` 均未启用。
- 已验证 Tom readiness 仍为 `status=blocked`、`liveExecutionAvailable=false`、`executor.productionWired=false`。
- 已验证 preflight 完成且未调用 live API。
- 已新增一次性演练窗口脚本：`ops/tom-readonly/live-healthcheck-window.sh`。
- 已让窗口脚本支持 `status`、`enable`、`disable`、`run` 四种模式。
- 已让 `run` 模式设置退出 trap，失败或结束后自动执行 `disable` 恢复只读状态。
- 已让窗口脚本生成临时 compose override，仅启用 `READONLY_MODE=false`、`MANAGED_ACTIONS_LIVE_ENABLED=true`、`MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED=true`、`MANAGED_ACTIONS_LIVE_ALLOWED_ACTIONS=healthcheck` 和 rollout 文件路径。
- 已让窗口脚本的 `enable/run` 必须确认 `CONFIRM_LIVE_HEALTHCHECK_WINDOW=I_UNDERSTAND_THIS_TEMPORARILY_ENABLES_LIVE_GATE`。
- 已让 `run` 模式继续要求 `CONFIRM_LIVE_HEALTHCHECK=I_UNDERSTAND_THIS_CALLS_LIVE_API` 和 `LOCAL_API_TOKEN`。
- 已更新 `ops/tom-readonly/README.md`，记录一次性演练窗口命令。
- 已增强 `test/oss-readiness.test.ts`，覆盖窗口脚本存在、确认短语、只允许 healthcheck 和退出恢复逻辑。
- 已验证 `bash -n ops/tom-readonly/live-healthcheck-window.sh`。
- 已验证 `npm test -- test/oss-readiness.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-gate.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `98965fb ops: add live healthcheck window script`。
- 已部署到 Tom，并验证运行提交 `98965fb`。
- 已验证 Tom `healthcheck.sh` 通过，5 个 OpenClaw gateway 健康端口、容器只读边界和 collector 快照检查通过。
- 已验证 Tom `repo/ops/tom-readonly/live-healthcheck-window.sh status` 通过，未检测到临时 override。
- 已验证 Tom 当前仍为 `READONLY_MODE=true`，live gate 与 executor 均未启用，readiness 仍为 `blocked`。
- 本轮未执行 `enable` 或 `run`，未调用 live API。
- 已新增实例影响快照脚本：`ops/tom-readonly/instance-impact-snapshot.sh`。
- 快照内容包括 gateway health、监听端口、control-center 容器特权状态、实例挂载只读状态、docker.sock 挂载状态、live 相关环境变量和 readiness。
- 已让 `live-healthcheck-window.sh run` 在演练前自动生成 before 快照，在成功或失败恢复只读后生成 after 快照，并调用 `instance-impact-snapshot.sh compare`。
- 已让 compare 要求 after 状态满足：gateway 健康、监听行稳定、实例挂载仍只读、无 docker.sock、`READONLY_MODE=true`、live gate 与 executor 关闭、readiness 不允许 live execution。
- 已更新 `ops/tom-readonly/README.md`，记录快照目录和比较标准。
- 已增强 `test/oss-readiness.test.ts`，覆盖实例影响快照脚本和窗口脚本接入。
- 已验证 `bash -n ops/tom-readonly/instance-impact-snapshot.sh && bash -n ops/tom-readonly/live-healthcheck-window.sh`。
- 已验证 `npm test -- test/oss-readiness.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-gate.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `12f6c8a ops: capture live healthcheck impact evidence`。
- 已部署到 Tom，并验证运行提交 `12f6c8a`。
- 已在 Tom 只读状态下生成 before/after 快照，并验证 `instance-impact-snapshot.sh compare` 通过。
- 已验证 Tom `live-healthcheck-window.sh status` 仍显示未检测到临时 override，`READONLY_MODE=true`，live gate 与 executor 未启用，readiness 仍为 `blocked`。
- 本轮仍未执行 `/api/managed-actions/live`。
- 已新增人工批准记录脚本：`ops/tom-readonly/live-healthcheck-approval.sh`。
- 已新增批准记录样板：`ops/tom-readonly/live-healthcheck-approval.example.json`，默认 `approved=false`。
- 批准记录校验要求：`approved=true`、`approvedAt` 可解析且未过期、`approvedBy` 已填写、实例为 `tom`、动作为 `healthcheck`、操作者为 `Anan`、风险为 `low`、确认短语匹配、`mutatesOpenClawInstance=false`，并且 checklist 全部为 true。
- 已让 `live-healthcheck-window.sh enable/run` 在写入临时 compose override 前调用 `live-healthcheck-approval.sh check`。
- 已让窗口脚本把 `INSTANCE_ID` 与 `OPERATOR` 显式传给 preflight 和 smoke。
- 已更新 `ops/tom-readonly/README.md`，记录 approval 模板生成、人工编辑和校验流程。
- 已增强 `test/oss-readiness.test.ts`，覆盖 approval 脚本、样板和窗口脚本接入。
- 已验证 `bash -n ops/tom-readonly/live-healthcheck-approval.sh && bash -n ops/tom-readonly/live-healthcheck-window.sh`。
- 已验证 approval 模板默认校验失败，人工填入 `approved=true`、`approvedAt`、`approvedBy` 和 checklist 后校验通过。
- 已验证 `npm test -- test/oss-readiness.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-gate.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `e6c629f ops: require approval record for live healthcheck`。
- 已部署到 Tom，并验证运行提交 `e6c629f`。
- 已在 Tom 生成候选 approval 模板，并验证未批准模板不会通过校验。
- 已验证 Tom `live-healthcheck-window.sh status` 仍显示未检测到临时 override，`READONLY_MODE=true`，live gate 与 executor 未启用，readiness 仍为 `blocked`。
- 本轮未执行 `enable` 或 `run`，未调用 `/api/managed-actions/live`。
- 已为 `ops/tom-readonly/live-healthcheck-approval.sh` 新增 `prepare` 模式：文件不存在时生成模板，已存在时不覆盖，并输出 JSON 状态。
- 已为 `ops/tom-readonly/live-healthcheck-approval.sh` 新增 `status` 模式：只读取批准文件状态，不会失败，不调用 live API。
- 已让 `live-healthcheck-window.sh status` 显示 approval 状态。
- 已更新 `ops/tom-readonly/README.md`，将常用流程改为 `prepare -> status -> check -> run`。
- 已增强 `test/oss-readiness.test.ts` 覆盖 `prepare/status` 与窗口状态接入。
- 已验证 `bash -n ops/tom-readonly/live-healthcheck-approval.sh && bash -n ops/tom-readonly/live-healthcheck-window.sh`。
- 已验证 approval `status` 在文件缺失时返回 `missing`。
- 已验证 approval `prepare` 会生成模板并返回 `needs_manual_approval`，再次执行不会覆盖已有文件。
- 已验证 `npm test -- test/oss-readiness.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-gate.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `3d23811 ops: prepare live healthcheck approval safely`。
- 已部署到 Tom，并验证运行提交 `3d23811`。
- 已在 Tom 生成 `/srv/openclaw-control-center-readonly/runtime/live-healthcheck-approval.json` 草稿。
- 已验证 Tom approval 状态为 `needs_manual_approval`，缺口包括 `approved=false`、`approvedBy` 为空、`approvedAt` 未填写、checklist 未确认。
- 已验证 Tom `live-healthcheck-window.sh status` 会显示 approval 状态，并继续显示未检测到临时 override、`READONLY_MODE=true`、live gate 与 executor 未启用、readiness 仍为 `blocked`。
- 本轮未执行 `enable` 或 `run`，未调用 `/api/managed-actions/live`。
- 已新增演练报告脚本：`ops/tom-readonly/live-healthcheck-report.sh`。
- 报告脚本只读取 approval、before/after impact snapshots 和 `runtime/operation-audit.log`，不调用 live API。
- 报告通过条件包括：approval 已批准、dry-run 审计存在、live result 审计为 `executed`、`liveExecution=true`、`mutatesOpenClawInstance=false`，以及 after 快照恢复只读。
- 已让 `live-healthcheck-window.sh run` 在成功比较 before/after 快照后自动调用报告脚本。
- 报告会写入 `runtime/live-healthcheck-reports/`，同时生成 JSON 与 Markdown。
- 已更新 `ops/tom-readonly/README.md`，记录报告目录和通过条件。
- 已增强 `test/oss-readiness.test.ts`，覆盖报告脚本和窗口脚本接入。
- 已验证 `bash -n ops/tom-readonly/live-healthcheck-report.sh && bash -n ops/tom-readonly/live-healthcheck-window.sh`。
- 已用临时 approval、impact snapshots 和模拟 `operation-audit.log` 验证报告脚本生成 `status=passed`，且 Markdown 报告存在。
- 已验证 `npm test -- test/oss-readiness.test.ts test/managed-actions-dry-run.test.ts test/managed-action-live-gate.test.ts`。
- 已验证 `npm run build`。
- 已提交并推送 `ff9890e ops: generate live healthcheck evidence report`。
- 已部署到 Tom，并验证运行提交 `ff9890e`。
- 已验证 Tom `bash -n repo/ops/tom-readonly/live-healthcheck-report.sh` 通过。
- 已验证 Tom `live-healthcheck-window.sh status` 仍显示未检测到临时 override，`READONLY_MODE=true`，live gate 与 executor 未启用，readiness 仍为 `blocked`。
- 本轮未执行 `enable` 或 `run`，未调用 `/api/managed-actions/live`。
- 已根据当前只有一台 Oracle 的生产约束，将当前上线口径收束为 `OPENCLAW_TOPOLOGY_MODE=local-only`：先管理 Tom 当前 Oracle 上的多套 OpenClaw 实例，未来扩展第二台 Oracle 时再显式打开 `cross-server` 链路。
- 已让 `ops/local/final-go-live-runner.sh prepare` 在已经处于人工批准边界时幂等返回 `prepared_waiting_human_approval`，并声明 `writesTomRuntime=false`、`opensLiveGate=false`、`callsManagedActionsLiveApi=false`。
- 已让 `ops/local/final-go-live-runner.sh prepare` 在已经处于批准后待执行边界时幂等返回 `prepared_approved_ready_for_live_window`，不再次准备 Tom runtime。
- 已更新 `ops/tom-readonly/README.md`，说明 OpenClaw 可重复调用本机侧 `prepare`，重复执行不会批准 approval、不会打开 live gate、不会调用 live API。
- 已更新 `implementation_plan.md`，把 final runner 重复 `prepare` 幂等语义写入当前阶段。
- 已新增 `test/final-go-live-runner.test.ts` 覆盖重复 `prepare` 场景，验证第二次调用不会再次 SSH 执行 Tom `prepare`。
- 已验证 `bash -n ops/local/final-go-live-runner.sh`。
- 已验证 `npm test -- test/final-go-live-runner.test.ts`。
- 已验证 `npm test -- test/final-go-live-runner.test.ts test/final-go-live-status.test.ts test/live-healthcheck-rollout-runner.test.ts test/go-live-gate.test.ts test/oss-readiness.test.ts`。
- 已验证 `npm run build`。
- 已验证 `git diff --check`。
- 本轮仍未执行 approval `approve`、未打开 live gate、未调用 `/api/managed-actions/live`、未修改或重启任何 OpenClaw 实例。

## 阶段完成后的下一步

先提交并部署这次 final runner 幂等更新到 Tom，然后执行本机侧 `final-go-live-runner.sh prepare` 复核真实 Tom 状态是否仍停在人工批准前。人工填写并校验 `/srv/openclaw-control-center-readonly/runtime/live-healthcheck-approval.json` 后，才能执行一次只读 healthcheck live 演练；演练前后都必须确认现有 OpenClaw 实例未被重启、未被写入、未被触发任务。若演练通过，再进入单动作灰度策略收口；若失败，保持只读并先修复失败点。
