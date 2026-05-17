import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "tom-readonly", "remote-collector-pull.sh");

function snapshotJson(serverId = "remote-oracle"): string {
  const generatedAt = "2026-05-17T08:00:00.000Z";
  return JSON.stringify({
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
  });
}

async function writePullConfig(deployDir: string, configFile: string): Promise<string> {
  const localSnapshotPath = join(deployDir, "runtime", "collectors", "remote-oracle", "snapshot.json");
  await writeFile(
    configFile,
    `${JSON.stringify(
      {
        schemaVersion: 1,
        sources: [
          {
            serverId: "remote-oracle",
            host: "10.0.0.12",
            user: "ubuntu",
            port: 2222,
            sshKey: join(deployDir, "runtime", "ssh", "remote-oracle-readonly.key"),
            knownHostsFile: join(deployDir, "runtime", "ssh", "known_hosts"),
            remoteSnapshotPath: "/remote/snapshot.json",
            localSnapshotPath,
            connectTimeoutSeconds: 3,
            strictHostKeyChecking: "accept-new",
          },
        ],
      },
      null,
      2,
    )}\n`,
    "utf8",
  );
  return localSnapshotPath;
}

test("remote collector pull plans and atomically writes a validated snapshot", async () => {
  const tempDir = await mkdtemp(join(tmpdir(), "openclaw-remote-collector-pull-"));
  const deployDir = join(tempDir, "deploy");
  const fakeBin = join(tempDir, "bin");
  const configFile = join(tempDir, "sources.json");
  const fakeSshArgs = join(tempDir, "ssh-args.txt");

  try {
    await mkdir(fakeBin, { recursive: true });
    const fakeSsh = join(fakeBin, "ssh");
    await writeFile(
      fakeSsh,
      `#!/usr/bin/env bash\nprintf '%s\\n' "$@" > "$FAKE_SSH_ARGS"\nprintf '%s' "$FAKE_SNAPSHOT_JSON"\n`,
      "utf8",
    );
    await chmod(fakeSsh, 0o755);

    const localSnapshotPath = await writePullConfig(deployDir, configFile);
    const baseEnv = {
      ...process.env,
      DEPLOY_DIR: deployDir,
      PATH: `${fakeBin}${delimiter}${process.env.PATH ?? ""}`,
      FAKE_SSH_ARGS: fakeSshArgs,
      FAKE_SNAPSHOT_JSON: snapshotJson(),
    };

    const plan = JSON.parse(execFileSync(SCRIPT, ["plan", configFile], { env: baseEnv, encoding: "utf8" }));
    assert.equal(plan.status, "planned");
    assert.equal(plan.sources[0]?.serverId, "remote-oracle");
    assert.equal(plan.sources[0]?.localSnapshotPath, localSnapshotPath);

    const blocked = spawnSync(SCRIPT, ["pull", configFile], { env: baseEnv, encoding: "utf8" });
    assert.notEqual(blocked.status, 0);
    assert.match(blocked.stderr, /CONFIRM_REMOTE_COLLECTOR_PULL/);

    const pulled = JSON.parse(
      execFileSync(SCRIPT, ["pull", configFile], {
        env: {
          ...baseEnv,
          CONFIRM_REMOTE_COLLECTOR_PULL: "I_UNDERSTAND_THIS_ONLY_READS_REMOTE_COLLECTOR_SNAPSHOTS",
        },
        encoding: "utf8",
      }),
    );

    assert.equal(pulled.status, "completed");
    assert.equal(pulled.results[0]?.status, "pulled");
    assert.equal(pulled.results[0]?.instances, 1);

    const snapshot = JSON.parse(await readFile(localSnapshotPath, "utf8"));
    assert.equal(snapshot.serverId, "remote-oracle");
    assert.equal(snapshot.instances[0]?.id, "remote-main");

    const state = JSON.parse(
      await readFile(join(deployDir, "runtime", "collector-pull-state", "remote-oracle.json"), "utf8"),
    );
    assert.equal(state.status, "pulled");
    assert.equal(state.instances, 1);

    const sshArgs = await readFile(fakeSshArgs, "utf8");
    assert.match(sshArgs, /ubuntu@10\.0\.0\.12/);
    assert(sshArgs.includes("cat -- '/remote/snapshot.json'"));
    assert.doesNotMatch(sshArgs, /collector-snapshot/);
    assert.doesNotMatch(sshArgs, /managed-actions\/live/);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
});

test("remote collector pull rejects snapshots for the wrong server", async () => {
  const tempDir = await mkdtemp(join(tmpdir(), "openclaw-remote-collector-pull-"));
  const deployDir = join(tempDir, "deploy");
  const fakeBin = join(tempDir, "bin");
  const configFile = join(tempDir, "sources.json");

  try {
    await mkdir(fakeBin, { recursive: true });
    const fakeSsh = join(fakeBin, "ssh");
    await writeFile(fakeSsh, `#!/usr/bin/env bash\nprintf '%s' "$FAKE_SNAPSHOT_JSON"\n`, "utf8");
    await chmod(fakeSsh, 0o755);
    await writePullConfig(deployDir, configFile);

    const result = spawnSync(SCRIPT, ["pull", configFile], {
      env: {
        ...process.env,
        DEPLOY_DIR: deployDir,
        PATH: `${fakeBin}${delimiter}${process.env.PATH ?? ""}`,
        FAKE_SNAPSHOT_JSON: snapshotJson("other-oracle"),
        CONFIRM_REMOTE_COLLECTOR_PULL: "I_UNDERSTAND_THIS_ONLY_READS_REMOTE_COLLECTOR_SNAPSHOTS",
      },
      encoding: "utf8",
    });

    assert.notEqual(result.status, 0);
    const body = JSON.parse(result.stdout);
    assert.equal(body.status, "failed");
    assert.match(body.results[0]?.error ?? "", /serverId 不匹配/);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
});
