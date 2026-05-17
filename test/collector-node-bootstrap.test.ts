import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "collector-node", "bootstrap-collector-node.sh");

async function writeConfig(dir: string): Promise<{ configFile: string; deployDir: string }> {
  const deployDir = join(dir, "collector-node");
  const configFile = join(dir, "collector-node.json");
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
        deployDir,
        image: "openclaw-control-center:collector-node",
        buildContext: ROOT,
        collectorContainerName: "openclaw-collector-node",
        snapshotOutputPath: "/app/runtime/collectors/remote-oracle/snapshot.json",
        cronSchedule: "*/2 * * * *",
        instances: [
          {
            id: "remote-main",
            name: "Remote Main",
            gatewayUrl: "ws://host.docker.internal:18789",
            configDir: "/srv/openclaw/config",
            workspaceDir: "/srv/openclaw/workspace",
          },
        ],
      },
      null,
      2,
    )}\n`,
    "utf8",
  );
  return { configFile, deployDir };
}

test("collector node bootstrap plans without writing files", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-collector-node-bootstrap-"));
  try {
    const { configFile, deployDir } = await writeConfig(dir);
    const plan = JSON.parse(execFileSync(SCRIPT, ["plan", configFile], { encoding: "utf8" }));

    assert.equal(plan.status, "planned");
    assert.equal(plan.serverId, "remote-oracle");
    assert.equal(plan.deployDir, deployDir);
    assert.equal(plan.safety.writesFilesOnly, true);
    assert.equal(plan.safety.startsContainers, false);
    assert.equal(plan.safety.mutatesOpenClawInstance, false);
    assert.equal(plan.safety.exposesPorts, false);
    assert(plan.files.some((file: string) => file.endsWith("docker-compose.collector.yml")));

    const missingCompose = spawnSync("test", ["-e", join(deployDir, "docker-compose.collector.yml")]);
    assert.notEqual(missingCompose.status, 0);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("collector node bootstrap writes readonly deployment files only after confirmation", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-collector-node-bootstrap-"));
  try {
    const { configFile, deployDir } = await writeConfig(dir);
    const blocked = spawnSync(SCRIPT, ["write", configFile], { encoding: "utf8" });
    assert.notEqual(blocked.status, 0);
    assert.match(blocked.stderr, /CONFIRM_COLLECTOR_NODE_WRITE/);

    const written = JSON.parse(
      execFileSync(SCRIPT, ["write", configFile], {
        env: {
          ...process.env,
          CONFIRM_COLLECTOR_NODE_WRITE: "I_UNDERSTAND_THIS_ONLY_WRITES_COLLECTOR_NODE_FILES",
        },
        encoding: "utf8",
      }),
    );
    assert.equal(written.status, "written");

    const compose = await readFile(join(deployDir, "docker-compose.collector.yml"), "utf8");
    const instances = JSON.parse(await readFile(join(deployDir, "config", "instances.json"), "utf8"));
    const snapshotScript = await readFile(join(deployDir, "collector-snapshot.sh"), "utf8");
    const cronScript = await readFile(join(deployDir, "install-collector-cron.sh"), "utf8");

    assert.equal(instances.servers[0].id, "remote-oracle");
    assert.equal(instances.servers[0].collectorSnapshotPath, "/app/runtime/collectors/remote-oracle/snapshot.json");
    assert.equal(instances.servers[0].instances[0].openclawHome, "/instances/remote-main/config");
    assert.match(compose, /READONLY_MODE: "true"/);
    assert.match(compose, /UI_MODE: "false"/);
    assert.match(compose, /:ro"/);
    assert.doesNotMatch(compose, /ports:/);
    assert.doesNotMatch(compose, /privileged:\s*true/);
    assert.doesNotMatch(compose, /docker\.sock/);
    assert.match(snapshotScript, /collector-snapshot/);
    assert.match(snapshotScript, /OPENCLAW_COLLECTOR_SERVER_ID/);
    assert.match(cronScript, /OPENCLAW_COLLECTOR_NODE_CRON_BEGIN/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
