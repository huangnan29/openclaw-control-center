import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const ONBOARDING = join(ROOT, "ops", "tom-readonly", "remote-collector-onboarding.sh");
const ROLLOUT = join(ROOT, "ops", "tom-readonly", "remote-collector-rollout.sh");
const RUNNER = join(ROOT, "ops", "tom-readonly", "remote-collector-rollout-runner.sh");
const RUNNER_CONFIRM = "I_UNDERSTAND_THIS_RUNS_SAFE_REMOTE_COLLECTOR_ROLLOUT_STEPS";

async function writeOnboardingConfig(
  dir: string,
  sshKey: string,
  configFile = join(dir, "onboarding.json"),
): Promise<{ deployDir: string; bundleDir: string; configFile: string }> {
  const deployDir = join(dir, "deploy");
  const bundleDir = join(deployDir, "runtime", "remote-onboarding", "remote-oracle");
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
          sshKey,
          knownHostsFile: join(deployDir, "runtime", "ssh", "known_hosts"),
          strictHostKeyChecking: "accept-new",
          connectTimeoutSeconds: 3,
          deployDir: "/srv/openclaw-collector-node",
        },
        outputDir: bundleDir,
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
  return { deployDir, bundleDir, configFile };
}

function writeBundle(configFile: string, deployDir: string): void {
  execFileSync(ONBOARDING, ["write", configFile], {
    env: {
      ...process.env,
      DEPLOY_DIR: deployDir,
      CONFIRM_REMOTE_COLLECTOR_ONBOARDING: "I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_ONBOARDING_BUNDLE",
    },
    encoding: "utf8",
  });
}

async function writeBaseRegistry(deployDir: string): Promise<void> {
  await mkdir(join(deployDir, "config"), { recursive: true });
  await writeFile(
    join(deployDir, "config", "instances.json"),
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
}

async function writePreflightState(deployDir: string, bundleDir: string): Promise<void> {
  const stateDir = join(deployDir, "runtime", "remote-preflight-state");
  await mkdir(stateDir, { recursive: true });
  await writeFile(
    join(stateDir, "remote-oracle.json"),
    `${JSON.stringify(
      {
        schemaVersion: 1,
        status: "ready",
        bundleDir,
        serverId: "remote-oracle",
        checkedAt: "2026-05-17T12:00:00.000Z",
        updatedAt: "2026-05-17T12:00:00.000Z",
        results: [{ id: "docker", status: "pass" }],
        safety: {
          writesRemoteFiles: false,
          startsContainers: false,
          mutatesOpenClawInstance: false,
          callsLiveApi: false,
          connectsSsh: true,
        },
      },
      null,
      2,
    )}\n`,
    "utf8",
  );
}

async function writeFakeRemoteSsh(dir: string, commandsFile: string): Promise<string> {
  const binDir = join(dir, "bin");
  await mkdir(binDir, { recursive: true });
  const ssh = join(binDir, "ssh");
  await writeFile(
    ssh,
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "${commandsFile}"
cat >/dev/null || true
case "$*" in
  *"bootstrap-collector-node.sh plan"*) printf '{"status":"planned","safety":{"startsContainers":false,"mutatesOpenClawInstance":false}}\\n' ;;
  *"bootstrap-collector-node.sh write"*) printf '{"status":"written"}\\n' ;;
  *"./collector-snapshot.sh"*) printf '{"serverId":"remote-oracle","instances":1,"generatedAt":"2026-05-17T12:05:00.000Z"}\\n' ;;
  *"./install-collector-cron.sh"*) printf '[完成] 已安装 collector-only cron：*/2 * * * *\\n' ;;
  *"cat -- "*"/snapshot.json"*) printf '{"schemaVersion":1,"serverId":"remote-oracle","generatedAt":"2026-05-17T12:05:00.000Z","instances":[{"id":"remote-main","status":"connected","snapshot":{"sessions":[],"statuses":[],"cronJobs":[],"approvals":[],"projects":{"projects":[],"updatedAt":"2026-05-17T12:05:00.000Z"},"projectSummaries":[],"tasks":{"tasks":[],"agentBudgets":[],"updatedAt":"2026-05-17T12:05:00.000Z"},"tasksSummary":{"projects":0,"tasks":0,"todo":0,"inProgress":0,"blocked":0,"done":0,"owners":0,"artifacts":0},"budgetSummary":{"total":0,"ok":0,"warn":0,"over":0,"evaluations":[]},"generatedAt":"2026-05-17T12:05:00.000Z"}}]}\\n' ;;
  *) printf 'ok\\n' ;;
