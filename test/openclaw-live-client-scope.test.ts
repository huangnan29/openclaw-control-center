import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { OpenClawLiveClient } from "../src/clients/openclaw-live-client";

const root = process.cwd();

test("openclaw live client exposes scoped instance plumbing", async () => {
  const source = await readFile(join(root, "src", "clients", "openclaw-live-client.ts"), "utf8");

  assert.match(source, /interface OpenClawLiveClientScope/);
  assert.match(source, /constructor\(private readonly scope: OpenClawLiveClientScope = \{\}\)/);
  assert.match(source, /private resolveOpenClawHomePath/);
  assert.match(source, /private buildScopedCommandEnv/);
  assert.match(source, /OPENCLAW_HOME/);
  assert.match(source, /OPENCLAW_CONFIG_PATH/);
});

test("client factory can create scoped OpenClaw clients", async () => {
  const source = await readFile(join(root, "src", "clients", "factory.ts"), "utf8");

  assert.match(source, /export function createScopedToolClient\(instance: OpenClawInstanceConfig\): ToolClient/);
  assert.match(source, /new OpenClawLiveClient\(scope\)/);
});

test("sessionsHistory CLI fallback uses scoped env and workspace cwd", async () => {
  const tempDir = await mkdtemp(join(tmpdir(), "openclaw-scope-history-"));
  const originalBinPath = process.env.OPENCLAW_BIN_PATH;
  const originalBin = process.env.OPENCLAW_BIN;
  const originalHome = process.env.OPENCLAW_HOME;
  const originalConfigPath = process.env.OPENCLAW_CONFIG_PATH;
  const originalGatewayUrl = process.env.GATEWAY_URL;

  try {
    const openclawHome = join(tempDir, "scoped-home");
    const workspaceRoot = join(tempDir, "workspace");
    const openclawConfigPath = join(openclawHome, "openclaw.json");
    const gatewayUrl = "ws://127.0.0.1:19999";
    const cliLogPath = join(tempDir, "cli.jsonl");
    const fakeCliPath = join(tempDir, "openclaw");

    await mkdir(openclawHome, { recursive: true });
    await mkdir(workspaceRoot, { recursive: true });
    await writeFile(
      openclawConfigPath,
      JSON.stringify({ agents: { list: [{ id: "main", name: "main" }] } }),
      "utf8",
    );
    await writeFile(
      fakeCliPath,
      [
        "#!/usr/bin/env node",
        "const fs = require('node:fs');",
        `fs.appendFileSync(${JSON.stringify(cliLogPath)}, JSON.stringify({`,
        "  argv: process.argv.slice(2),",
        "  cwd: process.cwd(),",
        "  env: {",
        "    OPENCLAW_HOME: process.env.OPENCLAW_HOME,",
        "    OPENCLAW_CONFIG_PATH: process.env.OPENCLAW_CONFIG_PATH,",
        "    GATEWAY_URL: process.env.GATEWAY_URL,",
        "  },",
        "}) + '\\n');",
        "process.stdout.write(JSON.stringify({ history: [{ content: 'from-scoped-cli' }] }));",
      ].join("\n"),
      "utf8",
    );
    await chmod(fakeCliPath, 0o755);

    process.env.OPENCLAW_BIN_PATH = fakeCliPath;
    delete process.env.OPENCLAW_BIN;
    process.env.OPENCLAW_HOME = join(tempDir, "default-home");
    process.env.OPENCLAW_CONFIG_PATH = join(tempDir, "default-openclaw.json");
    process.env.GATEWAY_URL = "ws://127.0.0.1:18888";

    const client = new OpenClawLiveClient({
      openclawHome,
      openclawConfigPath,
      workspaceRoot,
      gatewayUrl,
    });
    const response = await client.sessionsHistory({ sessionKey: "agent:main:demo", limit: 2 });
    const history = Array.isArray(response.json?.history) ? response.json.history : [];

    assert.deepEqual(history.map((item) => (typeof item === "string" ? item : item.content)), ["from-scoped-cli"]);
    const cliLog = JSON.parse((await readFile(cliLogPath, "utf8")).trim()) as {
      argv: string[];
      cwd: string;
      env: Record<string, string | undefined>;
    };
    assert.deepEqual(cliLog.argv.slice(0, 3), ["sessions", "history", "agent:main:demo"]);
    assert.equal(await realpath(cliLog.cwd), await realpath(workspaceRoot));
    assert.equal(cliLog.env.OPENCLAW_HOME, openclawHome);
    assert.equal(cliLog.env.OPENCLAW_CONFIG_PATH, openclawConfigPath);
    assert.equal(cliLog.env.GATEWAY_URL, gatewayUrl);
  } finally {
    if (originalBinPath === undefined) delete process.env.OPENCLAW_BIN_PATH;
    else process.env.OPENCLAW_BIN_PATH = originalBinPath;
    if (originalBin === undefined) delete process.env.OPENCLAW_BIN;
    else process.env.OPENCLAW_BIN = originalBin;
    if (originalHome === undefined) delete process.env.OPENCLAW_HOME;
    else process.env.OPENCLAW_HOME = originalHome;
    if (originalConfigPath === undefined) delete process.env.OPENCLAW_CONFIG_PATH;
    else process.env.OPENCLAW_CONFIG_PATH = originalConfigPath;
    if (originalGatewayUrl === undefined) delete process.env.GATEWAY_URL;
    else process.env.GATEWAY_URL = originalGatewayUrl;
    await rm(tempDir, { recursive: true, force: true });
  }
});
