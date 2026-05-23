import assert from "node:assert/strict";
import { chmod, mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import test from "node:test";
import { buildWindowsOpenClawCommandLine, OpenClawLiveClient } from "../src/clients/openclaw-live-client";

function attachSessionFile(client: OpenClawLiveClient, sessionKey: string, sessionFile: string): void {
  const internalClient = client as OpenClawLiveClient & {
    sessionCache: Map<string, { sessionFile?: string }>;
  };
  internalClient.sessionCache.set(sessionKey, { sessionFile });
}

async function installFakeOpenClawCli(
  tempDir: string,
  logPath: string,
  stdout: string,
  options: { logMode?: "text" | "json" } = {},
): Promise<string> {
  const binDir = join(tempDir, "bin");
  await mkdir(binDir, { recursive: true });

  const runnerPath = join(binDir, "openclaw-runner.js");
  const logStatement = options.logMode === "json"
    ? `fs.appendFileSync(${JSON.stringify(logPath)}, JSON.stringify(process.argv.slice(2)) + '\\n');`
    : `fs.appendFileSync(${JSON.stringify(logPath)}, process.argv.slice(2).join(' ') + '\\n');`;
  await writeFile(
    runnerPath,
    [
      "#!/usr/bin/env node",
      "const fs = require('node:fs');",
      logStatement,
      `process.stdout.write(${JSON.stringify(stdout)});`,
    ].join("\n"),
    "utf8",
  );
  await chmod(runnerPath, 0o755);

  const unixShimPath = join(binDir, "openclaw");
  await writeFile(unixShimPath, await readFile(runnerPath, "utf8"), "utf8");
  await chmod(unixShimPath, 0o755);

  const windowsShimPath = join(binDir, "openclaw.cmd");
  await writeFile(
    windowsShimPath,
    `@echo off\r\n"${process.execPath}" "${runnerPath}" %*\r\n`,
    "utf8",
  );

  return binDir;
}

async function installFakeWindowsShell(tempDir: string): Promise<string> {
  const shellPath = join(tempDir, "cmd.exe");
  await writeFile(
    shellPath,
    [
      "#!/bin/sh",
      "if [ \"$1\" = \"/d\" ] && [ \"$2\" = \"/s\" ] && [ \"$3\" = \"/c\" ]; then",
      "  shift 3",
      "  exec /bin/sh -lc \"$1\"",
      "fi",
      "echo \"unexpected shell args: $*\" >&2",
      "exit 64",
    ].join("\n"),
    "utf8",
  );
  await chmod(shellPath, 0o755);
  return shellPath;
}

async function withMockPlatform<T>(platform: NodeJS.Platform, callback: () => Promise<T>): Promise<T> {
  const originalPlatform = process.platform;
  Object.defineProperty(process, "platform", { value: platform });
  try {
    return await callback();
  } finally {
    Object.defineProperty(process, "platform", { value: originalPlatform });
  }
}

test("sessionsHistory reads recent history from large cached session files", async () => {
  const tempDir = await mkdtemp(join(tmpdir(), "openclaw-history-"));
  try {
    const sessionKey = "agent:main:cron:demo:run:child";
    const sessionFile = join(tempDir, "session.jsonl");
    const payload = "x".repeat(2048);
    const lines = Array.from({ length: 120 }, (_, index) =>
      JSON.stringify({ seq: index + 1, message: `entry-${index + 1}`, payload }),
    );
    await writeFile(sessionFile, `${lines.join("\n")}\n`, "utf8");

    const client = new OpenClawLiveClient();
    attachSessionFile(client, sessionKey, sessionFile);

    const response = await client.sessionsHistory({ sessionKey, limit: 3 });
    const history = Array.isArray(response.json?.history) ? response.json.history : [];

    assert.deepEqual(
      history.map((item) => (typeof item === "string" ? item : item.seq)),
      [118, 119, 120],
    );
    assert.match(response.rawText, /"seq":118/);
    assert.match(response.rawText, /"seq":120/);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
});

test("sessionsHistory keeps the last line when the history file has no trailing newline", async () => {
  const tempDir = await mkdtemp(join(tmpdir(), "openclaw-history-"));
  try {
    const sessionKey = "agent:coq:main";
    const sessionFile = join(tempDir, "session.jsonl");
    const lines = [
      JSON.stringify({ seq: 1, message: "first" }),
      JSON.stringify({ seq: 2, message: "second" }),
      JSON.stringify({ seq: 3, message: "third" }),
    ];
    await writeFile(sessionFile, lines.join("\n"), "utf8");

    const client = new OpenClawLiveClient();
    attachSessionFile(client, sessionKey, sessionFile);

    const response = await client.sessionsHistory({ sessionKey, limit: 2 });
    const history = Array.isArray(response.json?.history) ? response.json.history : [];

    assert.deepEqual(
      history.map((item) => (typeof item === "string" ? item : item.seq)),
      [2, 3],
    );
    assert.equal(response.rawText.trim().split("\n").length, 2);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
});

test("sessionsHistory returns empty immediately when a cached session file path is missing", async () => {
  const tempDir = await mkdtemp(join(tmpdir(), "openclaw-history-"));
  const originalPath = process.env.PATH;
  try {
    const sessionKey = "agent:main:demo";
    const cliLogPath = join(tempDir, "cli.log");
    const binDir = await installFakeOpenClawCli(
      tempDir,
      cliLogPath,
      JSON.stringify({
        history: [{ kind: "message", role: "assistant", content: "from-cli", timestamp: "2026-03-16T12:00:00.000Z" }],
      }),
    );
    process.env.PATH = binDir + delimiter + (originalPath ?? "");

    const client = new OpenClawLiveClient();
    attachSessionFile(client, sessionKey, join(tempDir, "missing-session.jsonl"));

    const response = await client.sessionsHistory({ sessionKey, limit: 2 });

    assert.equal(response.rawText, "");
    await assert.rejects(readFile(cliLogPath, "utf8"));
  } finally {
    process.env.PATH = originalPath;
    await rm(tempDir, { recursive: true, force: true });
  }
});

test("sessionsHistory uses bounded CLI recovery when a cached session file is unreadable", async () => {
  const tempDir = await mkdtemp(join(tmpdir(), "openclaw-history-"));
  const originalPath = process.env.PATH;
  try {
    const sessionKey = "agent:main:demo";
    const cliLogPath = join(tempDir, "cli.log");
    const binDir = await installFakeOpenClawCli(
      tempDir,
      cliLogPath,
      JSON.stringify({
        history: [{ kind: "message", role: "assistant", content: "from-cli", timestamp: "2026-03-16T12:00:00.000Z" }],
      }),
    );
    process.env.PATH = binDir + delimiter + (originalPath ?? "");

    const client = new OpenClawLiveClient();
    attachSessionFile(client, sessionKey, tempDir);

    const response = await client.sessionsHistory({ sessionKey, limit: 2 });
    const history = Array.isArray(response.json?.history) ? response.json.history : [];

    assert.deepEqual(
      history.map((item) => (typeof item === "string" ? item : item.content)),
      ["from-cli"],
    );
    const cliLog = await readFile(cliLogPath, "utf8");
    assert.match(cliLog, new RegExp("sessions history " + sessionKey));
  } finally {
    process.env.PATH = originalPath;
    await rm(tempDir, { recursive: true, force: true });
  }
});

test("agentRun passes message as a flagged argument instead of positional args", async () => {
  const tempDir = await mkdtemp(join(tmpdir(), "openclaw-agent-run-"));
  const originalPath = process.env.PATH;
  try {
    const cliLogPath = join(tempDir, "cli.log");
    const binDir = await installFakeOpenClawCli(
      tempDir,
      cliLogPath,
      JSON.stringify({
        status: "ok",
        result: {
          payloads: [{ text: "done" }],
          meta: {
            agentMeta: {
              sessionId: "session-1",
              model: "gpt-test",
            },
            systemPromptReport: {
              sessionKey: "agent:pandas:main",
            },
          },
        },
      }),
    );
    process.env.PATH = binDir + delimiter + (originalPath ?? "");

    const client = new OpenClawLiveClient();
    const response = await client.agentRun({
      agentId: "pandas",
      message: "hello from hall",
      thinking: "minimal",
      timeoutSeconds: 5,
    });

    assert.equal(response.ok, true);
    assert.equal(response.text, "done");
    const cliLog = await readFile(cliLogPath, "utf8");
    assert.match(cliLog, /agent --agent pandas --message hello from hall --thinking minimal --timeout 5 --json/);
    assert.doesNotMatch(cliLog, /agent pandas hello from hall/);
  } finally {
    process.env.PATH = originalPath;
    await rm(tempDir, { recursive: true, force: true });
  }
});

test("agentRun falls back to session history text when CLI omits ok payloads", async () => {
  const tempDir = await mkdtemp(join(tmpdir(), "openclaw-agent-run-status-"));
  const originalPath = process.env.PATH;
  try {
    const cliLogPath = join(tempDir, "cli.log");
    const sessionFile = join(tempDir, "session.jsonl");
    await writeFile(
      sessionFile,
      JSON.stringify({
        message: {
          role: "assistant",
          content: [{ type: "text", text: "skill 已连通" }],
        },
      }) + "\n",
      "utf8",
    );
    const binDir = join(tempDir, "bin");
    await mkdir(binDir, { recursive: true });
    const runnerPath = join(binDir, "openclaw");
    await writeFile(
      runnerPath,
      [
        "#!/usr/bin/env node",
        "const fs = require('node:fs');",
        `fs.appendFileSync(${JSON.stringify(cliLogPath)}, process.argv.slice(2).join(' ') + '\\n');`,
        "const args = process.argv.slice(2);",
        "if (args[0] === 'sessions') {",
        `  process.stdout.write(JSON.stringify({ sessions: [{ key: "agent:pandas:main", agentId: "pandas", sessionId: "session-1", sessionFile: ${JSON.stringify(sessionFile)}, updatedAt: Date.now() }] }));`,
        "} else {",
        "  process.stdout.write(JSON.stringify({ status: false, result: { meta: { agentMeta: { sessionId: 'session-1', model: 'gpt-test' }, systemPromptReport: { sessionKey: 'agent:pandas:main' } } } }));",
        "}",
      ].join("\n"),
      "utf8",
    );
    await chmod(runnerPath, 0o755);
    process.env.PATH = binDir + delimiter + (originalPath ?? "");

    const client = new OpenClawLiveClient();
    attachSessionFile(client, "agent:pandas:main", sessionFile);
    const response = await client.agentRun({
      agentId: "pandas",
      sessionKey: "agent:pandas:main",
      message: "检查 skill 连通性",
      thinking: "minimal",
      timeoutSeconds: 5,
    });

    assert.equal(response.ok, true);
    assert.equal(response.status, "ok");
    assert.equal(response.text, "skill 已连通");
  } finally {
    process.env.PATH = originalPath;
    await rm(tempDir, { recursive: true, force: true });
  }
});

test("buildWindowsOpenClawCommandLine quotes multiline hall prompts as a single message argument", () => {
  const message = "line one\nline two with spaces & symbols \"quoted\"";
  const commandLine = buildWindowsOpenClawCommandLine("C:\\tools\\openclaw.cmd", [
    "agent",
    "--agent",
    "pandas",
    "--message",
    message,
    "--thinking",
    "minimal",
  ]);

  assert.match(commandLine, /^C:\\tools\\openclaw\.cmd agent --agent pandas --message "/);
  assert.match(commandLine, /line one\nline two with spaces & symbols \\"quoted\\"/);
  assert.match(commandLine, /" --thinking minimal$/);
});

test("agentRunStream keeps multiline hall prompts intact on the Windows execution path", async () => {
  const tempDir = await mkdtemp(join(tmpdir(), "openclaw-agent-stream-win-"));
  const originalPath = process.env.PATH;
  const originalBinPath = process.env.OPENCLAW_BIN_PATH;
  const originalComSpec = process.env.ComSpec;
  const originalCOMSPEC = process.env.COMSPEC;
  try {
    const cliLogPath = join(tempDir, "cli.jsonl");
    const binDir = await installFakeOpenClawCli(
      tempDir,
      cliLogPath,
      "streamed answer",
      { logMode: "json" },
    );
    const fakeWindowsShell = await installFakeWindowsShell(tempDir);
    process.env.PATH = binDir + delimiter + (originalPath ?? "");
    process.env.OPENCLAW_BIN_PATH = join(binDir, "openclaw");
    process.env.ComSpec = fakeWindowsShell;
    process.env.COMSPEC = fakeWindowsShell;

    const message = "first line\nsecond line with handoff @pandas";
    await withMockPlatform("win32", async () => {
      const client = new OpenClawLiveClient();
      const chunks: string[] = [];
      const response = await client.agentRunStream({
        agentId: "pandas",
        sessionKey: "agent:pandas:main",
        message,
        thinking: "minimal",
        timeoutSeconds: 5,
      }, {
        onStdoutChunk: (chunk) => {
          chunks.push(chunk);
        },
      });

      assert.equal(response.ok, true);
      assert.equal(response.text, "streamed answer");
      assert.equal(chunks.join(""), "streamed answer");
    });

    const cliLog = await readFile(cliLogPath, "utf8");
    const argv = JSON.parse(cliLog.trim().split("\n").at(-1) ?? "[]") as string[];
    assert.equal(argv[0], "agent");
    assert.equal(argv[1], "--session-id");
    assert.ok(argv[2]);
    assert.equal(argv[3], "--message");
    assert.equal(argv[4], message);
    assert.equal(argv[5], "--thinking");
    assert.equal(argv[6], "minimal");
  } finally {
    process.env.PATH = originalPath;
    if (originalBinPath === undefined) {
      delete process.env.OPENCLAW_BIN_PATH;
    } else {
      process.env.OPENCLAW_BIN_PATH = originalBinPath;
    }
    if (originalComSpec === undefined) {
      delete process.env.ComSpec;
    } else {
      process.env.ComSpec = originalComSpec;
    }
    if (originalCOMSPEC === undefined) {
      delete process.env.COMSPEC;
    } else {
      process.env.COMSPEC = originalCOMSPEC;
    }
    await rm(tempDir, { recursive: true, force: true });
  }
});
