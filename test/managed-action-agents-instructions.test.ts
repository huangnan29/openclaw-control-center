import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { existsSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "tom-readonly", "install-managed-action-agents-instructions.sh");

function runInstaller(mode: "status" | "plan" | "apply", env: Record<string, string>) {
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

async function writeAgentsFile(dir: string, content = "# AGENTS\n\n现有规则。\n"): Promise<string> {
  const file = join(dir, "workspace", "AGENTS.md");
  await mkdir(dirname(file), { recursive: true });
  await writeFile(file, content, "utf8");
  return file;
}

test("managed action AGENTS installer plan 只报告变更不写文件", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-agents-plan-"));
  try {
    const agentsPath = await writeAgentsFile(dir);
    const before = await readFile(agentsPath, "utf8");

    const { exitCode, report, stdout } = runInstaller("plan", {
      MANAGED_ACTION_AGENTS_TARGET_SOURCE: "local",
      MANAGED_ACTION_AGENTS_TARGET_PATH: agentsPath,
    });

    assert.equal(exitCode, 0);
    assert.equal(report.status, "agents_instructions_plan_ready");
    assert.equal(report.target.path, agentsPath);
    assert.equal(report.plan.needsUpdate, true);
    assert.match(report.plan.block, /OpenClaw Control Center 受控管理动作/);
    assert.equal(report.safety.writesAgentsMdOnly, false);
    assert.equal(report.safety.writesOpenClawConfig, false);
    assert.equal(report.safety.restartsOpenClawInstances, false);
    assert.doesNotMatch(stdout, /api\/managed-actions\/live/);
    assert.equal(await readFile(agentsPath, "utf8"), before);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("managed action AGENTS installer apply 缺确认时不写文件", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-agents-confirm-"));
  try {
    const agentsPath = await writeAgentsFile(dir);
    const before = await readFile(agentsPath, "utf8");

    const { exitCode, report } = runInstaller("apply", {
      MANAGED_ACTION_AGENTS_TARGET_SOURCE: "local",
      MANAGED_ACTION_AGENTS_TARGET_PATH: agentsPath,
    });

    assert.notEqual(exitCode, 0);
    assert.equal(report.status, "blocked_confirmation_required");
    assert.equal(report.safety.blockedBeforeWrite, true);
    assert.equal(report.safety.writesAgentsMdOnly, false);
    assert.equal(await readFile(agentsPath, "utf8"), before);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("managed action AGENTS installer apply 插入标记块并备份原文件", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-agents-apply-"));
  try {
    const agentsPath = await writeAgentsFile(dir);

    const { exitCode, report, stdout } = runInstaller("apply", {
      MANAGED_ACTION_AGENTS_TARGET_SOURCE: "local",
      MANAGED_ACTION_AGENTS_TARGET_PATH: agentsPath,
      CONFIRM_MANAGED_ACTION_AGENTS_INSTALL: "I_UNDERSTAND_THIS_UPDATES_TOM_AGENTS_INSTRUCTIONS_ONLY",
    });

    assert.equal(exitCode, 0);
    assert.equal(report.status, "agents_instructions_installed");
    assert.equal(report.target.path, agentsPath);
    assert.equal(report.safety.writesAgentsMdOnly, true);
    assert.equal(report.safety.writesOpenClawConfig, false);
    assert.equal(report.safety.restartsOpenClawInstances, false);
    assert.doesNotMatch(stdout, /api\/managed-actions\/live/);

    const content = await readFile(agentsPath, "utf8");
    assert.match(content, /OPENCLAW_CONTROL_CENTER_MANAGED_ACTIONS_BEGIN/);
    assert.match(content, /control-center-commands\/inbox/);
    assert.match(content, /只写入 inbox 文本请求/);
    assert.match(content, /不要调用 control-center API/);
    assert.match(content, /不要读取或输出 LOCAL_API_TOKEN/);

    const backups = readdirSync(join(dirname(agentsPath), ".backup", "control-center-agents"));
    assert.equal(backups.length, 1);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("managed action AGENTS installer apply 后 status 不应再次要求更新", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-agents-status-"));
  try {
    const agentsPath = await writeAgentsFile(dir);

    const applied = runInstaller("apply", {
      MANAGED_ACTION_AGENTS_TARGET_SOURCE: "local",
      MANAGED_ACTION_AGENTS_TARGET_PATH: agentsPath,
      CONFIRM_MANAGED_ACTION_AGENTS_INSTALL: "I_UNDERSTAND_THIS_UPDATES_TOM_AGENTS_INSTRUCTIONS_ONLY",
    });
    assert.equal(applied.exitCode, 0);

    const checked = runInstaller("status", {
      MANAGED_ACTION_AGENTS_TARGET_SOURCE: "local",
      MANAGED_ACTION_AGENTS_TARGET_PATH: agentsPath,
    });

    assert.equal(checked.exitCode, 0);
    assert.equal(checked.report.status, "agents_instructions_installed");
    assert.equal(checked.report.installed, true);
    assert.equal(checked.report.needsUpdate, false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("managed action AGENTS installer apply 可幂等更新已有标记块", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-agents-idempotent-"));
  try {
    const agentsPath = await writeAgentsFile(
      dir,
      [
        "# AGENTS",
        "",
        "<!-- OPENCLAW_CONTROL_CENTER_MANAGED_ACTIONS_BEGIN -->",
        "旧内容",
        "<!-- OPENCLAW_CONTROL_CENTER_MANAGED_ACTIONS_END -->",
        "",
        "尾部规则。",
        "",
      ].join("\n"),
    );

    const { exitCode, report } = runInstaller("apply", {
      MANAGED_ACTION_AGENTS_TARGET_SOURCE: "local",
      MANAGED_ACTION_AGENTS_TARGET_PATH: agentsPath,
      CONFIRM_MANAGED_ACTION_AGENTS_INSTALL: "I_UNDERSTAND_THIS_UPDATES_TOM_AGENTS_INSTRUCTIONS_ONLY",
    });

    assert.equal(exitCode, 0);
    assert.equal(report.status, "agents_instructions_installed");
    const content = await readFile(agentsPath, "utf8");
    assert.doesNotMatch(content, /旧内容/);
    assert.match(content, /尾部规则。/);
    assert.equal((content.match(/OPENCLAW_CONTROL_CENTER_MANAGED_ACTIONS_BEGIN/g) || []).length, 1);
    assert.equal((content.match(/OPENCLAW_CONTROL_CENTER_MANAGED_ACTIONS_END/g) || []).length, 1);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
