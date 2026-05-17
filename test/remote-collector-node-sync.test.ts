import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const ONBOARDING = join(ROOT, "ops", "tom-readonly", "remote-collector-onboarding.sh");
const SYNC = join(ROOT, "ops", "tom-readonly", "remote-collector-node-sync.sh");

async function writeOnboardingConfig(dir: string): Promise<{ deployDir: string; bundleDir: string; configFile: string; sshKey: string }> {
  const deployDir = join(dir, "deploy");
  const bundleDir = join(deployDir, "runtime", "remote-onboarding", "remote-oracle");
  const sshKey = join(deployDir, "runtime", "ssh", "remote-oracle-readonly.key");
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
  await mkdir(join(deployDir, "runtime", "ssh"), { recursive: true });
  await writeFile(sshKey, "fake readonly key\n", "utf8");
  execFileSync(ONBOARDING, ["write", configFile], {
    env: {
      ...process.env,
      DEPLOY_DIR: deployDir,
      CONFIRM_REMOTE_COLLECTOR_ONBOARDING: "I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_ONBOARDING_BUNDLE",
    },
    encoding: "utf8",
  });
  return { deployDir, bundleDir, configFile, sshKey };
}

async function writeFakeSsh(
  dir: string,
  options: { argsFile: string; stdinFile: string; mode?: "sync" | "bootstrap" },
): Promise<string> {
  const binDir = join(dir, "bin");
  await mkdir(binDir, { recursive: true });
  const ssh = join(binDir, "ssh");
  const stdout = options.mode === "bootstrap"
    ? `case "$*" in
  *"bootstrap-collector-node.sh plan"*) printf '{"status":"planned","safety":{"startsContainers":false,"mutatesOpenClawInstance":false}}\\n' ;;
  *"bootstrap-collector-node.sh write"*) printf '{"status":"written","nextActions":["cd /srv/openclaw-collector-node && ./collector-snapshot.sh"]}\\n' ;;
  *) printf '{"status":"unknown"}\\n' ;;
esac`
    : `printf 'synced\\n'`;
  await writeFile(
    ssh,
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$@" > "${options.argsFile}"
cat > "${options.stdinFile}"
${stdout}
`,
    "utf8",
  );
  await chmod(ssh, 0o755);
  return binDir;
}

test("remote collector node sync plans without network or writes", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-node-sync-"));
  try {
    const { deployDir, bundleDir } = await writeOnboardingConfig(dir);
    const plan = JSON.parse(
      execFileSync(SYNC, ["plan", bundleDir], {
        env: { ...process.env, DEPLOY_DIR: deployDir },
        encoding: "utf8",
      }),
    );

    assert.equal(plan.status, "planned");
    assert.equal(plan.serverId, "remote-oracle");
    assert.equal(plan.remoteTarget.host, "10.0.0.12");
    assert.equal(plan.remoteTarget.deployDir, "/srv/openclaw-collector-node");
    assert.equal(plan.safety.connectsSsh, false);
    assert.equal(plan.safety.writesRemoteCollectorNode, false);
    assert.equal(plan.safety.writesOpenClawInstanceDirs, false);
    assert.equal(plan.safety.startsContainers, false);
    assert.equal(plan.safety.callsLiveApi, false);
    assert(plan.bundle.files >= 6);
    assert(plan.nextActions.some((command: string) => command.includes("remote-collector-node-sync.sh sync")));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("remote collector node sync copies only after explicit confirmation", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-node-sync-"));
  try {
    const { deployDir, bundleDir } = await writeOnboardingConfig(dir);
    const argsFile = join(dir, "ssh-args.txt");
    const stdinFile = join(dir, "bundle.tar");
    const fakeBin = await writeFakeSsh(dir, { argsFile, stdinFile, mode: "sync" });
    const env = { ...process.env, DEPLOY_DIR: deployDir, PATH: `${fakeBin}:${process.env.PATH || ""}` };

    const blocked = spawnSync(SYNC, ["sync", bundleDir], { env, encoding: "utf8" });
    assert.notEqual(blocked.status, 0);
    assert.match(blocked.stderr, /CONFIRM_REMOTE_COLLECTOR_NODE_SYNC/);

    const synced = JSON.parse(
      execFileSync(SYNC, ["sync", bundleDir], {
        env: {
          ...env,
          CONFIRM_REMOTE_COLLECTOR_NODE_SYNC: "I_UNDERSTAND_THIS_ONLY_COPIES_COLLECTOR_BUNDLE_TO_REMOTE",
        },
        encoding: "utf8",
      }),
    );

    assert.equal(synced.status, "synced");
    assert.equal(synced.safety.writesRemoteBundle, true);
    assert.equal(synced.safety.writesRemoteCollectorNode, true);
    assert.equal(synced.safety.writesOpenClawInstanceDirs, false);
    assert.equal(synced.safety.startsContainers, false);
    assert.equal(synced.safety.installsCron, false);
    assert.equal(synced.safety.callsLiveApi, false);

    const args = await readFile(argsFile, "utf8");
    assert.match(args, /ubuntu@10\.0\.0\.12/);
    assert.match(args, /tar -C '\\''\/srv\/openclaw-collector-node'\\'' -xf -/);
    const tarList = execFileSync("tar", ["-tf", stdinFile], { encoding: "utf8" });
    assert.match(tarList, /collector-node\.json/);
    assert.match(tarList, /bootstrap-collector-node\.sh/);
    assert.match(tarList, /remote-collector-pull\.sources\.json/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("remote collector node bootstrap modes stay collector-only", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-node-sync-"));
  try {
    const { deployDir, bundleDir } = await writeOnboardingConfig(dir);
    const argsFile = join(dir, "ssh-bootstrap-args.txt");
    const stdinFile = join(dir, "ssh-bootstrap-stdin.txt");
    const fakeBin = await writeFakeSsh(dir, { argsFile, stdinFile, mode: "bootstrap" });
    const env = { ...process.env, DEPLOY_DIR: deployDir, PATH: `${fakeBin}:${process.env.PATH || ""}` };

    const blocked = spawnSync(SYNC, ["bootstrap-write", bundleDir], { env, encoding: "utf8" });
    assert.notEqual(blocked.status, 0);
    assert.match(blocked.stderr, /CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_WRITE/);

    const planned = JSON.parse(
      execFileSync(SYNC, ["bootstrap-plan", bundleDir], {
        env: {
          ...env,
          CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_PLAN: "I_UNDERSTAND_THIS_ONLY_RUNS_REMOTE_BOOTSTRAP_PLAN",
        },
        encoding: "utf8",
      }),
    );
    assert.equal(planned.status, "bootstrap_plan_completed");
    assert.equal(planned.remoteResult.status, "planned");
    assert.equal(planned.safety.writesRemoteCollectorNode, false);
    assert.equal(planned.safety.startsContainers, false);

    const written = JSON.parse(
      execFileSync(SYNC, ["bootstrap-write", bundleDir], {
        env: {
          ...env,
          CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_WRITE: "I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_COLLECTOR_NODE_FILES",
        },
        encoding: "utf8",
      }),
    );
    assert.equal(written.status, "bootstrap_written");
    assert.equal(written.remoteResult.status, "written");
    assert.equal(written.safety.writesRemoteCollectorNode, true);
    assert.equal(written.safety.writesOpenClawInstanceDirs, false);
    assert.equal(written.safety.startsContainers, false);
    assert.equal(written.safety.callsLiveApi, false);

    const args = await readFile(argsFile, "utf8");
    assert.match(args, /bootstrap-collector-node\.sh write collector-node\.json/);
    assert.doesNotMatch(args, /collector-snapshot\.sh/);
    assert.equal((await readFile(stdinFile, "utf8")).length, 0);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
