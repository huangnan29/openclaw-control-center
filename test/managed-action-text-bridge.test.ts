import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmod, copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "tom-readonly", "managed-action-text-bridge.sh");

async function makeFakeRunner(dir: string): Promise<{ runner: string; log: string }> {
  const runner = join(dir, "fake-managed-action-command-runner.sh");
  const log = join(dir, "fake-runner-call.json");
  await writeFile(
    runner,
    `#!/usr/bin/env bash
set -euo pipefail
node - "$1" "$2" "$FAKE_RUNNER_CALL_LOG" <<'NODE'
const fs = require("node:fs");
const mode = process.argv[2];
const file = process.argv[3];
const logPath = process.argv[4];
const text = fs.readFileSync(file, "utf8");
fs.writeFileSync(logPath, JSON.stringify({
  mode,
  file,
  text,
  confirm: process.env.CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN || "",
  tokenSource: process.env.MANAGED_ACTION_COMMAND_TOKEN_SOURCE || "",
  hasLocalToken: Boolean(process.env.LOCAL_API_TOKEN),
}, null, 2));
const commonSafety = {
  callsManagedActionsDryRunApi: mode === "dry-run-text",
  callsManagedActionsLiveApi: false,
  writesOpenClawInstanceDirs: false,
  restartsOpenClawInstances: false,
  opensLiveGate: false,
};
if (mode === "parse-text") {
  console.log(JSON.stringify({
    schemaVersion: 1,
    status: "parsed",
    command: {
      instanceId: "tom",
      action: "skill_run",
      operator: "Anan",
      skillName: "zhihu-human-ops-writing",
      confirmedText: "DRY-RUN-ONLY",
    },
    safety: commonSafety,
  }));
  process.exit(0);
}
if (mode === "plan-text") {
  console.log(JSON.stringify({
    schemaVersion: 1,
    status: "planned",
    target: {
      instanceId: "tom",
      action: "skill_run",
      operator: "Anan",
      skillName: "zhihu-human-ops-writing",
    },
    nextCommands: ["managed-action-text-bridge.sh dry-run <command.txt>"],
    safety: commonSafety,
  }));
  process.exit(0);
}
if (mode === "dry-run-text") {
  console.log(JSON.stringify({
    schemaVersion: 1,
    status: "dry_run_completed",
    target: {
      instanceId: "tom",
      action: "skill_run",
      operator: "Anan",
      skillName: "zhihu-human-ops-writing",
    },
    dryRunApi: {
      statusCode: 200,
      body: {
        ok: true,
        dryRun: true,
        commandPreview: ["openclaw skill dry-run for instance tom: zhihu-human-ops-writing"],
        review: { operationRequestId: "bridge-fake-dry-run" },
      },
    },
    safety: commonSafety,
  }));
  process.exit(0);
}
console.log(JSON.stringify({ status: "blocked_fake_unknown_mode", safety: commonSafety }));
process.exit(2);
NODE
`,
    "utf8",
  );
  await chmod(runner, 0o755);
  return { runner, log };
}

async function writeInput(dir: string, text = "对 tom 运行 zhihu-human-ops-writing dry-run"): Promise<string> {
  const file = join(dir, "command.txt");
  await writeFile(file, text, "utf8");
  return file;
}

