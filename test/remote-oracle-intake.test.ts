import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "local", "remote-oracle-intake.sh");
const CONFIRM = "I_UNDERSTAND_THIS_WRITES_LOCAL_PUSH_CONFIG_AND_TOM_RUNTIME_ONLY";

async function writeHarness(dir: string) {
  const binDir = join(dir, "bin");
  const runtimeDir = join(dir, "runtime");
  await mkdir(binDir, { recursive: true });
  await mkdir(runtimeDir, { recursive: true });
  const discovery = join(binDir, "discover.sh");
  const push = join(binDir, "push.sh");
  const fakeSsh = join(binDir, "ssh");
  const discoveryCalls = join(dir, "discovery-calls.txt");
  const pushCalls = join(dir, "push-calls.txt");
  const sshCalls = join(dir, "ssh-calls.txt");
  const keyFile = join(dir, "remote-readonly.key");
  await writeFile(keyFile, "fake remote readonly key\n", "utf8");
  await chmod(keyFile, 0o600);
  await writeFile(
    discovery,
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$DISCOVERY_CALLS"
mode="$1"
if [ "$mode" = "render-push-config" ]; then
  cat <<JSON
{
  "schemaVersion": 1,
  "tom": {
    "host": "146.235.226.66",
    "user": "ubuntu",
    "port": 22,
    "sshKey": "/tmp/tom.key",
    "deployDir": "/srv/openclaw-control-center-readonly",
    "strictHostKeyChecking": "accept-new"
  },
  "server": {
    "id": "remote-oracle",
    "name": "Remote Oracle",
    "host": "$REMOTE_ORACLE_HOST"
  },
  "remote": {
    "host": "$REMOTE_ORACLE_HOST",
    "user": "\${REMOTE_ORACLE_USER:-ubuntu}",
    "port": "\${REMOTE_ORACLE_PORT:-22}",
    "sourceSshKeyPath": "$REMOTE_ORACLE_KEY_PATH",
    "targetSshKeyPath": "/srv/openclaw-control-center-readonly/runtime/ssh/remote-oracle-readonly.key",
    "knownHostsFile": "/srv/openclaw-control-center-readonly/runtime/ssh/known_hosts",
    "strictHostKeyChecking": "accept-new",
    "connectTimeoutSeconds": 10,
    "deployDir": "/srv/openclaw-collector-node"
  },
  "collectorNode": {
    "image": "openclaw-control-center:collector-node",
    "bundleBuildContext": true,
    "collectorContainerName": "openclaw-collector-remote-oracle",
    "cronSchedule": "*/2 * * * *"
  },
  "instances": [
    {
      "id": "remote-main",
      "name": "Remote Main",
      "gatewayUrl": "ws://host.docker.internal:18789",
      "configDir": "/srv/openclaw/config",
      "workspaceDir": "/srv/openclaw/workspace"
    }
  ],
  "outputConfigFile": "/srv/openclaw-control-center-readonly/runtime/remote-collector-onboarding.json",
  "overwrite": false
}
JSON
  exit 0
fi
if [ "$mode" = "write-push-config" ]; then
  [ "$CONFIRM_REMOTE_ORACLE_PUSH_CONFIG_WRITE" = "I_UNDERSTAND_THIS_ONLY_WRITES_LOCAL_PUSH_CONFIG" ]
  "$0" render-push-config "$2" > "$REMOTE_ORACLE_PUSH_CONFIG_OUTPUT"
  cat <<JSON
{
  "schemaVersion": 1,
  "status": "written",
  "outputFile": "$REMOTE_ORACLE_PUSH_CONFIG_OUTPUT",
  "selected": {
    "host": "$REMOTE_ORACLE_HOST",
    "keyPath": "$REMOTE_ORACLE_KEY_PATH"
  },
  "safety": {
    "writesLocalPushConfigOnly": true,
    "connectsSecondOracle": false,
    "outputsPrivateKeyContent": false
  }
}
JSON
  exit 0
fi
echo "unexpected discovery mode" >&2
exit 2
`,
    "utf8",
  );
  await writeFile(
    push,
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$PUSH_CALLS"
mode="$1"
config="$2"
if [ "$mode" = "plan" ]; then
  node - "$config" <<'NODE'
const fs = require("node:fs");
const config = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
console.log(JSON.stringify({
  status: "planned",
  serverId: config.server.id,
  remote: config.remote,
  outputConfigFile: config.outputConfigFile,
  safety: {
    writesTomControlCenterRuntimeOnly: false,
    connectsTomSsh: false,
    connectsSecondOracle: false,
    writesActiveRegistry: false,
    callsLiveApi: false
  }
}, null, 2));
NODE
  exit 0
fi
if [ "$mode" = "apply" ]; then
  [ "$CONFIRM_PUSH_REMOTE_COLLECTOR_CREDENTIALS" = "I_UNDERSTAND_THIS_ONLY_PUSHES_REMOTE_COLLECTOR_CREDENTIALS_TO_TOM_RUNTIME" ]
  node - "$config" <<'NODE'
const fs = require("node:fs");
const config = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
console.log(JSON.stringify({
  status: "applied",
  serverId: config.server.id,
  remote: config.remote,
  outputConfigFile: config.outputConfigFile,
  remoteResult: {
    status: "applied",
    safety: {
      writesControlCenterRuntimeOnly: true,
      connectsSecondOracle: false,
      writesActiveRegistry: false,
      mutatesOpenClawInstance: false,
      callsLiveApi: false
    }
  },
  safety: {
    writesTomControlCenterRuntimeOnly: true,
    connectsTomSsh: true,
    connectsSecondOracle: false,
    writesActiveRegistry: false,
    callsLiveApi: false
  }
}, null, 2));
NODE
  exit 0
fi
echo "unexpected push mode" >&2
exit 2
`,
    "utf8",
  );
  await writeFile(
    fakeSsh,
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$SSH_CALLS"
cat <<'JSON'
{
  "status": "ready",
  "stage": "ready_for_healthcheck",
  "safety": {
    "mutatesOpenClawInstance": false,
    "callsLiveApi": false
  }
}
JSON
`,
    "utf8",
  );
  await chmod(discovery, 0o755);
  await chmod(push, 0o755);
  await chmod(fakeSsh, 0o755);
  return { discovery, push, discoveryCalls, pushCalls, sshCalls, keyFile, runtimeDir, binDir };
}

test("remote Oracle intake plan renders the push config without writing or pushing", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-oracle-intake-"));
  try {
    const { discovery, push, discoveryCalls, pushCalls, keyFile, runtimeDir } = await writeHarness(dir);
    const output = execFileSync(SCRIPT, ["plan"], {
      env: {
        ...process.env,
        DISCOVERY_SCRIPT: discovery,
        PUSH_SCRIPT: push,
        PUSH_CONFIG_FILE: join(runtimeDir, "push-remote-collector-credentials.json"),
        DISCOVERY_CALLS: discoveryCalls,
        PUSH_CALLS: pushCalls,
        REMOTE_ORACLE_HOST: "129.146.10.20",
        REMOTE_ORACLE_KEY_PATH: keyFile,
      },
      encoding: "utf8",
    });
    const report = JSON.parse(output);

    assert.equal(report.status, "planned");
    assert.equal(report.target.host, "129.146.10.20");
    assert.equal(report.safety.writesLocalPushConfig, false);
    assert.equal(report.safety.connectsTomSsh, false);
    assert.equal(report.safety.connectsSecondOracle, false);
    assert.equal(existsSync(join(runtimeDir, "push-remote-collector-credentials.json")), false);
    assert.equal(existsSync(pushCalls), false);
    assert.match(await readFile(discoveryCalls, "utf8"), /render-push-config/);
    assert.doesNotMatch(output, /fake remote readonly key/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("remote Oracle intake apply requires a top-level confirmation", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-oracle-intake-"));
  try {
    const { discovery, push, discoveryCalls, pushCalls, keyFile, runtimeDir } = await writeHarness(dir);
    const result = spawnSync(SCRIPT, ["apply"], {
      env: {
        ...process.env,
        DISCOVERY_SCRIPT: discovery,
        PUSH_SCRIPT: push,
        PUSH_CONFIG_FILE: join(runtimeDir, "push-remote-collector-credentials.json"),
        DISCOVERY_CALLS: discoveryCalls,
        PUSH_CALLS: pushCalls,
        REMOTE_ORACLE_HOST: "129.146.10.20",
        REMOTE_ORACLE_KEY_PATH: keyFile,
      },
      encoding: "utf8",
    });

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /CONFIRM_REMOTE_ORACLE_INTAKE/);
    assert.equal(existsSync(join(runtimeDir, "push-remote-collector-credentials.json")), false);
    assert.equal(existsSync(discoveryCalls), false);
    assert.equal(existsSync(pushCalls), false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("remote Oracle intake apply writes local config and pushes only to Tom runtime", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-oracle-intake-"));
  try {
    const { discovery, push, discoveryCalls, pushCalls, keyFile, runtimeDir } = await writeHarness(dir);
    const pushConfigFile = join(runtimeDir, "push-remote-collector-credentials.json");
    const output = execFileSync(SCRIPT, ["apply"], {
      env: {
        ...process.env,
        DISCOVERY_SCRIPT: discovery,
        PUSH_SCRIPT: push,
        PUSH_CONFIG_FILE: pushConfigFile,
        DISCOVERY_CALLS: discoveryCalls,
        PUSH_CALLS: pushCalls,
        REMOTE_ORACLE_HOST: "129.146.10.20",
        REMOTE_ORACLE_KEY_PATH: keyFile,
        CONFIRM_REMOTE_ORACLE_INTAKE: CONFIRM,
      },
      encoding: "utf8",
    });
    const report = JSON.parse(output);
    const pushConfig = JSON.parse(await readFile(pushConfigFile, "utf8"));
    const discoveryLog = await readFile(discoveryCalls, "utf8");
    const pushLog = await readFile(pushCalls, "utf8");

    assert.equal(report.status, "applied");
    assert.equal(report.safety.writesLocalPushConfig, true);
    assert.equal(report.safety.writesTomControlCenterRuntimeOnly, true);
    assert.equal(report.safety.connectsTomSsh, true);
    assert.equal(report.safety.connectsSecondOracle, false);
    assert.equal(report.safety.writesActiveRegistry, false);
    assert.equal(report.safety.callsLiveApi, false);
    assert.equal(pushConfig.remote.host, "129.146.10.20");
    assert.equal(pushConfig.remote.sourceSshKeyPath, keyFile);
    assert.match(discoveryLog, /write-push-config/);
    assert.match(pushLog, /plan/);
    assert.match(pushLog, /apply/);
    assert.doesNotMatch(pushLog, /129\.146\.10\.20/);
    assert.doesNotMatch(output, /fake remote readonly key/);
    assert.doesNotMatch(output, /api\/managed-actions\/live/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("remote Oracle intake run requires the rollout confirmation before writing", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-oracle-intake-"));
  try {
    const { discovery, push, discoveryCalls, pushCalls, sshCalls, keyFile, runtimeDir, binDir } = await writeHarness(dir);
    const result = spawnSync(SCRIPT, ["run"], {
      env: {
        ...process.env,
        PATH: `${binDir}${delimiter}${process.env.PATH ?? ""}`,
        DISCOVERY_SCRIPT: discovery,
        PUSH_SCRIPT: push,
        PUSH_CONFIG_FILE: join(runtimeDir, "push-remote-collector-credentials.json"),
        DISCOVERY_CALLS: discoveryCalls,
        PUSH_CALLS: pushCalls,
        SSH_CALLS: sshCalls,
        REMOTE_ORACLE_HOST: "129.146.10.20",
        REMOTE_ORACLE_KEY_PATH: keyFile,
        CONFIRM_REMOTE_ORACLE_INTAKE: CONFIRM,
      },
      encoding: "utf8",
    });

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /CONFIRM_REMOTE_ORACLE_INTAKE_RUNNER/);
    assert.equal(existsSync(join(runtimeDir, "push-remote-collector-credentials.json")), false);
    assert.equal(existsSync(discoveryCalls), false);
    assert.equal(existsSync(pushCalls), false);
    assert.equal(existsSync(sshCalls), false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("remote Oracle intake run pushes credentials and triggers Tom safe rollout", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-remote-oracle-intake-"));
  try {
    const { discovery, push, discoveryCalls, pushCalls, sshCalls, keyFile, runtimeDir, binDir } = await writeHarness(dir);
    const pushConfigFile = join(runtimeDir, "push-remote-collector-credentials.json");
    const output = execFileSync(SCRIPT, ["run"], {
      env: {
        ...process.env,
        PATH: `${binDir}${delimiter}${process.env.PATH ?? ""}`,
        DISCOVERY_SCRIPT: discovery,
        PUSH_SCRIPT: push,
        PUSH_CONFIG_FILE: pushConfigFile,
        DISCOVERY_CALLS: discoveryCalls,
        PUSH_CALLS: pushCalls,
        SSH_CALLS: sshCalls,
        REMOTE_ORACLE_HOST: "129.146.10.20",
        REMOTE_ORACLE_KEY_PATH: keyFile,
        CONFIRM_REMOTE_ORACLE_INTAKE: CONFIRM,
        CONFIRM_REMOTE_ORACLE_INTAKE_RUNNER: "I_UNDERSTAND_THIS_PUSHES_CREDENTIALS_AND_RUNS_TOM_SAFE_ROLLOUT",
      },
      encoding: "utf8",
    });
    const report = JSON.parse(output);
    const pushConfig = JSON.parse(await readFile(pushConfigFile, "utf8"));
    const sshLog = await readFile(sshCalls, "utf8");

    assert.equal(report.status, "ran_rollout_runner");
    assert.equal(report.apply.status, "applied");
    assert.equal(report.rolloutRunner.exitCode, 0);
    assert.equal(report.safety.connectsTomSsh, true);
    assert.equal(report.safety.mayConnectSecondOracleViaTomReadonlyPreflight, true);
    assert.equal(report.safety.writesOpenClawInstanceDirs, false);
    assert.equal(report.safety.callsLiveApi, false);
    assert.equal(pushConfig.remote.host, "129.146.10.20");
    assert.match(sshLog, /ubuntu@146\.235\.226\.66/);
    assert.match(sshLog, /remote-collector-rollout-runner\.sh run/);
    assert.match(sshLog, /go-live-gate\.sh status/);
    assert.doesNotMatch(sshLog, /129\.146\.10\.20/);
    assert.doesNotMatch(output, /fake remote readonly key/);
    assert.doesNotMatch(output, /api\/managed-actions\/live/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
