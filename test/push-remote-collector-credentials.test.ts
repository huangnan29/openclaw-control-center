import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "local", "push-remote-collector-credentials.sh");

async function writeConfig(dir: string, options: { overwrite?: boolean } = {}) {
  const deployDir = "/srv/openclaw-control-center-readonly";
  const sourceKey = join(dir, "remote-oracle-readonly.key");
  const tomKey = join(dir, "tom.key");
  const configFile = join(dir, "push-credentials.json");
  await writeFile(sourceKey, "fake remote readonly key\n", "utf8");
  await writeFile(tomKey, "fake tom key\n", "utf8");
  await chmod(sourceKey, 0o600);
  await chmod(tomKey, 0o600);
  await writeFile(
    configFile,
    `${JSON.stringify(
      {
        schemaVersion: 1,
        tom: {
          host: "146.235.226.66",
          user: "ubuntu",
          port: 2222,
          sshKey: tomKey,
          deployDir,
          strictHostKeyChecking: "accept-new",
          connectTimeoutSeconds: 3,
        },
        server: {
          id: "remote-oracle",
          name: "Remote Oracle",
          host: "203.0.113.10",
          region: "oracle-us",
        },
        remote: {
          host: "203.0.113.10",
          user: "ubuntu",
          port: 2200,
          sourceSshKeyPath: sourceKey,
          targetSshKeyPath: `${deployDir}/runtime/ssh/remote-oracle-readonly.key`,
          knownHostsFile: `${deployDir}/runtime/ssh/known_hosts`,
          strictHostKeyChecking: "accept-new",
          connectTimeoutSeconds: 5,
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
        outputConfigFile: `${deployDir}/runtime/remote-collector-onboarding.json`,
        overwrite: options.overwrite ?? false,
      },
      null,
      2,
    )}\n`,
    "utf8",
  );
  return { configFile, sourceKey, tomKey, deployDir };
}

async function writeFakeSsh(dir: string) {
  const fakeBin = join(dir, "bin");
  const payloadFile = join(dir, "ssh-payload.json");
  const argsFile = join(dir, "ssh-args.txt");
  await mkdir(fakeBin, { recursive: true });
  const fakeSsh = join(fakeBin, "ssh");
  await writeFile(
    fakeSsh,
    `#!/usr/bin/env bash
printf '%s\\n' "$*" > "$FAKE_SSH_ARGS"
cat > "$FAKE_SSH_PAYLOAD"
node - "$FAKE_SSH_PAYLOAD" <<'NODE_FAKE'
const fs = require('node:fs');
const payload = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
process.stdout.write(JSON.stringify({
  status: 'applied',
  written: {
    keyFile: payload.targetSshKeyPath,
    onboardingConfigFile: payload.outputConfigFile
  },
  safety: {
    writesControlCenterRuntimeOnly: true,
    connectsSecondOracle: false,
    writesRemoteFiles: false,
    writesActiveRegistry: false,
    mutatesOpenClawInstance: false,
    callsLiveApi: false
  }
}, null, 2));
NODE_FAKE
`,
    "utf8",
  );
  await chmod(fakeSsh, 0o755);
  return { fakeBin, payloadFile, argsFile };
}

test("push remote collector credentials plans locally without ssh", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-push-remote-credentials-"));
  try {
    const { configFile } = await writeConfig(dir);
    const { fakeBin, payloadFile } = await writeFakeSsh(dir);
    const plan = JSON.parse(
      execFileSync(SCRIPT, ["plan", configFile], {
        env: { ...process.env, PATH: `${fakeBin}${delimiter}${process.env.PATH ?? ""}` },
        encoding: "utf8",
      }),
    );

    assert.equal(plan.status, "planned");
    assert.equal(plan.serverId, "remote-oracle");
    assert.equal(plan.sourceKeyExists, true);
    assert.equal(plan.tomKeyExists, true);
    assert.equal(plan.safety.writesTomControlCenterRuntimeOnly, false);
    assert.equal(plan.safety.connectsTomSsh, false);
    assert.equal(plan.safety.connectsSecondOracle, false);
    assert.equal(plan.safety.writesActiveRegistry, false);
    assert.equal(existsSync(payloadFile), false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("push remote collector credentials applies only after confirmation", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-push-remote-credentials-"));
  try {
    const { configFile, deployDir } = await writeConfig(dir);
    const { fakeBin, payloadFile, argsFile } = await writeFakeSsh(dir);
    const env = {
      ...process.env,
      PATH: `${fakeBin}${delimiter}${process.env.PATH ?? ""}`,
      FAKE_SSH_PAYLOAD: payloadFile,
      FAKE_SSH_ARGS: argsFile,
    };

    const blocked = spawnSync(SCRIPT, ["apply", configFile], { env, encoding: "utf8" });
    assert.notEqual(blocked.status, 0);
    assert.match(blocked.stderr, /CONFIRM_PUSH_REMOTE_COLLECTOR_CREDENTIALS/);

    const applied = JSON.parse(
      execFileSync(SCRIPT, ["apply", configFile], {
        env: {
          ...env,
          CONFIRM_PUSH_REMOTE_COLLECTOR_CREDENTIALS: "I_UNDERSTAND_THIS_ONLY_PUSHES_REMOTE_COLLECTOR_CREDENTIALS_TO_TOM_RUNTIME",
        },
        encoding: "utf8",
      }),
    );

    assert.equal(applied.status, "applied");
    assert.equal(applied.safety.writesTomControlCenterRuntimeOnly, true);
    assert.equal(applied.safety.connectsTomSsh, true);
    assert.equal(applied.safety.connectsSecondOracle, false);
    assert.equal(applied.safety.writesActiveRegistry, false);
    assert.equal(applied.remoteResult.safety.writesControlCenterRuntimeOnly, true);

    const payload = JSON.parse(await readFile(payloadFile, "utf8"));
    assert.equal(payload.tomDeployDir, deployDir);
    assert.equal(payload.targetSshKeyPath, `${deployDir}/runtime/ssh/remote-oracle-readonly.key`);
    assert.equal(payload.outputConfigFile, `${deployDir}/runtime/remote-collector-onboarding.json`);
    assert.equal(payload.keyText, "fake remote readonly key\n");
    assert.equal(payload.onboardingConfig.remote.host, "203.0.113.10");
    assert.equal(payload.onboardingConfig.remote.sshKey, `${deployDir}/runtime/ssh/remote-oracle-readonly.key`);
    assert.equal(payload.onboardingConfig.instances[0]?.id, "remote-main");

    const args = await readFile(argsFile, "utf8");
    assert.match(args, /ubuntu@146\.235\.226\.66/);
    assert.doesNotMatch(args, /203\.0\.113\.10/);
    assert.doesNotMatch(args, /fake remote readonly key/);
    assert.doesNotMatch(args, /api\/managed-actions\/live/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("push remote collector credentials rejects Tom output outside runtime", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-push-remote-credentials-"));
  try {
    const { configFile } = await writeConfig(dir);
    const raw = JSON.parse(await readFile(configFile, "utf8"));
    raw.remote.targetSshKeyPath = "/srv/openclaw-control-center-readonly/config/bad.key";
    await writeFile(configFile, `${JSON.stringify(raw, null, 2)}\n`, "utf8");

    const result = spawnSync(SCRIPT, ["plan", configFile], { encoding: "utf8" });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /runtime/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