esac
`,
    "utf8",
  );
  await chmod(ssh, 0o755);
  return binDir;
}

test("remote collector rollout runner status delegates to the read-only rollout gate", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-runner-"));
  try {
    const missingKey = join(dir, "deploy", "runtime", "ssh", "missing.key");
    const { deployDir, bundleDir, configFile } = await writeOnboardingConfig(dir, missingKey);
    writeBundle(configFile, deployDir);
    await writeBaseRegistry(deployDir);

    const status = JSON.parse(
      execFileSync(RUNNER, ["status", bundleDir], {
        env: { ...process.env, DEPLOY_DIR: deployDir },
        encoding: "utf8",
      }),
    );

    assert.equal(status.status, "blocked");
    assert.equal(status.stage, "needs_remote_credentials");
    assert.equal(status.safety.connectsSsh, false);
    assert.equal(status.safety.writesActiveRegistry, false);
    assert.equal(status.safety.mutatesOpenClawInstance, false);
    assert.equal(status.safety.callsLiveApi, false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("remote collector rollout runner refuses step mode without explicit confirmation", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-runner-"));
  try {
    const missingKey = join(dir, "deploy", "runtime", "ssh", "missing.key");
    const { deployDir, bundleDir, configFile } = await writeOnboardingConfig(dir, missingKey);
    writeBundle(configFile, deployDir);

    const result = spawnSync(RUNNER, ["step", bundleDir], {
      env: { ...process.env, DEPLOY_DIR: deployDir },
      encoding: "utf8",
    });

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /CONFIRM_REMOTE_COLLECTOR_ROLLOUT_RUNNER/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("remote collector rollout runner refreshes onboarding bundle and advances to preflight", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-runner-"));
  try {
    const deployDir = join(dir, "deploy");
    const missingKey = join(deployDir, "runtime", "ssh", "missing.key");
    const correctKey = join(deployDir, "runtime", "ssh", "remote-oracle-readonly.key");
    const initial = await writeOnboardingConfig(dir, missingKey, join(dir, "initial-onboarding.json"));
    writeBundle(initial.configFile, deployDir);
    await writeBaseRegistry(deployDir);

    await mkdir(join(deployDir, "runtime", "ssh"), { recursive: true });
    await writeFile(correctKey, "fake readonly key\n", "utf8");
    const runtimeConfig = join(deployDir, "runtime", "remote-collector-onboarding.json");
    await writeOnboardingConfig(dir, correctKey, runtimeConfig);

    const before = JSON.parse(
      execFileSync(ROLLOUT, ["status", initial.bundleDir], {
        env: { ...process.env, DEPLOY_DIR: deployDir },
        encoding: "utf8",
      }),
    );
    assert.equal(before.stage, "needs_remote_credentials");

    execFileSync(RUNNER, ["step", initial.bundleDir], {
      env: {
        ...process.env,
        DEPLOY_DIR: deployDir,
        CONFIRM_REMOTE_COLLECTOR_ROLLOUT_RUNNER: RUNNER_CONFIRM,
      },
      encoding: "utf8",
    });

    const after = JSON.parse(
      execFileSync(ROLLOUT, ["status", initial.bundleDir], {
        env: { ...process.env, DEPLOY_DIR: deployDir },
        encoding: "utf8",
      }),
    );
    assert.equal(after.stage, "needs_remote_preflight");
    assert.equal(after.evidence.remoteAccess.status, "ready");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("remote collector rollout runner prepares remote collector node before pulling snapshot", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-runner-"));
  try {
    const deployDir = join(dir, "deploy");
    const sshKey = join(deployDir, "runtime", "ssh", "remote-oracle-readonly.key");
    await mkdir(join(deployDir, "runtime", "ssh"), { recursive: true });
    await writeFile(sshKey, "fake readonly key\n", "utf8");
    const { bundleDir, configFile } = await writeOnboardingConfig(dir, sshKey);
    writeBundle(configFile, deployDir);
    await writeBaseRegistry(deployDir);
    await writePreflightState(deployDir, bundleDir);

    const before = JSON.parse(
      execFileSync(ROLLOUT, ["status", bundleDir], {
        env: { ...process.env, DEPLOY_DIR: deployDir },
        encoding: "utf8",
      }),
    );
    assert.equal(before.stage, "needs_remote_collector_pull");

    const commandsFile = join(dir, "ssh-commands.txt");
    const fakeBin = await writeFakeRemoteSsh(dir, commandsFile);
    execFileSync(RUNNER, ["step", bundleDir], {
      env: {
        ...process.env,
        DEPLOY_DIR: deployDir,
        PATH: `${fakeBin}:${process.env.PATH || ""}`,
        CONFIRM_REMOTE_COLLECTOR_ROLLOUT_RUNNER: RUNNER_CONFIRM,
      },
      encoding: "utf8",
      maxBuffer: 20 * 1024 * 1024,
    });

    const after = JSON.parse(
      execFileSync(ROLLOUT, ["status", bundleDir], {
        env: { ...process.env, DEPLOY_DIR: deployDir },
        encoding: "utf8",
      }),
    );
    assert.equal(after.stage, "needs_registry_register");
    assert.equal(after.evidence.pull.status, "pulled");
    assert.equal(after.evidence.snapshot.status, "valid");

    const commands = await readFile(commandsFile, "utf8");
    assert.match(commands, /tar -C '\\''\/srv\/openclaw-collector-node'\\'' -xf -/);
    assert.match(commands, /bootstrap-collector-node\.sh plan collector-node\.json/);
    assert.match(commands, /bootstrap-collector-node\.sh write collector-node\.json/);
    assert.match(commands, /\.\/collector-snapshot\.sh/);
    assert.match(commands, /\.\/install-collector-cron\.sh/);
    assert.match(commands, /cat -- '\/srv\/openclaw-collector-node\/runtime\/collectors\/remote-oracle\/snapshot\.json'/);
    assert.doesNotMatch(commands, /api\/managed-actions\/live/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
