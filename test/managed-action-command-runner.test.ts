import assert from "node:assert/strict";
import { execFile, spawnSync } from "node:child_process";
import { createServer, type IncomingMessage } from "node:http";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { promisify } from "node:util";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "tom-readonly", "managed-action-command-runner.sh");
const execFileAsync = promisify(execFile);
type RunnerMode = "status" | "plan" | "dry-run" | "parse-text" | "plan-text" | "dry-run-text";

async function writeCommandFile(dir: string, overrides: Record<string, unknown> = {}): Promise<string> {
  const file = join(dir, "managed-action-command.json");
  await writeFile(
    file,
    JSON.stringify(
      {
        instanceId: "tom",
        action: "skill_run",
        operator: "Anan",
        reason: "通过 OpenClaw 指令预览 skill 调用",
        skillName: "zhihu-human-ops-writing",
        ...overrides,
      },
      null,
      2,
    ),
    "utf8",
  );
  return file;
}

async function writeCommandTextFile(dir: string, text = "对 tom 运行 zhihu-human-ops-writing dry-run"): Promise<string> {
  const file = join(dir, "managed-action-command.txt");
  await writeFile(file, text, "utf8");
  return file;
}

function runRunner(
  mode: RunnerMode,
  file?: string,
  env: Record<string, string> = {},
) {
  const result = spawnSync(SCRIPT, file ? [mode, file] : [mode], {
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

async function runRunnerAsync(
  mode: RunnerMode,
  file?: string,
  env: Record<string, string> = {},
) {
  const { stdout, stderr } = await execFileAsync(SCRIPT, file ? [mode, file] : [mode], {
    cwd: ROOT,
    env: {
      ...process.env,
      ...env,
    },
  });
  return {
    exitCode: 0,
    stdout,
    stderr,
    report: JSON.parse(stdout),
  };
}

async function readBody(req: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks).toString("utf8");
}

async function withFakeApi<T>(
  handler: (
    baseUrl: string,
    requests: Array<{ method?: string; url?: string; headers: IncomingMessage["headers"]; body: string }>,
  ) => Promise<T>,
): Promise<T> {
  const requests: Array<{ method?: string; url?: string; headers: IncomingMessage["headers"]; body: string }> = [];
  const server = createServer(async (req, res) => {
    const body = await readBody(req);
    requests.push({ method: req.method, url: req.url, headers: req.headers, body });

    if (req.method === "GET" && req.url === "/api/managed-actions") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true, dryRunOnly: true, actions: [{ action: "skill_run" }] }));
      return;
    }
    if (req.method === "GET" && req.url === "/api/managed-actions/readiness") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true, status: "blocked", liveExecutionAvailable: false }));
      return;
    }
    if (req.method === "POST" && req.url === "/api/managed-actions/dry-run") {
      const parsed = JSON.parse(body);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({
        ok: true,
        status: "dry_run_ready",
        dryRun: true,
        liveExecution: false,
        action: parsed.action,
        target: { instanceId: parsed.instanceId, instanceName: "Tom / Work" },
        commandPreview: [`openclaw skill dry-run for instance ${parsed.instanceId}: ${parsed.skillName}`],
        safety: { mutatesOpenClawInstance: false, requiresConfirmation: true, auditRequired: true },
        review: {
          operationRequestId: "dry-run-from-fake-api",
          operator: parsed.operator,
          reason: parsed.reason,
          confirmationTextMatched: parsed.confirmedText === "DRY-RUN-ONLY",
        },
      }));
      return;
    }

    res.writeHead(404, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: false, status: "not_found" }));
  });

  await new Promise<void>((resolve, reject) => {
    server.listen(0, "127.0.0.1", resolve);
    server.once("error", reject);
  });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("fake API 端口绑定失败。");
  const baseUrl = `http://127.0.0.1:${address.port}`;

  try {
    return await handler(baseUrl, requests);
  } finally {
    await new Promise<void>((resolve, reject) => {
      server.close((error) => error ? reject(error) : resolve());
    });
  }
}

