import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "tom-readonly", "remote-collector-credentials.sh");

async function writeConfig(dir: string, overwrite = false): Promise<{ configFile: string; deployDir: string; sourceKey: string }> {
  const deployDir = join(dir, "deploy");
  const sourceKey = join(dir, "remote-oracle-readonly.key");
  const configFile = join(dir, "credentials.json");
  await writeFile(sourceKey, "fake readonly private key\n", "utf8");
  await chmod(sourceKey, 0o600);
  await writeFile(
    configFile,
    `${JSON.stringify(
      {
        schemaVersion: 1,
        server: {
          id: "remote-oracle",
          name: "Remote Oracle",
          host: "203.0.113.10",
          region: "oracle-us",
          description: "第二台 Oracle 只读 collector 节点",
        },
        remote: {
          host: "203.0.113.10",
          user: "ubuntu",
          port: 2222,
          sourceSshKeyPath: sourceKey,
          targetSshKeyPath: join(deployDir, "runtime", "ssh", "remote-oracle-readonly.key"),
          knownHostsFile: join(deployDir, "runtime", "ssh", "known_hosts"),
          strictHostKeyChecking: "accept-new",
          connectTimeoutSeconds: 3,
          deployDir: "/srv/openclaw-collector-node",
        },
        collectorNode: {
          image: "openclaw-control-center:collector-node",
          bundleBuildContext: true,
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
        outputConfigFile: join(deployDir, "runtime", "remote-collector-onboarding.json"),
        overwrite,
      },
      null,
      2,
    )}\n`,
    "utf8",
  );
  return { configFile, deployDir, sourceKey };
}

test("remote collector credentials plan validates without writing runtime files", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-credentials-"));
  try {
    const { configFile, deployDir } = await writeConfig(dir);
    const plan = JSON.parse(
      execFileSync(SCRIPT, ["plan", configFile], {
        env: { ...process.env, DEPLOY_DIR: deployDir },
        encoding: "utf8",
      }),
    );

    assert.equal(plan.status, "planned");
    assert.equal(plan.serverId, "remote-oracle");
    assert.equal(plan.sourceKeyExists, true);
    assert.equal(plan.targetKeyExists, false);
    assert.equal(plan.onboardingConfigExists, false);
    assert.equal(plan.safety.writesControlCenterRuntimeOnly, false);
    assert.equal(plan.safety.connectsSsh, false);
    assert.equal(plan.safety.writesRemoteFiles, false);
    assert.equal(plan.safety.writesActiveRegistry, false);
    assert.equal(plan.safety.mutatesOpenClawInstance, false);
    assert.equal(existsSync(join(deployDir, "runtime", "ssh", "remote-oracle-readonly.key")), false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("remote collector credentials apply writes key and onboarding config after confirmation", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-credentials-"));
  try {
    const { configFile, deployDir } = await writeConfig(dir);
    const env = { ...process.env, DEPLOY_DIR: deployDir };
    const blocked = spawnSync(SCRIPT, ["apply", configFile], { env, encoding: "utf8" });
    assert.notEqual(blocked.status, 0);
    assert.match(blocked.stderr, /CONFIRM_REMOTE_COLLECTOR_CREDENTIALS/);

    const applied = JSON.parse(
      execFileSync(SCRIPT, ["apply", configFile], {
        env: {
          ...env,
          CONFIRM_REMOTE_COLLECTOR_CREDENTIALS: "I_UNDERSTAND_THIS_ONLY_WRITES_CONTROL_CENTER_REMOTE_CREDENTIALS",
        },
        encoding: "utf8",
      }),
    );

    assert.equal(applied.status, "applied");
    assert.equal(applied.safety.writesControlCenterRuntimeOnly, true);
    assert.equal(applied.safety.connectsSsh, false);
    assert.equal(applied.safety.writesRemoteFiles, false);
    assert.equal(applied.safety.mutatesOpenClawInstance, false);

    const keyPath = join(deployDir, "runtime", "ssh", "remote-oracle-readonly.key");
    const onboardingPath = join(deployDir, "runtime", "remote-collector-onboarding.json");
    const key = await readFile(keyPath, "utf8");
    const keyMode = (await stat(keyPath)).mode & 0o777;
    const onboarding = JSON.parse(await readFile(onboardingPath, "utf8"));

    assert.equal(key, "fake readonly private key\n");
    assert.equal(keyMode, 0o600);
    assert.equal(onboarding.schemaVersion, 1);
    assert.equal(onboarding.remote.host, "203.0.113.10");
    assert.equal(onboarding.remote.user, "ubuntu");
    assert.equal(onboarding.remote.port, 2222);
    assert.equal(onboarding.remote.sshKey, keyPath);
    assert.equal(onboarding.remote.knownHostsFile, join(deployDir, "runtime", "ssh", "known_hosts"));
    assert.equal(onboarding.collectorNode.bundleBuildContext, true);
    assert.equal(onboarding.instances[0]?.id, "remote-main");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("remote collector credentials refuses to overwrite without opt-in", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-credentials-"));
  try {
    const { configFile, deployDir } = await writeConfig(dir);
    const env = {
      ...process.env,
      DEPLOY_DIR: deployDir,
      CONFIRM_REMOTE_COLLECTOR_CREDENTIALS: "I_UNDERSTAND_THIS_ONLY_WRITES_CONTROL_CENTER_REMOTE_CREDENTIALS",
    };
    execFileSync(SCRIPT, ["apply", configFile], { env, encoding: "utf8" });
    const second = spawnSync(SCRIPT, ["apply", configFile], { env, encoding: "utf8" });
    assert.notEqual(second.status, 0);
    assert.match(second.stderr, /已存在/);

    const { configFile: overwriteConfig } = await writeConfig(dir, true);
    const overwritten = JSON.parse(execFileSync(SCRIPT, ["apply", overwriteConfig], { env, encoding: "utf8" }));
    assert.equal(overwritten.status, "applied");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("remote collector credentials rejects output outside runtime", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-credentials-"));
  try {
    const { configFile, deployDir } = await writeConfig(dir);
    const raw = JSON.parse(await readFile(configFile, "utf8"));
    raw.remote.targetSshKeyPath = join(dir, "outside.key");
    await writeFile(configFile, `${JSON.stringify(raw, null, 2)}\n`, "utf8");

    const result = spawnSync(SCRIPT, ["plan", configFile], {
      env: { ...process.env, DEPLOY_DIR: deployDir },
      encoding: "utf8",
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /runtime/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
