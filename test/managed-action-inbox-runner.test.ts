import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { existsSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "tom-readonly", "managed-action-inbox-runner.sh");

async function makeFakeBridge(dir: string): Promise<{ bridge: string; log: string }> {
  const bridge = join(dir, "fake-managed-action-text-bridge.sh");
  const log = join(dir, "fake-bridge-call.jsonl");
  await writeFile(
    bridge,
    `#!/usr/bin/env bash
set -euo pipefail
mode="$1"
file="$2"
node - "$mode" "$file" "$FAKE_BRIDGE_CALL_LOG" <<'NODE'
const fs = require("node:fs");
const mode = process.argv[2];
const file = process.argv[3];
const logPath = process.argv[4];
const text = fs.readFileSync(file, "utf8");
fs.appendFileSync(logPath, JSON.stringify({
  mode,
  file,
  text,
  bridgeConfirm: process.env.CONFIRM_MANAGED_ACTION_TEXT_BRIDGE || "",
  tokenSource: process.env.MANAGED_ACTION_COMMAND_TOKEN_SOURCE || "",
}) + "\\n");
const commonSafety = {
  callsManagedActionsDryRunApi: mode === "dry-run",
  callsManagedActionsLiveApi: false,
  writesControlCenterRuntimeOnly: true,
  writesOpenClawInstanceDirs: false,
  restartsOpenClawInstances: false,
  opensLiveGate: false,
};
if (text.includes("发布")) {
  console.log(JSON.stringify({
    status: "blocked_bridge_runner",
    runnerStatus: "blocked_invalid_command",
    issues: ["文本指令包含高风险词，已阻止。"],
    safety: commonSafety,
  }));
  process.exit(2);
}
if (mode === "plan") {
  console.log(JSON.stringify({
    status: "bridge_plan_completed",
    runnerStatus: "planned",
    target: { instanceId: "tom", action: "skill_run", skillName: "zhihu-human-ops-writing" },
    safety: commonSafety,
  }));
  process.exit(0);
}
if (mode === "dry-run") {
  console.log(JSON.stringify({
    status: "bridge_dry_run_completed",
    runnerStatus: "dry_run_completed",
    target: { instanceId: "tom", action: "skill_run", skillName: "zhihu-human-ops-writing" },
    operationRequestId: "inbox-fake-dry-run",
    commandPreview: ["openclaw skill dry-run for instance tom: zhihu-human-ops-writing"],
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
  await chmod(bridge, 0o755);
  return { bridge, log };
}

async function writeInboxCommand(inbox: string, name: string, text = "对 tom 运行 zhihu-human-ops-writing dry-run"): Promise<string> {
  await mkdir(inbox, { recursive: true });
  const file = join(inbox, name);
  await writeFile(file, text, "utf8");
  return file;
}

function runInbox(
  mode: "status" | "plan-next" | "run-next",
  env: Record<string, string>,
) {
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

test("managed action inbox runner status 只列出待处理请求且不调用桥接层", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-inbox-status-"));
  try {
    const inbox = join(dir, "inbox");
    const runtime = join(dir, "runtime");
    const commandFile = await writeInboxCommand(inbox, "001.txt");
    const { bridge, log } = await makeFakeBridge(dir);

    const { exitCode, report, stdout } = runInbox("status", {
      RUNTIME_DIR: runtime,
      MANAGED_ACTION_INBOX_DIR: inbox,
      MANAGED_ACTION_TEXT_BRIDGE: bridge,
      FAKE_BRIDGE_CALL_LOG: log,
    });

    assert.equal(exitCode, 0);
    assert.equal(report.status, "inbox_status_ready");
    assert.equal(report.pendingCount, 1);
    assert.equal(report.next?.sourcePath, commandFile);
    assert.equal(report.safety.callsManagedActionsDryRunApi, false);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
    assert.equal(report.safety.writesOpenClawInstanceDirs, false);
    assert.equal(existsSync(log), false);
    assert.doesNotMatch(stdout, /api\/managed-actions\/live/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("managed action inbox runner plan-next 调用桥接层 plan 且不标记已处理", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-inbox-plan-"));
  try {
    const inbox = join(dir, "inbox");
    const runtime = join(dir, "runtime");
    const commandFile = await writeInboxCommand(inbox, "001.txt");
    const { bridge, log } = await makeFakeBridge(dir);

    const { exitCode, report } = runInbox("plan-next", {
      RUNTIME_DIR: runtime,
      MANAGED_ACTION_INBOX_DIR: inbox,
      MANAGED_ACTION_TEXT_BRIDGE: bridge,
      FAKE_BRIDGE_CALL_LOG: log,
    });

    assert.equal(exitCode, 0);
    assert.equal(report.status, "inbox_plan_completed");
    assert.equal(report.sourcePath, commandFile);
    assert.equal(report.bridgeStatus, "bridge_plan_completed");
    assert.equal(report.safety.callsManagedActionsDryRunApi, false);
    const call = JSON.parse((await readFile(log, "utf8")).trim());
    assert.equal(call.mode, "plan");
    assert.equal(call.text, "对 tom 运行 zhihu-human-ops-writing dry-run\n");
    assert.equal(existsSync(join(runtime, "managed-action-inbox-runner", "state.json")), false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("managed action inbox runner run-next 需要确认，缺确认不会调用桥接层", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-inbox-confirm-"));
  try {
    const inbox = join(dir, "inbox");
    const runtime = join(dir, "runtime");
    await writeInboxCommand(inbox, "001.txt");
    const { bridge, log } = await makeFakeBridge(dir);

    const { exitCode, report } = runInbox("run-next", {
      RUNTIME_DIR: runtime,
      MANAGED_ACTION_INBOX_DIR: inbox,
      MANAGED_ACTION_TEXT_BRIDGE: bridge,
      FAKE_BRIDGE_CALL_LOG: log,
      MANAGED_ACTION_COMMAND_TOKEN_SOURCE: "container",
    });

    assert.notEqual(exitCode, 0);
    assert.equal(report.status, "blocked_confirmation_required");
    assert.equal(report.safety.blockedBeforeBridge, true);
    assert.equal(report.safety.callsManagedActionsDryRunApi, false);
    assert.equal(existsSync(log), false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("managed action inbox runner run-next dry-run 后写 control-center runtime 状态并隐藏令牌", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-inbox-run-"));
  try {
    const inbox = join(dir, "inbox");
    const runtime = join(dir, "runtime");
    const commandFile = await writeInboxCommand(inbox, "001.txt");
    const { bridge, log } = await makeFakeBridge(dir);

    const { exitCode, report, stdout } = runInbox("run-next", {
      RUNTIME_DIR: runtime,
      MANAGED_ACTION_INBOX_DIR: inbox,
      MANAGED_ACTION_TEXT_BRIDGE: bridge,
      FAKE_BRIDGE_CALL_LOG: log,
      CONFIRM_MANAGED_ACTION_INBOX_RUNNER: "I_UNDERSTAND_THIS_READS_OPENCLAW_INBOX_AND_RUNS_DRY_RUN_TEXT",
      MANAGED_ACTION_COMMAND_TOKEN_SOURCE: "container",
      LOCAL_API_TOKEN: "test-token",
    });

    assert.equal(exitCode, 0);
    assert.equal(report.status, "inbox_dry_run_completed");
    assert.equal(report.sourcePath, commandFile);
    assert.equal(report.bridgeStatus, "bridge_dry_run_completed");
    assert.equal(report.operationRequestId, "inbox-fake-dry-run");
    assert.equal(report.safety.callsManagedActionsDryRunApi, true);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
    assert.equal(report.safety.writesControlCenterRuntimeOnly, true);
    assert.equal(report.safety.writesOpenClawInstanceDirs, false);
    assert.doesNotMatch(stdout, /test-token/);
    assert.doesNotMatch(stdout, /api\/managed-actions\/live/);

    const call = JSON.parse((await readFile(log, "utf8")).trim());
    assert.equal(call.mode, "dry-run");
    assert.equal(call.bridgeConfirm, "I_UNDERSTAND_THIS_ONLY_RUNS_MANAGED_ACTION_DRY_RUN_TEXT");
    assert.equal(call.tokenSource, "container");

    const state = JSON.parse(await readFile(join(runtime, "managed-action-inbox-runner", "state.json"), "utf8"));
    assert.equal(state.processed.length, 1);
    assert.equal(state.processed[0].sourcePath, commandFile);
    const results = readdirSync(join(runtime, "managed-action-inbox-runner", "results"));
    assert.equal(results.length, 1);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
