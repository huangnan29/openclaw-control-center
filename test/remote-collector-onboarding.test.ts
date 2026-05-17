import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "tom-readonly", "remote-collector-onboarding.sh");

async function writeConfig(dir: string): Promise<{ configFile: string; deployDir: string; outputDir: string }> {
  const deployDir = join(dir, "deploy");
  const outputDir = join(deployDir, "runtime", "remote-onboarding", "remote-oracle");
  const configFile = join(dir, "onboarding.json");
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
        remote: {
          host: "10.0.0.12",
          user: "ubuntu",
          port: 2222,
          sshKey: join(deployDir, "runtime", "ssh", "remote-oracle-readonly.key"),
          knownHostsFile: join(deployDir, "runtime", "ssh", "known_hosts"),
          strictHostKeyChecking: "accept-new",
          connectTimeoutSeconds: 3,
          deployDir: "/srv/openclaw-collector-node",
        },
        outputDir,
        collectorNode: {
          image: "openclaw-control-center:collector-node",
          buildContext: ROOT,
          collectorContainerName: "openclaw-collector-remote-oracle",
          cronSchedule: "*/2 * * * *",
        },
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
  return { configFile, deployDir, outputDir };
}

test("remote collector onboarding plans without writing bundle files", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-onboarding-"));
  try {
    const { configFile, deployDir, outputDir } = await writeConfig(dir);
    const plan = JSON.parse(
      execFileSync(SCRIPT, ["plan", configFile], {
        env: { ...process.env, DEPLOY_DIR: deployDir },
        encoding: "utf8",
      }),
    );

    assert.equal(plan.status, "planned");
    assert.equal(plan.serverId, "remote-oracle");
    assert.equal(plan.outputDir, outputDir);
    assert.equal(plan.safety.writesOnboardingBundleOnly, true);
    assert.equal(plan.safety.writesActiveRegistry, false);
    assert.equal(plan.safety.connectsSsh, false);
    assert.equal(plan.safety.mutatesOpenClawInstance, false);
    assert.equal(plan.safety.callsLiveApi, false);
    assert(plan.files.some((file: string) => file.endsWith("collector-node.json")));
    assert.equal(existsSync(join(outputDir, "collector-node.json")), false);
    assert.equal(existsSync(join(deployDir, "config", "instances.json")), false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("remote collector onboarding writes a reviewable bundle only after confirmation", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-onboarding-"));
  try {
    const { configFile, deployDir, outputDir } = await writeConfig(dir);
    const env = { ...process.env, DEPLOY_DIR: deployDir };
    const blocked = spawnSync(SCRIPT, ["write", configFile], { env, encoding: "utf8" });
    assert.notEqual(blocked.status, 0);
    assert.match(blocked.stderr, /CONFIRM_REMOTE_COLLECTOR_ONBOARDING/);

    const written = JSON.parse(
      execFileSync(SCRIPT, ["write", configFile], {
        env: {
          ...env,
          CONFIRM_REMOTE_COLLECTOR_ONBOARDING: "I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_ONBOARDING_BUNDLE",
        },
        encoding: "utf8",
      }),
    );
    assert.equal(written.status, "written");
    assert.equal(written.outputDir, outputDir);

    const collectorNode = JSON.parse(await readFile(join(outputDir, "collector-node.json"), "utf8"));
    const pullConfig = JSON.parse(await readFile(join(outputDir, "remote-collector-pull.sources.json"), "utf8"));
    const registerConfig = JSON.parse(await readFile(join(outputDir, "register-remote-collector.json"), "utf8"));
    const runbook = await readFile(join(outputDir, "RUNBOOK.md"), "utf8");
    const safety = JSON.parse(await readFile(join(outputDir, "safety.json"), "utf8"));
    const bootstrapMode = (await stat(join(outputDir, "bootstrap-collector-node.sh"))).mode;

    assert.equal(collectorNode.server.id, "remote-oracle");
    assert.equal(collectorNode.deployDir, "/srv/openclaw-collector-node");
    assert.equal(collectorNode.instances[0]?.configDir, "/srv/openclaw/config");
    assert.equal(pullConfig.sources[0]?.enabled, true);
    assert.equal(pullConfig.sources[0]?.remoteSnapshotPath, "/srv/openclaw-collector-node/runtime/collectors/remote-oracle/snapshot.json");
    assert.equal(pullConfig.sources[0]?.localSnapshotPath, join(deployDir, "runtime", "collectors", "remote-oracle", "snapshot.json"));
    assert.equal(registerConfig.collectorSnapshotPath, "/app/runtime/collectors/remote-oracle/snapshot.json");
    assert.deepEqual(registerConfig.instances, [{ id: "remote-main", name: "Remote Main" }]);
    assert.match(runbook, /remote-collector-pull\.sh plan/);
    assert.match(runbook, /register-remote-collector\.sh apply/);
    assert.doesNotMatch(runbook, /api\/managed-actions\/live/);
    assert.equal(safety.writesActiveRegistry, false);
    assert.equal(safety.connectsSsh, false);
    assert.equal(safety.mutatesOpenClawInstance, false);
    assert.notEqual(bootstrapMode & 0o111, 0);
    assert.equal(existsSync(join(deployDir, "config", "instances.json")), false);

    const generatedPlan = JSON.parse(
      execFileSync(join(outputDir, "bootstrap-collector-node.sh"), ["plan", join(outputDir, "collector-node.json")], {
        encoding: "utf8",
      }),
    );
    assert.equal(generatedPlan.status, "planned");
    assert.equal(generatedPlan.safety.startsContainers, false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("remote collector onboarding bundles a build context when no remote buildContext is provided", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-onboarding-"));
  try {
    const { configFile, deployDir, outputDir } = await writeConfig(dir);
    const raw = JSON.parse(await readFile(configFile, "utf8"));
    delete raw.collectorNode.buildContext;
    await writeFile(configFile, `${JSON.stringify(raw, null, 2)}\n`, "utf8");

    const plan = JSON.parse(
      execFileSync(SCRIPT, ["plan", configFile], {
        env: { ...process.env, DEPLOY_DIR: deployDir },
        encoding: "utf8",
      }),
    );
    assert.equal(plan.bundlesBuildContext, true);
    assert.equal(plan.remoteBuildContext, "/srv/openclaw-collector-node/build-context");
    assert.equal(plan.warnings.length, 0);
    assert(plan.buildContextFiles > 10);
    assert(plan.files.includes(join(outputDir, "build-context")));

    execFileSync(SCRIPT, ["write", configFile], {
      env: {
        ...process.env,
        DEPLOY_DIR: deployDir,
        CONFIRM_REMOTE_COLLECTOR_ONBOARDING: "I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_ONBOARDING_BUNDLE",
      },
      encoding: "utf8",
    });

    const collectorNode = JSON.parse(await readFile(join(outputDir, "collector-node.json"), "utf8"));
    const manifest = JSON.parse(await readFile(join(outputDir, "build-context-manifest.json"), "utf8"));
    const safety = JSON.parse(await readFile(join(outputDir, "safety.json"), "utf8"));
    const runbook = await readFile(join(outputDir, "RUNBOOK.md"), "utf8");

    assert.equal(collectorNode.buildContext, "/srv/openclaw-collector-node/build-context");
    assert.equal(existsSync(join(outputDir, "build-context", "Dockerfile")), true);
    assert.equal(existsSync(join(outputDir, "build-context", "package.json")), true);
    assert.equal(existsSync(join(outputDir, "build-context", "src", "index.ts")), true);
    assert(manifest.files.includes("Dockerfile"));
    assert(manifest.files.includes("package-lock.json"));
    assert.equal(manifest.remoteBuildContext, "/srv/openclaw-collector-node/build-context");
    assert.equal(safety.bundlesBuildContext, true);
    assert.equal(safety.remoteBuildContext, "/srv/openclaw-collector-node/build-context");
    assert.match(runbook, /scp' '-r'/);
    assert.match(runbook, /cp -a \/tmp\/build-context/);
    assert.doesNotMatch(runbook, /api\/managed-actions\/live/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("remote collector onboarding refuses output outside the control-center onboarding directory", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-onboarding-"));
  try {
    const { configFile, deployDir } = await writeConfig(dir);
    const raw = JSON.parse(await readFile(configFile, "utf8"));
    raw.outputDir = join(dir, "outside");
    await writeFile(configFile, `${JSON.stringify(raw, null, 2)}\n`, "utf8");

    const result = spawnSync(SCRIPT, ["plan", configFile], {
      env: { ...process.env, DEPLOY_DIR: deployDir },
      encoding: "utf8",
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /outputDir 必须位于/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