function runBridge(
  mode: "parse" | "plan" | "dry-run",
  input: string | undefined,
  env: Record<string, string>,
  script = SCRIPT,
) {
  const result = spawnSync(script, input ? [mode, input] : [mode], {
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

test("managed action text bridge parse 写入 runtime 文本并调用 runner parse-text", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-text-bridge-parse-"));
  try {
    const deployDir = join(dir, "deploy");
    const input = await writeInput(dir);
    const { runner, log } = await makeFakeRunner(dir);

    const { exitCode, report, stdout } = runBridge("parse", input, {
      DEPLOY_DIR: deployDir,
      MANAGED_ACTION_COMMAND_RUNNER: runner,
      FAKE_RUNNER_CALL_LOG: log,
    });

    assert.equal(exitCode, 0);
    assert.equal(report.status, "bridge_parse_completed");
    assert.equal(report.runnerStatus, "parsed");
    assert.equal(report.inputPath, join(deployDir, "runtime", "managed-action-command.txt"));
    assert.equal(report.target.instanceId, "tom");
    assert.equal(report.target.action, "skill_run");
    assert.equal(report.target.skillName, "zhihu-human-ops-writing");
    assert.equal(report.safety.writesControlCenterRuntimeOnly, true);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
    assert.equal(report.safety.writesOpenClawInstanceDirs, false);
    assert.doesNotMatch(stdout, /api\/managed-actions\/live/);

    const written = await readFile(join(deployDir, "runtime", "managed-action-command.txt"), "utf8");
    assert.equal(written, "对 tom 运行 zhihu-human-ops-writing dry-run\n");
    const call = JSON.parse(await readFile(log, "utf8"));
    assert.equal(call.mode, "parse-text");
    assert.equal(call.file, join(deployDir, "runtime", "managed-action-command.txt"));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("managed action text bridge plan 只调用 runner plan-text", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-text-bridge-plan-"));
  try {
    const deployDir = join(dir, "deploy");
    const input = await writeInput(dir);
    const { runner, log } = await makeFakeRunner(dir);

    const { exitCode, report } = runBridge("plan", input, {
      DEPLOY_DIR: deployDir,
      MANAGED_ACTION_COMMAND_RUNNER: runner,
      FAKE_RUNNER_CALL_LOG: log,
    });

    assert.equal(exitCode, 0);
    assert.equal(report.status, "bridge_plan_completed");
    assert.equal(report.runnerStatus, "planned");
    assert.equal(report.safety.callsManagedActionsDryRunApi, false);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
    const call = JSON.parse(await readFile(log, "utf8"));
    assert.equal(call.mode, "plan-text");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("managed action text bridge dry-run 缺桥接确认时不会调用 runner", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-text-bridge-confirm-"));
  try {
    const deployDir = join(dir, "deploy");
    const input = await writeInput(dir);
    const { runner, log } = await makeFakeRunner(dir);

    const { exitCode, report } = runBridge("dry-run", input, {
      DEPLOY_DIR: deployDir,
      MANAGED_ACTION_COMMAND_RUNNER: runner,
      FAKE_RUNNER_CALL_LOG: log,
      LOCAL_API_TOKEN: "test-token",
    });

    assert.notEqual(exitCode, 0);
    assert.equal(report.status, "blocked_confirmation_required");
    assert.equal(report.safety.blockedBeforeRunner, true);
    assert.equal(report.safety.callsManagedActionsDryRunApi, false);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
    assert.equal(existsSync(log), false);
    assert.equal(existsSync(join(deployDir, "runtime", "managed-action-command.txt")), false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("managed action text bridge dry-run 设置 runner 确认并隐藏令牌", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-text-bridge-dry-run-"));
  try {
    const deployDir = join(dir, "deploy");
    const input = await writeInput(dir);
    const { runner, log } = await makeFakeRunner(dir);

    const { exitCode, report, stdout } = runBridge("dry-run", input, {
      DEPLOY_DIR: deployDir,
      MANAGED_ACTION_COMMAND_RUNNER: runner,
      FAKE_RUNNER_CALL_LOG: log,
      CONFIRM_MANAGED_ACTION_TEXT_BRIDGE: "I_UNDERSTAND_THIS_ONLY_RUNS_MANAGED_ACTION_DRY_RUN_TEXT",
      MANAGED_ACTION_COMMAND_TOKEN_SOURCE: "container",
      LOCAL_API_TOKEN: "test-token",
    });

    assert.equal(exitCode, 0);
    assert.equal(report.status, "bridge_dry_run_completed");
    assert.equal(report.runnerStatus, "dry_run_completed");
    assert.equal(report.operationRequestId, "bridge-fake-dry-run");
    assert.deepEqual(report.commandPreview, ["openclaw skill dry-run for instance tom: zhihu-human-ops-writing"]);
    assert.equal(report.safety.callsManagedActionsDryRunApi, true);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
    assert.equal(report.safety.writesOpenClawInstanceDirs, false);
    assert.doesNotMatch(stdout, /test-token/);
    assert.doesNotMatch(stdout, /api\/managed-actions\/live/);

    const call = JSON.parse(await readFile(log, "utf8"));
    assert.equal(call.mode, "dry-run-text");
    assert.equal(call.confirm, "I_UNDERSTAND_THIS_ONLY_CALLS_MANAGED_ACTION_DRY_RUN_API");
    assert.equal(call.tokenSource, "container");
    assert.equal(call.hasLocalToken, true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("managed action text bridge 在 Tom repo 布局下默认写部署根 runtime", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-text-bridge-layout-"));
  try {
    const deployDir = join(dir, "deploy");
    const scriptDir = join(deployDir, "repo", "ops", "tom-readonly");
    await mkdir(scriptDir, { recursive: true });
    await mkdir(join(deployDir, "runtime"), { recursive: true });
    const copiedScript = join(scriptDir, "managed-action-text-bridge.sh");
    await copyFile(SCRIPT, copiedScript);
    await chmod(copiedScript, 0o755);
    const input = await writeInput(dir);
    const { runner, log } = await makeFakeRunner(dir);

    const { exitCode, report } = runBridge("parse", input, {
      MANAGED_ACTION_COMMAND_RUNNER: runner,
      FAKE_RUNNER_CALL_LOG: log,
    }, copiedScript);

    assert.equal(exitCode, 0);
    assert.equal(report.status, "bridge_parse_completed");
    assert.equal(report.inputPath, join(deployDir, "runtime", "managed-action-command.txt"));
    const written = await readFile(join(deployDir, "runtime", "managed-action-command.txt"), "utf8");
    assert.equal(written, "对 tom 运行 zhihu-human-ops-writing dry-run\n");
    assert.equal(existsSync(join(deployDir, "repo", "runtime", "managed-action-command.txt")), false);
    const call = JSON.parse(await readFile(log, "utf8"));
    assert.equal(call.file, join(deployDir, "runtime", "managed-action-command.txt"));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
