import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { loadRuntimeLogs } from "../src/runtime/runtime-logs";

test("loadRuntimeLogs 从 workspace runtime 日志读取最近事件", async () => {
  const root = await mkdtemp(join(tmpdir(), "openclaw-runtime-logs-"));
  const workspace = join(root, "workspace");
  const logDir = join(workspace, "runtime", "logs");

  try {
    await mkdir(logDir, { recursive: true });
    await writeFile(
      join(logDir, "control.log"),
      [
        "2026-05-17T03:00:00.000Z info first runtime line",
        "2026-05-17T03:02:00.000Z error second runtime line",
      ].join("\n"),
      "utf8",
    );

    const logs = await loadRuntimeLogs({ workspaceRoot: workspace, openclawHome: join(root, "config") });

    assert.equal(logs.status, "connected");
    assert.equal(logs.entries.length, 2);
    assert.equal(logs.entries[0]?.message, "second runtime line");
    assert.equal(logs.entries[0]?.severity, "error");
    assert(logs.entries[0]?.sourcePath.endsWith("control.log"));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("loadRuntimeLogs 支持 JSONL 日志", async () => {
  const root = await mkdtemp(join(tmpdir(), "openclaw-runtime-jsonl-"));
  const workspace = join(root, "workspace");
  const logDir = join(workspace, "logs");

  try {
    await mkdir(logDir, { recursive: true });
    await writeFile(
      join(logDir, "events.jsonl"),
      [
        JSON.stringify({ timestamp: "2026-05-17T03:01:00.000Z", level: "warn", message: "jsonl warning" }),
        JSON.stringify({ timestamp: "2026-05-17T03:03:00.000Z", level: "info", detail: "jsonl detail" }),
      ].join("\n"),
      "utf8",
    );

    const logs = await loadRuntimeLogs({ workspaceRoot: workspace });

    assert.equal(logs.status, "connected");
    assert.deepEqual(logs.entries.map((entry) => entry.message), ["jsonl detail", "jsonl warning"]);
    assert.equal(logs.entries[1]?.severity, "warn");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
