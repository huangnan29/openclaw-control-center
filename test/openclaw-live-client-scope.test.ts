import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";

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
