import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "tom-readonly", "heartbeat-burn-inspector.sh");

async function writeFixture(dir: string) {
  const deployDir = join(dir, "deploy");
  const configDir = join(deployDir, "config");
  const historyDir = join(deployDir, "runtime", "collectors", "tom-oracle");
  await mkdir(configDir, { recursive: true });
  await mkdir(historyDir, { recursive: true });

  const instancesFile = join(configDir, "instances.json");
  const historyFile = join(historyDir, "history.json");
  await writeFile(
    instancesFile,
    JSON.stringify(
      {
        servers: [
          {
            id: "tom-oracle",
            name: "Tom Oracle",
            collectorSnapshotPath: "/app/runtime/collectors/tom-oracle/snapshot.json",
            instances: [
              {
                id: "deepseek",
                name: "DeepSeek",
                gatewayUrl: "ws://host.docker.internal:18795",
                openclawHome: "/instances/deepseek/config",
                workspaceRoot: "/instances/deepseek/workspace",
                readonly: true,
              },
            ],
          },
        ],
      },
      null,
      2,
    ),
    "utf8",
  );

  const baseMs = Date.parse("2026-05-18T08:00:00.000Z");
  const samples = Array.from({ length: 76 }, (_, index) => {
    const minutes = index * 2;
    const heartbeatRuns = Math.floor(minutes / 30);
    const totalTokens = 84_000 + heartbeatRuns * 280;
    return {
      generatedAt: new Date(baseMs + minutes * 60 * 1000).toISOString(),
      serverId: "tom-oracle",
      totals: {
        instances: 1,
        connected: 1,
        partial: 0,
        notConnected: 0,
        sessions: 3,
        running: 0,
        blocked: 0,
        errors: 0,
        pendingApprovals: 0,
        tokensIn: totalTokens,
        tokensOut: 0,
        totalTokens,
        cost: 0,
      },
      instances: [
        {
          id: "deepseek",
          name: "DeepSeek",
          status: "connected",
          sessions: 3,
          running: 0,
          blocked: 0,
          errors: 0,
          pendingApprovals: 0,
          tokensIn: totalTokens,
          tokensOut: 0,
          totalTokens,
          cost: 0,
        },
      ],
      models: [],
    };
  });
  await writeFile(
    historyFile,
    JSON.stringify({ schemaVersion: 1, serverId: "tom-oracle", updatedAt: samples.at(-1)?.generatedAt, retentionDays: 8, samples }, null, 2),
    "utf8",
  );

  const dockerBin = join(dir, "fake-docker.sh");
  await writeFile(
    dockerBin,
    `#!/usr/bin/env bash
set -euo pipefail
path="\${@: -1}"
printf '{"status":"read","path":"%s","sizeBytes":226,"nonEmpty":true,"firstContentLine":"# Keep this file empty","updatedAt":"2026-05-08T16:03:52.000Z"}\\n' "$path"
`,
    "utf8",
  );
  await chmod(dockerBin, 0o755);
  return { deployDir, instancesFile, historyFile, dockerBin };
}

function runInspector(fixture: Awaited<ReturnType<typeof writeFixture>>, mode: "status" | "check" = "status") {
  const result = spawnSync(SCRIPT, [mode, "deepseek"], {
    env: {
      ...process.env,
      DEPLOY_DIR: fixture.deployDir,
      INSTANCES_FILE: fixture.instancesFile,
      HISTORY_FILE: fixture.historyFile,
      DOCKER_BIN: fixture.dockerBin,
      HEARTBEAT_INSPECT_SOURCE: "control-center-container",
    },
    encoding: "utf8",
  });
  return {
    exitCode: typeof result.status === "number" ? result.status : 1,
    report: JSON.parse(result.stdout),
    stderr: result.stderr,
  };
}

test("heartbeat burn inspector flags sampled periodic token growth and reads heartbeat metadata", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-heartbeat-burn-"));
  try {
    const fixture = await writeFixture(dir);
    const result = runInspector(fixture, "status");

    assert.equal(result.exitCode, 0);
    assert.equal(result.report.status, "suspicious_usage_detected");
    assert.equal(result.report.summary.suspiciousRows, 1);
    assert.equal(result.report.rows[0].instanceId, "deepseek");
    assert.equal(result.report.rows[0].status, "periodic_small_growth");
    assert.equal(Math.round(result.report.rows[0].medianDelta), 280);
    assert.equal(Math.round(result.report.rows[0].medianIntervalMinutes), 30);
    assert.equal(result.report.rows[0].heartbeat.nonEmpty, true);
    assert.equal(result.report.safety.writesOpenClawInstanceDirs, false);
    assert.equal(result.report.safety.clearsHeartbeatFiles, false);
    assert.equal(result.report.safety.callsModelApis, false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("heartbeat burn inspector check exits nonzero when suspicious rows exist", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-heartbeat-burn-check-"));
  try {
    const fixture = await writeFixture(dir);
    const result = runInspector(fixture, "check");

    assert.equal(result.exitCode, 2);
    assert.equal(result.report.status, "suspicious_usage_detected");
    assert(result.report.rows[0].nextCommands.some((command: string) => command.includes("usage_instance=deepseek")));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("heartbeat burn inspector supports metadata-free readonly mode", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-heartbeat-burn-none-"));
  try {
    const fixture = await writeFixture(dir);
    const output = execFileSync(SCRIPT, ["status", "deepseek"], {
      env: {
        ...process.env,
        DEPLOY_DIR: fixture.deployDir,
        INSTANCES_FILE: fixture.instancesFile,
        HISTORY_FILE: fixture.historyFile,
        HEARTBEAT_INSPECT_SOURCE: "none",
      },
      encoding: "utf8",
    });
    const report = JSON.parse(output);

    assert.equal(report.status, "suspicious_usage_detected");
    assert.equal(report.rows[0].heartbeat.status, "skipped");
    assert.equal(report.safety.readsHeartbeatMetadataOnly, false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
