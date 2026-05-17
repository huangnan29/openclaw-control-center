import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const ONBOARDING = join(ROOT, "ops", "tom-readonly", "remote-collector-onboarding.sh");
const ROLLOUT = join(ROOT, "ops", "tom-readonly", "remote-collector-rollout.sh");

async function writeOnboardingConfig(dir: string): Promise<{ deployDir: string; bundleDir: string; configFile: string }> {
  const deployDir = join(dir, "deploy");
  const bundleDir = join(deployDir, "runtime", "remote-onboarding", "remote-oracle");
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
  execFileSync(ONBOARDING, ["write", configFile], {
    env: {
      ...process.env,
      DEPLOY_DIR: deployDir,
      CONFIRM_REMOTE_COLLECTOR_ONBOARDING: "I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_ONBOARDING_BUNDLE",
    },
    encoding: "utf8",
  });
  return { deployDir, bundleDir, configFile };
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

async function writeRemoteSshKey(deployDir: string): Promise<void> {
  await mkdir(join(deployDir, "runtime", "ssh"), { recursive: true });
  await writeFile(join(deployDir, "runtime", "ssh", "remote-oracle-readonly.key"), "fake readonly key\n", "utf8");
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
        checkedAt: "2026-05-17T08:10:00.000Z",
        updatedAt: "2026-05-17T08:10:00.000Z",
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

async function writeSnapshotAndPullState(deployDir: string): Promise<void> {
  const generatedAt = "2026-05-17T08:20:00.000Z";
  const snapshotPath = join(deployDir, "runtime", "collectors", "remote-oracle", "snapshot.json");
  await mkdir(join(deployDir, "runtime", "collectors", "remote-oracle"), { recursive: true });
  await mkdir(join(deployDir, "runtime", "collector-pull-state"), { recursive: true });
  await writeFile(
    snapshotPath,
    `${JSON.stringify(
      {
        schemaVersion: 1,
        serverId: "remote-oracle",
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
    )}\n`,
    "utf8",
  );
  await writeFile(
    join(deployDir, "runtime", "collector-pull-state", "remote-oracle.json"),
    `${JSON.stringify(
      {
        schemaVersion: 1,
        serverId: "remote-oracle",
        status: "pulled",
        updatedAt: "2026-05-17T08:21:00.000Z",
        pulledAt: "2026-05-17T08:21:00.000Z",
        generatedAt,
        instances: 1,
        source: {
          host: "10.0.0.12",
          user: "ubuntu",
          port: 2222,
          remoteSnapshotPath: "/srv/openclaw-collector-node/runtime/collectors/remote-oracle/snapshot.json",
          localSnapshotPath: snapshotPath,
        },
      },
      null,
      2,
    )}\n`,
    "utf8",
  );
}

async function writeRegisteredRegistry(deployDir: string): Promise<void> {
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
          {
            id: "remote-oracle",
            name: "Remote Oracle",
            collectorSnapshotPath: "/app/runtime/collectors/remote-oracle/snapshot.json",
            instances: [{ id: "remote-main", name: "Remote Main" }],
          },
        ],
      },
      null,
      2,
    )}\n`,
    "utf8",
  );
}

test("remote collector rollout gate reports the next safe stage", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-rollout-"));
  try {
    const { deployDir, bundleDir } = await writeOnboardingConfig(dir);
    await writeBaseRegistry(deployDir);
    const env = { ...process.env, DEPLOY_DIR: deployDir };

    const needsCredentials = JSON.parse(execFileSync(ROLLOUT, ["status", bundleDir], { env, encoding: "utf8" }));
    assert.equal(needsCredentials.status, "blocked");
    assert.equal(needsCredentials.stage, "needs_remote_credentials");
    assert.equal(needsCredentials.evidence.remoteAccess.status, "blocked");
    assert(needsCredentials.evidence.remoteAccess.issues.some((issue: string) => issue.includes("SSH key")));
    assert(needsCredentials.nextCommands.some((command: string) => command.includes("remote-oracle-intake.sh run")));
    assert(needsCredentials.nextCommands.some((command: string) => command.includes("write-push-config")));
    assert(needsCredentials.nextCommands.some((command: string) => command.includes("push-remote-collector-credentials.sh apply")));
    assert(needsCredentials.nextCommands.some((command: string) => command.includes("remote-collector-credentials.sh apply")));
    assert(needsCredentials.nextCommands.some((command: string) => command.includes("remote-collector-onboarding.sh write")));

    await writeRemoteSshKey(deployDir);
    const needsPreflight = JSON.parse(execFileSync(ROLLOUT, ["status", bundleDir], { env, encoding: "utf8" }));
    assert.equal(needsPreflight.status, "blocked");
    assert.equal(needsPreflight.stage, "needs_remote_preflight");
    assert.equal(needsPreflight.evidence.remoteAccess.status, "ready");
    assert.equal(needsPreflight.safety.connectsSsh, false);
    assert.equal(needsPreflight.safety.writesActiveRegistry, false);
    assert.equal(needsPreflight.safety.mutatesOpenClawInstance, false);
    assert(needsPreflight.nextCommands.some((command: string) => command.includes("remote-collector-preflight.sh check")));

    await writePreflightState(deployDir, bundleDir);
    const needsPull = JSON.parse(execFileSync(ROLLOUT, ["plan", bundleDir], { env, encoding: "utf8" }));
    assert.equal(needsPull.stage, "needs_remote_collector_pull");
    assert.equal(needsPull.evidence.preflight.status, "ready");
    assert(needsPull.nextCommands.some((command: string) => command.includes("remote-collector-node-sync.sh sync")));
    assert(needsPull.nextCommands.some((command: string) => command.includes("remote-collector-node-sync.sh bootstrap-write")));
    assert(needsPull.nextCommands.some((command: string) => command.includes("remote-collector-node-sync.sh snapshot")));
    assert(needsPull.nextCommands.some((command: string) => command.includes("remote-collector-node-sync.sh install-cron")));
    assert(needsPull.nextCommands.some((command: string) => command.includes("remote-collector-pull.sh pull")));

    await writeSnapshotAndPullState(deployDir);
    const needsRegister = JSON.parse(execFileSync(ROLLOUT, ["status", bundleDir], { env, encoding: "utf8" }));
    assert.equal(needsRegister.stage, "needs_registry_register");
    assert.equal(needsRegister.evidence.pull.status, "pulled");
    assert.equal(needsRegister.evidence.snapshot.status, "valid");
    assert(needsRegister.nextCommands.some((command: string) => command.includes("register-remote-collector.sh apply")));

    await writeRegisteredRegistry(deployDir);
    const ready = JSON.parse(execFileSync(ROLLOUT, ["status", bundleDir], { env, encoding: "utf8" }));
    assert.equal(ready.status, "ready");
    assert.equal(ready.stage, "ready_for_healthcheck");
    assert.equal(ready.evidence.registry.status, "registered");
    assert.deepEqual(ready.nextCommands, ["./healthcheck.sh"]);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
