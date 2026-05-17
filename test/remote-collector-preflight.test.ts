import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const ONBOARDING = join(ROOT, "ops", "tom-readonly", "remote-collector-onboarding.sh");
const PREFLIGHT = join(ROOT, "ops", "tom-readonly", "remote-collector-preflight.sh");

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

async function writeFakeSsh(dir: string, failPattern?: string): Promise<{ fakeBin: string; sshLog: string }> {
  const fakeBin = join(dir, "bin");
  const sshLog = join(dir, "ssh-commands.log");
  await mkdir(fakeBin, { recursive: true });
  const fakeSsh = join(fakeBin, "ssh");
  await writeFile(
    fakeSsh,
    `#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$FAKE_SSH_LOG"
cmd="\${@: -1}"
if [ -n "\${FAKE_FAIL_PATTERN:-}" ] && printf '%s' "$cmd" | grep -F "$FAKE_FAIL_PATTERN" >/dev/null 2>&1; then
  printf 'forced failure for %s\\n' "$FAKE_FAIL_PATTERN" >&2
  exit 1
fi
if printf '%s' "$cmd" | grep -F 'docker --version' >/dev/null 2>&1; then
  printf 'Docker version 27.0.0\\n'
fi
exit 0
`,
    "utf8",
  );
  await chmod(fakeSsh, 0o755);
  return { fakeBin, sshLog };
}

test("remote collector preflight plans without ssh", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-preflight-"));
  try {
    const { deployDir, bundleDir } = await writeOnboardingConfig(dir);
    const { fakeBin, sshLog } = await writeFakeSsh(dir);
    const plan = JSON.parse(
      execFileSync(PREFLIGHT, ["plan", bundleDir], {
        env: { ...process.env, DEPLOY_DIR: deployDir, PATH: `${fakeBin}${delimiter}${process.env.PATH ?? ""}` },
        encoding: "utf8",
      }),
    );
    assert.equal(plan.status, "planned");
    assert.equal(plan.serverId, "remote-oracle");
    assert.equal(plan.safety.connectsSsh, false);
    assert(plan.checks.some((check: { id: string }) => check.id === "docker"));
    assert(plan.checks.some((check: { id: string }) => check.id === "gateway_remote-main"));

    const logResult = spawnSync("test", ["-e", sshLog]);
    assert.notEqual(logResult.status, 0);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("remote collector preflight checks readonly prerequisites with confirmation", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-preflight-"));
  try {
    const { deployDir, bundleDir } = await writeOnboardingConfig(dir);
    const { fakeBin, sshLog } = await writeFakeSsh(dir);
    const env = {
      ...process.env,
      DEPLOY_DIR: deployDir,
      PATH: `${fakeBin}${delimiter}${process.env.PATH ?? ""}`,
      FAKE_SSH_LOG: sshLog,
    };

    const blocked = spawnSync(PREFLIGHT, ["check", bundleDir], { env, encoding: "utf8" });
    assert.notEqual(blocked.status, 0);
    assert.match(blocked.stderr, /CONFIRM_REMOTE_COLLECTOR_PREFLIGHT/);

    const checked = JSON.parse(
      execFileSync(PREFLIGHT, ["check", bundleDir], {
        env: {
          ...env,
          CONFIRM_REMOTE_COLLECTOR_PREFLIGHT: "I_UNDERSTAND_THIS_ONLY_READS_REMOTE_PREREQUISITES",
        },
        encoding: "utf8",
      }),
    );
    assert.equal(checked.status, "ready");
    assert.equal(checked.safety.readsRemotePrerequisitesOnly, true);
    assert.equal(checked.safety.writesRemoteFiles, false);
    assert.equal(checked.safety.startsContainers, false);
    assert.equal(checked.safety.mutatesOpenClawInstance, false);
    assert.equal(checked.safety.callsLiveApi, false);
    assert.equal(checked.safety.connectsSsh, true);
    assert(checked.results.every((result: { status: string }) => result.status === "pass"));

    const sshCommands = await readFile(sshLog, "utf8");
    assert.match(sshCommands, /ubuntu@10\.0\.0\.12/);
    assert.match(sshCommands, /docker --version/);
    assert(sshCommands.includes("test -d '/srv/openclaw/config'"));
    assert.doesNotMatch(sshCommands, /docker compose .*up/);
    assert.doesNotMatch(sshCommands, /collector-snapshot/);
    assert.doesNotMatch(sshCommands, /managed-actions\/live/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("remote collector preflight blocks when a required readonly check fails", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-preflight-"));
  try {
    const { deployDir, bundleDir } = await writeOnboardingConfig(dir);
    const { fakeBin, sshLog } = await writeFakeSsh(dir, "/srv/openclaw/workspace");
    const result = spawnSync(PREFLIGHT, ["check", bundleDir], {
      env: {
        ...process.env,
        DEPLOY_DIR: deployDir,
        PATH: `${fakeBin}${delimiter}${process.env.PATH ?? ""}`,
        FAKE_SSH_LOG: sshLog,
        FAKE_FAIL_PATTERN: "/srv/openclaw/workspace",
        CONFIRM_REMOTE_COLLECTOR_PREFLIGHT: "I_UNDERSTAND_THIS_ONLY_READS_REMOTE_PREREQUISITES",
      },
      encoding: "utf8",
    });
    assert.notEqual(result.status, 0);
    const body = JSON.parse(result.stdout);
    assert.equal(body.status, "blocked");
    assert(body.results.some((item: { id: string; status: string }) => item.id === "workspace_dir_remote-main" && item.status === "fail"));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
