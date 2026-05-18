import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import test from "node:test";

const ROOT = process.cwd();
const RUNNER = join(ROOT, "ops", "tom-readonly", "heartbeat-burn-alert-runner.sh");
const INSTALLER = join(ROOT, "ops", "tom-readonly", "install-heartbeat-burn-alert-cron.sh");
const CONFIRM = "I_UNDERSTAND_THIS_ONLY_INSTALLS_READONLY_HEARTBEAT_BURN_ALERT_CRON";

async function makeFakeInspector(dir: string, status: "suspicious" | "clear" = "suspicious"): Promise<string> {
  const inspector = join(dir, "heartbeat-burn-inspector.sh");
  const report =
    status === "suspicious"
      ? {
          schemaVersion: 1,
          status: "suspicious_usage_detected",
          mode: "status",
          generatedAt: "2026-05-18T08:00:00.000Z",
          summary: { instances: 1, suspiciousRows: 1 },
          rows: [
            {
              instanceId: "deepseek",
              instanceName: "DeepSeek",
              status: "periodic_small_growth",
              suspicious: true,
              totalDelta: 13683,
              recentDelta: 174,
              medianDelta: 281,
              medianIntervalMinutes: 30,
              heartbeat: {
                status: "read",
                path: "/instances/deepseek/workspace/HEARTBEAT.md",
                sizeBytes: 226,
                nonEmpty: true,
                updatedAt: "2026-05-08T16:03:52.414Z",
              },
              nextCommands: ["repo/ops/tom-readonly/heartbeat-burn-inspector.sh status deepseek"],
            },
          ],
          safety: {
            writesOpenClawInstanceDirs: false,
            clearsHeartbeatFiles: false,
            callsModelApis: false,
          },
        }
      : {
          schemaVersion: 1,
          status: "ok",
          mode: "status",
          generatedAt: "2026-05-18T08:00:00.000Z",
          summary: { instances: 1, suspiciousRows: 0 },
          rows: [
            {
              instanceId: "main",
              status: "ok",
              suspicious: false,
              totalDelta: 0,
              heartbeat: { status: "missing", path: "/instances/main/workspace/HEARTBEAT.md" },
            },
          ],
          safety: {
            writesOpenClawInstanceDirs: false,
            clearsHeartbeatFiles: false,
            callsModelApis: false,
          },
        };
  await writeFile(
    inspector,
    `#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
${JSON.stringify(report)}
JSON
`,
    "utf8",
  );
  await chmod(inspector, 0o755);
  return inspector;
}

async function makeDeployDir(dir: string): Promise<string> {
  const deployDir = join(dir, "deploy");
  const runner = join(deployDir, "repo", "ops", "tom-readonly", "heartbeat-burn-alert-runner.sh");
  await mkdir(dirname(runner), { recursive: true });
  await writeFile(runner, "#!/usr/bin/env bash\n", "utf8");
  await chmod(runner, 0o755);
  return deployDir;
}

async function makeFakeCrontab(dir: string, initial = ""): Promise<{ bin: string; tab: string }> {
  const bin = join(dir, "fake-crontab.sh");
  const tab = join(dir, "crontab.txt");
  await writeFile(tab, initial, "utf8");
  await writeFile(
    bin,
    `#!/usr/bin/env bash
set -euo pipefail
tab="${tab}"
case "$1" in
  -l)
    if [ -s "$tab" ]; then cat "$tab"; else exit 1; fi
    ;;
  -)
    cat > "$tab"
    ;;
  *)
    printf 'unsupported fake crontab args: %s\\n' "$*" >&2
    exit 2
    ;;
esac
`,
    "utf8",
  );
  await chmod(bin, 0o755);
  return { bin, tab };
}

function runJson(script: string, args: string[], env: Record<string, string>) {
  const result = spawnSync(script, args, {
    cwd: ROOT,
    env: {
      ...process.env,
      ...env,
    },
    encoding: "utf8",
  });
  return {
    exitCode: typeof result.status === "number" ? result.status : 1,
    stdout: result.stdout,
    stderr: result.stderr,
    report: JSON.parse(result.stdout),
  };
}

