import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "tom-readonly", "install-managed-action-inbox-cron.sh");
const CONFIRM = "I_UNDERSTAND_THIS_ONLY_INSTALLS_DRY_RUN_INBOX_CRON";

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

function runInstaller(mode: "status" | "plan" | "apply" | "remove", env: Record<string, string>) {
  const result = spawnSync(SCRIPT, [mode], {
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

async function makeDeployDir(dir: string): Promise<string> {
  const deployDir = join(dir, "deploy");
  const runner = join(deployDir, "repo", "ops", "tom-readonly", "managed-action-inbox-runner.sh");
  await mkdir(dirname(runner), { recursive: true });
  await writeFile(runner, "#!/usr/bin/env bash\n", "utf8");
  await chmod(runner, 0o755);
  return deployDir;
}

test("managed action inbox cron plan 不写 crontab 且只计划 dry-run run-pending", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-inbox-cron-plan-"));
  try {
    const { bin, tab } = await makeFakeCrontab(dir, "MAILTO=anan@example.com\n");
    const deployDir = await makeDeployDir(dir);

    const { exitCode, report, stdout } = runInstaller("plan", {
      CRONTAB_BIN: bin,
      DEPLOY_DIR: deployDir,
      MANAGED_ACTION_INBOX_CRON_SCHEDULE: "*/2 * * * *",
    });

    assert.equal(exitCode, 0);
    assert.equal(report.status, "inbox_cron_plan_ready");
    assert.equal(report.installed, false);
    assert.equal(report.needsUpdate, true);
    assert.match(report.block, /OPENCLAW_MANAGED_ACTION_INBOX_CRON_BEGIN/);
    assert.match(report.block, /cd '[^']+' && CONFIRM_MANAGED_ACTION_INBOX_RUNNER=/);
    assert.match(report.block, /managed-action-inbox-runner\.sh run-pending/);
    assert.match(report.block, /CONFIRM_MANAGED_ACTION_INBOX_RUNNER/);
    assert.match(report.block, /MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container/);
    assert.doesNotMatch(stdout, /api\/managed-actions\/live/);
    assert.equal(await readFile(tab, "utf8"), "MAILTO=anan@example.com\n");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("managed action inbox cron apply 缺确认时不写 crontab", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-inbox-cron-confirm-"));
  try {
    const { bin, tab } = await makeFakeCrontab(dir, "SHELL=/bin/bash\n");
    const deployDir = await makeDeployDir(dir);

    const { exitCode, report } = runInstaller("apply", {
      CRONTAB_BIN: bin,
      DEPLOY_DIR: deployDir,
    });

    assert.notEqual(exitCode, 0);
    assert.equal(report.status, "blocked_confirmation_required");
    assert.equal(report.safety.blockedBeforeWrite, true);
    assert.equal(report.safety.writesCrontabOnly, false);
    assert.equal(await readFile(tab, "utf8"), "SHELL=/bin/bash\n");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("managed action inbox cron apply 安装受控块且 remove 可移除", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-inbox-cron-apply-"));
  try {
    const { bin, tab } = await makeFakeCrontab(dir, "SHELL=/bin/bash\n");
    const deployDir = await makeDeployDir(dir);

    const applied = runInstaller("apply", {
      CRONTAB_BIN: bin,
      DEPLOY_DIR: deployDir,
      CONFIRM_MANAGED_ACTION_INBOX_CRON: CONFIRM,
      MANAGED_ACTION_INBOX_MAX_PER_RUN: "7",
    });

    assert.equal(applied.exitCode, 0);
    assert.equal(applied.report.status, "inbox_cron_installed");
    assert.equal(applied.report.safety.writesCrontabOnly, true);
    assert.equal(applied.report.safety.installsDryRunInboxCron, true);
    assert.equal(applied.report.safety.callsManagedActionsLiveApi, false);
    assert.equal(applied.report.safety.writesOpenClawInstanceDirs, false);
    const afterApply = await readFile(tab, "utf8");
    assert.match(afterApply, /OPENCLAW_MANAGED_ACTION_INBOX_CRON_BEGIN/);
    assert.match(afterApply, /cd '[^']+' && CONFIRM_MANAGED_ACTION_INBOX_RUNNER=/);
    assert.match(afterApply, /managed-action-inbox-runner\.sh run-pending/);
    assert.match(afterApply, /MANAGED_ACTION_INBOX_MAX_PER_RUN='7'/);
    assert.doesNotMatch(afterApply, /api\/managed-actions\/live/);

    const status = runInstaller("status", {
      CRONTAB_BIN: bin,
      DEPLOY_DIR: deployDir,
      MANAGED_ACTION_INBOX_MAX_PER_RUN: "7",
    });
    assert.equal(status.report.status, "inbox_cron_installed");
    assert.equal(status.report.installed, true);
    assert.equal(status.report.needsUpdate, false);

    const removed = runInstaller("remove", {
      CRONTAB_BIN: bin,
      DEPLOY_DIR: deployDir,
      CONFIRM_MANAGED_ACTION_INBOX_CRON: CONFIRM,
      MANAGED_ACTION_INBOX_MAX_PER_RUN: "7",
    });
    assert.equal(removed.exitCode, 0);
    assert.equal(removed.report.status, "inbox_cron_removed");
    assert.equal(removed.report.safety.removesDryRunInboxCron, true);
    const afterRemove = await readFile(tab, "utf8");
    assert.match(afterRemove, /SHELL=\/bin\/bash/);
    assert.doesNotMatch(afterRemove, /OPENCLAW_MANAGED_ACTION_INBOX_CRON_BEGIN/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("managed action inbox cron apply 在 runner 缺失时阻断", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-inbox-cron-missing-"));
  try {
    const { bin } = await makeFakeCrontab(dir);
    const deployDir = join(dir, "deploy");
    await mkdir(deployDir, { recursive: true });

    const { exitCode, report } = runInstaller("apply", {
      CRONTAB_BIN: bin,
      DEPLOY_DIR: deployDir,
      CONFIRM_MANAGED_ACTION_INBOX_CRON: CONFIRM,
    });

    assert.notEqual(exitCode, 0);
    assert.equal(report.status, "blocked_runner_missing");
    assert.equal(report.safety.blockedBeforeWrite, true);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
