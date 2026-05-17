import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "local", "discover-remote-oracle-credentials.sh");
const PROBE_CONFIRM = "I_UNDERSTAND_THIS_ONLY_PROBES_SSH_READONLY";

async function writeDiscoveryFixture(dir: string) {
  const sshDir = join(dir, ".ssh");
  const desktopDir = join(dir, "Desktop");
  await mkdir(sshDir, { recursive: true });
  await mkdir(desktopDir, { recursive: true });
  const configFile = join(dir, "discovery.json");
  const sshConfig = join(sshDir, "config");
  const keyFile = join(desktopDir, "ssh-key-2026-remote.key");
  const tomKeyFile = join(desktopDir, "ssh-key-tom.key");
  await writeFile(
    sshConfig,
    `Host tom
  HostName 146.235.226.66
  User ubuntu
  IdentityFile ${tomKeyFile}

Host second-oracle
  HostName 203.0.113.88
  User ubuntu
  Port 2222
  IdentityFile ${keyFile}
`,
    "utf8",
  );
  await writeFile(keyFile, "-----BEGIN OPENSSH PRIVATE KEY-----\nsecret-second-key\n-----END OPENSSH PRIVATE KEY-----\n", "utf8");
  await writeFile(tomKeyFile, "-----BEGIN OPENSSH PRIVATE KEY-----\nsecret-tom-key\n-----END OPENSSH PRIVATE KEY-----\n", "utf8");
  await chmod(keyFile, 0o600);
  await chmod(tomKeyFile, 0o600);
  await writeFile(
    configFile,
    `${JSON.stringify(
      {
        schemaVersion: 1,
        tom: {
          host: "146.235.226.66",
          user: "ubuntu",
          port: 22,
        },
        scan: {
          sshConfigFiles: [sshConfig],
          keyGlobs: [join(desktopDir, "ssh-key*.key")],
          excludeHosts: ["146.235.226.66"],
          defaultUser: "ubuntu",
          defaultPort: 22,
          connectTimeoutSeconds: 3,
          maxProbeCombinations: 5,
        },
      },
      null,
      2,
    )}\n`,
    "utf8",
  );
  return { configFile, keyFile };
}

async function writeFakeSsh(dir: string) {
  const fakeBin = join(dir, "bin");
  const argsFile = join(dir, "ssh-args.txt");
  await mkdir(fakeBin, { recursive: true });
  const fakeSsh = join(fakeBin, "ssh");
  await writeFile(
    fakeSsh,
    `#!/usr/bin/env bash
printf '%s\\n' "$*" > "$FAKE_SSH_ARGS"
echo "user=ubuntu host=second-oracle uname=Linux"
`,
    "utf8",
  );
  await chmod(fakeSsh, 0o755);
  return { fakeBin, argsFile };
}

test("remote Oracle discovery scan finds non-Tom host and key without leaking key content", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-discover-remote-oracle-"));
  try {
    const { configFile, keyFile } = await writeDiscoveryFixture(dir);
    const output = execFileSync(SCRIPT, ["scan", configFile], { encoding: "utf8" });
    const report = JSON.parse(output);

    assert.equal(report.status, "candidates_found");
    assert.equal(report.summary.hosts, 1);
    assert.equal(report.hosts[0]?.host, "203.0.113.88");
    assert.equal(report.hosts[0]?.port, 2222);
    assert(report.keys.some((item: { path: string }) => item.path === keyFile));
    assert.equal(report.safety.readsLocalSshConfigOnly, true);
    assert.equal(report.safety.writesLocalFiles, false);
    assert.equal(report.safety.outputsPrivateKeyContent, false);
    assert.doesNotMatch(output, /secret-second-key/);
    assert.doesNotMatch(output, /secret-tom-key/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("remote Oracle discovery probe requires confirmation", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-discover-remote-oracle-"));
  try {
    const { configFile } = await writeDiscoveryFixture(dir);
    const result = spawnSync(SCRIPT, ["probe", configFile], { encoding: "utf8" });

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /CONFIRM_REMOTE_ORACLE_DISCOVERY/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("remote Oracle discovery probe uses readonly ssh options and records reachable candidates", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-discover-remote-oracle-"));
  try {
    const { configFile } = await writeDiscoveryFixture(dir);
    const { fakeBin, argsFile } = await writeFakeSsh(dir);
    const output = execFileSync(SCRIPT, ["probe", configFile], {
      env: {
        ...process.env,
        PATH: `${fakeBin}${delimiter}${process.env.PATH ?? ""}`,
        FAKE_SSH_ARGS: argsFile,
        CONFIRM_REMOTE_ORACLE_DISCOVERY: PROBE_CONFIRM,
      },
      encoding: "utf8",
    });
    const report = JSON.parse(output);
    const args = await readFile(argsFile, "utf8");

    assert.equal(report.status, "reachable_candidate_found");
    assert.equal(report.summary.reachable, 1);
    assert.equal(report.probes[0]?.status, "reachable");
    assert.equal(report.safety.connectsSecondOracle, true);
    assert.equal(report.safety.writesRemoteFiles, false);
    assert.match(args, /UserKnownHostsFile=\/dev\/null/);
    assert.match(args, /StrictHostKeyChecking=no/);
    assert.match(args, /id -un/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