test("heartbeat burn alert runner 写 control-center runtime 告警且不修改实例", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-heartbeat-burn-alert-runner-"));
  try {
    const inspector = await makeFakeInspector(dir, "suspicious");
    const alertDir = join(dir, "runtime", "heartbeat-burn-alerts");

    const result = runJson(RUNNER, ["run"], {
      DEPLOY_DIR: dir,
      HEARTBEAT_BURN_INSPECTOR: inspector,
      HEARTBEAT_BURN_ALERT_DIR: alertDir,
      HEARTBEAT_BURN_ALERT_INSTANCE_IDS: "deepseek",
    });

    assert.equal(result.exitCode, 2);
    assert.equal(result.report.status, "heartbeat_burn_alert_triggered");
    assert.equal(result.report.summary.suspiciousRows, 1);
    assert.equal(result.report.suspiciousRows[0].instanceId, "deepseek");
    assert.equal(result.report.suspiciousRows[0].heartbeat.nonEmpty, true);
    assert.equal(result.report.safety.writesControlCenterRuntimeOnly, true);
    assert.equal(result.report.safety.writesOpenClawInstanceDirs, false);
    assert.equal(result.report.safety.clearsHeartbeatFiles, false);
    assert.equal(result.report.safety.callsModelApis, false);

    const latest = JSON.parse(await readFile(join(alertDir, "latest.json"), "utf8"));
    assert.equal(latest.status, "heartbeat_burn_alert_triggered");
    const events = await readFile(join(alertDir, "events.ndjson"), "utf8");
    assert.match(events, /periodic_small_growth/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("heartbeat burn alert runner 无异常时写 clear 状态且不追加事件", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-heartbeat-burn-alert-clear-"));
  try {
    const inspector = await makeFakeInspector(dir, "clear");
    const alertDir = join(dir, "runtime", "heartbeat-burn-alerts");

    const result = runJson(RUNNER, ["run"], {
      DEPLOY_DIR: dir,
      HEARTBEAT_BURN_INSPECTOR: inspector,
      HEARTBEAT_BURN_ALERT_DIR: alertDir,
    });

    assert.equal(result.exitCode, 0);
    assert.equal(result.report.status, "heartbeat_burn_alert_clear");
    assert.equal(result.report.summary.suspiciousRows, 0);
    const latest = JSON.parse(await readFile(join(alertDir, "latest.json"), "utf8"));
    assert.equal(latest.status, "heartbeat_burn_alert_clear");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("heartbeat burn alert cron plan 不写 crontab 且只计划只读 runner", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-heartbeat-burn-alert-cron-plan-"));
  try {
    const { bin, tab } = await makeFakeCrontab(dir, "MAILTO=anan@example.com\n");
    const deployDir = await makeDeployDir(dir);

    const result = runJson(INSTALLER, ["plan"], {
      CRONTAB_BIN: bin,
      DEPLOY_DIR: deployDir,
      HEARTBEAT_BURN_ALERT_CRON_SCHEDULE: "*/10 * * * *",
      HEARTBEAT_BURN_ALERT_INSTANCE_IDS: "deepseek",
    });

    assert.equal(result.exitCode, 0);
    assert.equal(result.report.status, "heartbeat_burn_alert_cron_plan_ready");
    assert.match(result.report.block, /OPENCLAW_HEARTBEAT_BURN_ALERT_CRON_BEGIN/);
    assert.match(result.report.block, /cd '[^']+' && HEARTBEAT_BURN_ALERT_INSTANCE_IDS='deepseek'/);
    assert.match(result.report.block, /heartbeat-burn-alert-runner\.sh run/);
    assert.doesNotMatch(result.stdout, /api\/managed-actions\/live/);
    assert.equal(await readFile(tab, "utf8"), "MAILTO=anan@example.com\n");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("heartbeat burn alert cron apply 需要确认，确认后安装受控块且 remove 可移除", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-heartbeat-burn-alert-cron-apply-"));
  try {
    const { bin, tab } = await makeFakeCrontab(dir, "SHELL=/bin/bash\n");
    const deployDir = await makeDeployDir(dir);

    const blocked = runJson(INSTALLER, ["apply"], {
      CRONTAB_BIN: bin,
      DEPLOY_DIR: deployDir,
    });
    assert.notEqual(blocked.exitCode, 0);
    assert.equal(blocked.report.status, "blocked_confirmation_required");
    assert.equal(blocked.report.safety.blockedBeforeWrite, true);
    assert.equal(await readFile(tab, "utf8"), "SHELL=/bin/bash\n");

    const applied = runJson(INSTALLER, ["apply"], {
      CRONTAB_BIN: bin,
      DEPLOY_DIR: deployDir,
      CONFIRM_HEARTBEAT_BURN_ALERT_CRON: CONFIRM,
      HEARTBEAT_BURN_ALERT_INSTANCE_IDS: "deepseek",
    });
    assert.equal(applied.exitCode, 0);
    assert.equal(applied.report.status, "heartbeat_burn_alert_cron_installed");
    assert.equal(applied.report.safety.writesCrontabOnly, true);
    assert.equal(applied.report.safety.installsReadonlyHeartbeatBurnAlertCron, true);
    assert.equal(applied.report.safety.writesOpenClawInstanceDirs, false);
    const afterApply = await readFile(tab, "utf8");
    assert.match(afterApply, /OPENCLAW_HEARTBEAT_BURN_ALERT_CRON_BEGIN/);
    assert.match(afterApply, /heartbeat-burn-alert-runner\.sh run/);
    assert.doesNotMatch(afterApply, /api\/managed-actions\/live/);

    const status = runJson(INSTALLER, ["status"], {
      CRONTAB_BIN: bin,
      DEPLOY_DIR: deployDir,
      HEARTBEAT_BURN_ALERT_INSTANCE_IDS: "deepseek",
    });
    assert.equal(status.report.status, "heartbeat_burn_alert_cron_installed");
    assert.equal(status.report.needsUpdate, false);

    const removed = runJson(INSTALLER, ["remove"], {
      CRONTAB_BIN: bin,
      DEPLOY_DIR: deployDir,
      CONFIRM_HEARTBEAT_BURN_ALERT_CRON: CONFIRM,
      HEARTBEAT_BURN_ALERT_INSTANCE_IDS: "deepseek",
    });
    assert.equal(removed.exitCode, 0);
    assert.equal(removed.report.status, "heartbeat_burn_alert_cron_removed");
    const afterRemove = await readFile(tab, "utf8");
    assert.match(afterRemove, /SHELL=\/bin\/bash/);
    assert.doesNotMatch(afterRemove, /OPENCLAW_HEARTBEAT_BURN_ALERT_CRON_BEGIN/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