test("managed action command runner plan 只校验命令且不需要网络", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-command-plan-"));
  try {
    const file = await writeCommandFile(dir);
    const { exitCode, report, stdout } = runRunner("plan", file, {
      CONTROL_CENTER_BASE_URL: "http://127.0.0.1:9",
    });

    assert.equal(exitCode, 0);
    assert.equal(report.status, "planned");
    assert.equal(report.target.instanceId, "tom");
    assert.equal(report.target.action, "skill_run");
    assert.equal(report.target.skillName, "zhihu-human-ops-writing");
    assert.equal(report.payload.confirmedText, "DRY-RUN-ONLY");
    assert.equal(report.safety.callsManagedActionsDryRunApi, false);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
    assert.equal(report.safety.writesOpenClawInstanceDirs, false);
    assert.doesNotMatch(stdout, /api\/managed-actions\/live/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("managed action command runner parse-text 把中文指令转成 skill_run 命令", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-command-text-"));
  try {
    const file = await writeCommandTextFile(dir);
    const { exitCode, report, stdout } = runRunner("parse-text", file, {
      CONTROL_CENTER_BASE_URL: "http://127.0.0.1:9",
    });

    assert.equal(exitCode, 0);
    assert.equal(report.status, "parsed");
    assert.equal(report.command.instanceId, "tom");
    assert.equal(report.command.action, "skill_run");
    assert.equal(report.command.skillName, "zhihu-human-ops-writing");
    assert.equal(report.command.operator, "Anan");
    assert.equal(report.command.confirmedText, "DRY-RUN-ONLY");
    assert.equal(report.safety.callsManagedActionsDryRunApi, false);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
    assert.equal(report.safety.writesOpenClawInstanceDirs, false);
    assert.doesNotMatch(stdout, /api\/managed-actions\/live/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("managed action command runner plan-text 不联网且提示 dry-run-text 下一步", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-command-plan-text-"));
  try {
    const file = await writeCommandTextFile(dir, "instance=tom action=skill_run skill=zhihu-human-ops-writing dry-run");
    const { exitCode, report } = runRunner("plan-text", file, {
      CONTROL_CENTER_BASE_URL: "http://127.0.0.1:9",
    });

    assert.equal(exitCode, 0);
    assert.equal(report.status, "planned");
    assert.equal(report.target.instanceId, "tom");
    assert.equal(report.target.action, "skill_run");
    assert.equal(report.target.skillName, "zhihu-human-ops-writing");
    assert(report.nextCommands.some((command: string) => command.includes("dry-run-text")));
    assert.equal(report.safety.callsManagedActionsDryRunApi, false);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("managed action command runner parse-text 阻止未声明 dry-run 或高风险词", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-command-text-block-"));
  try {
    const missingDryRun = await writeCommandTextFile(dir, "对 tom 运行 zhihu-human-ops-writing");
    const missing = runRunner("parse-text", missingDryRun);
    assert.notEqual(missing.exitCode, 0);
    assert.equal(missing.report.status, "blocked_invalid_command");
    assert(missing.report.issues.some((issue: string) => issue.includes("dry-run")));

    const risky = await writeCommandTextFile(dir, "对 tom 运行 zhihu-human-ops-writing dry-run 后发布");
    const riskyResult = runRunner("parse-text", risky);
    assert.notEqual(riskyResult.exitCode, 0);
    assert.equal(riskyResult.report.status, "blocked_invalid_command");
    assert(riskyResult.report.issues.some((issue: string) => issue.includes("高风险词")));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("managed action command runner dry-run 缺确认时不会调用 API", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-command-confirm-"));
  try {
    const file = await writeCommandFile(dir);
    await withFakeApi(async (_baseUrl, requests) => {
      const { exitCode, report } = runRunner("dry-run", file, {
        CONTROL_CENTER_BASE_URL: "http://127.0.0.1:9",
        LOCAL_API_TOKEN: "test-token",
      });

      assert.notEqual(exitCode, 0);
      assert.equal(report.status, "blocked_confirmation_required");
      assert.equal(report.safety.blockedBeforeApi, true);
      assert.equal(requests.length, 0);
    });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("managed action command runner dry-run 只调用 dry-run API 并隐藏令牌", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-command-dry-run-"));
  try {
    const file = await writeCommandFile(dir);
    await withFakeApi(async (baseUrl, requests) => {
      const { exitCode, report, stdout } = await runRunnerAsync("dry-run", file, {
        CONTROL_CENTER_BASE_URL: baseUrl,
        CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN: "I_UNDERSTAND_THIS_ONLY_CALLS_MANAGED_ACTION_DRY_RUN_API",
        LOCAL_API_TOKEN: "test-token",
      });

      assert.equal(exitCode, 0);
      assert.equal(report.status, "dry_run_completed");
      assert.equal(report.target.instanceId, "tom");
      assert.equal(report.target.action, "skill_run");
      assert.equal(report.dryRunApi.statusCode, 200);
      assert.equal(report.dryRunApi.body.review.operationRequestId, "dry-run-from-fake-api");
      assert.equal(report.safety.callsManagedActionsDryRunApi, true);
      assert.equal(report.safety.callsManagedActionsLiveApi, false);
      assert.equal(report.safety.writesOpenClawInstanceDirs, false);
      assert.equal(report.safety.restartsOpenClawInstances, false);
      assert.equal(report.safety.localApiTokenSource, "env");
      assert.equal(requests.length, 1);
      assert.equal(requests[0]?.method, "POST");
      assert.equal(requests[0]?.url, "/api/managed-actions/dry-run");
      assert.equal(requests[0]?.headers["x-local-token"], "test-token");
      assert.equal(JSON.parse(requests[0]?.body || "{}").confirmedText, "DRY-RUN-ONLY");
      assert.doesNotMatch(stdout, /test-token/);
      assert.doesNotMatch(stdout, /api\/managed-actions\/live/);
    });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("managed action command runner dry-run-text 只调用 dry-run API", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-managed-action-command-dry-run-text-"));
  try {
    const file = await writeCommandTextFile(dir);
    await withFakeApi(async (baseUrl, requests) => {
      const { exitCode, report } = await runRunnerAsync("dry-run-text", file, {
        CONTROL_CENTER_BASE_URL: baseUrl,
        CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN: "I_UNDERSTAND_THIS_ONLY_CALLS_MANAGED_ACTION_DRY_RUN_API",
        LOCAL_API_TOKEN: "test-token",
      });

      assert.equal(exitCode, 0);
      assert.equal(report.status, "dry_run_completed");
      assert.equal(report.target.instanceId, "tom");
      assert.equal(report.target.action, "skill_run");
      assert.equal(report.target.skillName, "zhihu-human-ops-writing");
      assert.equal(report.safety.callsManagedActionsDryRunApi, true);
      assert.equal(report.safety.callsManagedActionsLiveApi, false);
      assert.equal(requests.length, 1);
      assert.equal(requests[0]?.url, "/api/managed-actions/dry-run");
      const body = JSON.parse(requests[0]?.body || "{}");
      assert.equal(body.instanceId, "tom");
      assert.equal(body.action, "skill_run");
      assert.equal(body.skillName, "zhihu-human-ops-writing");
      assert.equal(body.confirmedText, "DRY-RUN-ONLY");
    });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
