import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "tom-readonly", "register-remote-collector.sh");

function snapshotJson(serverId = "remote-oracle"): string {
  const generatedAt = "2026-05-17T09:30:00.000Z";
  return `${JSON.stringify(
    {
      schemaVersion: 1,
      serverId,
      generatedAt,
      instances: [
        {
          id: "remote-main",
          status: "connected",
          detail: "collector ok",
          snapshot: {
            sessions: [],
            statuses: [],
            cronJobs: [],
            approvals: [],
            projects: { projects: [], updatedAt: generatedAt },
            projectSummaries: [],
            tasks: { tasks: [], agentBudgets: [], updatedAt: generatedAt },
            tasksSummary: {
              projects: 0,
              tasks: 0,
              todo: 0,
              inProgress: 0,
              blocked: 0,
              done: 0,
              owners: 0,
              artifacts: 0,
            },
            budgetSummary: { total: 0, ok: 0, warn: 0, over: 0, evaluations: [] },
            generatedAt,
          },
        },
      ],
    },
    null,
    2,
  )}\n`;
}

async function writeFixture(dir: string, snapshotServerId = "remote-oracle") {
  const deployDir = join(dir, "deploy");
  const registryFile = join(deployDir, "config", "instances.json");
  const snapshotFile = join(deployDir, "runtime", "collectors", "remote-oracle", "snapshot.json");
  const configFile = join(dir, "register.json");

  await mkdir(join(deployDir, "config"), { recursive: true });
  await mkdir(join(deployDir, "runtime", "collectors", "remote-oracle"), { recursive: true });
  await writeFile(
    registryFile,
    `${JSON.stringify(
      {
        servers: [
          {
            id: "tom-oracle",
            name: "Tom Oracle",
            collectorSnapshotPath: "/app/runtime/collectors/tom-oracle/snapshot.json",
            instances: [{ id: "main", name: "Main" }],
          },
        ],
      },
      null,
      2,
    )}\n`,
    "utf8",
  );

  await writeFile(snapshotFile, snapshotJson(snapshotServerId), "utf8");
  await writeFile(
    configFile,
    `${JSON.stringify(
      {
        schemaVersion: 1,
        server: {
          id: "remote-oracle",
          name: "Remote Oracle",
          host: "10.0.0.12",
          region: "oracle-us",
        },
        collectorSnapshotPath: "/app/runtime/collectors/remote-oracle/snapshot.json",
        instances: [{ id: "remote-main", name: "Remote Main" }],
      },
      null,
      2,
    )}\n`,
    "utf8",
  );

  return { deployDir, registryFile, configFile };
}

test("register remote collector plans and applies a collector-only server", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-register-remote-collector-"));
  try {
    const { deployDir, registryFile, configFile } = await writeFixture(dir);
    const env = { ...process.env, DEPLOY_DIR: deployDir, REGISTRY_FILE: registryFile };
    const before = await readFile(registryFile, "utf8");

    const plan = JSON.parse(execFileSync(SCRIPT, ["plan", configFile], { env, encoding: "utf8" }));
    assert.equal(plan.status, "planned");
    assert.equal(plan.action, "add");
    assert.equal(plan.serverId, "remote-oracle");
    assert.equal(plan.safety.updatesControlCenterRegistryOnly, true);
    assert.equal(plan.safety.mutatesOpenClawInstance, false);
    assert.equal(await readFile(registryFile, "utf8"), before);

    const blocked = spawnSync(SCRIPT, ["apply", configFile], { env, encoding: "utf8" });
    assert.notEqual(blocked.status, 0);
    assert.match(blocked.stderr, /CONFIRM_REMOTE_COLLECTOR_REGISTER/);

    const applied = JSON.parse(
      execFileSync(SCRIPT, ["apply", configFile], {
        env: {
          ...env,
          CONFIRM_REMOTE_COLLECTOR_REGISTER: "I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_REGISTRY",
        },
        encoding: "utf8",
      }),
    );
    assert.equal(applied.status, "applied");
    assert(existsSync(applied.backupFile));

    const registry = JSON.parse(await readFile(registryFile, "utf8"));
    assert.equal(registry.servers.length, 2);
    const remote = registry.servers.find((server: { id: string }) => server.id === "remote-oracle");
    assert.equal(remote.collectorSnapshotPath, "/app/runtime/collectors/remote-oracle/snapshot.json");
    assert.deepEqual(remote.instances, [{ id: "remote-main", name: "Remote Main" }]);
    assert.equal(remote.instances[0].openclawHome, undefined);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("register remote collector rejects mismatched snapshot server ids", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-register-remote-collector-"));
  try {
    const { deployDir, registryFile, configFile } = await writeFixture(dir, "other-oracle");
    const result = spawnSync(SCRIPT, ["plan", configFile], {
      env: { ...process.env, DEPLOY_DIR: deployDir, REGISTRY_FILE: registryFile },
      encoding: "utf8",
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /serverId 不匹配/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
