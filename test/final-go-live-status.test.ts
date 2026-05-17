import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "local", "final-go-live-status.sh");

async function writeExecutable(file: string, content: string): Promise<void> {
  await writeFile(file, content, "utf8");
  await chmod(file, 0o755);
}

async function writeHarness(dir: string, options: {
  doctorStatus: "needs_remote_host" | "ready_for_apply";
  gateStatus?: "blocked_cross_server_readonly" | "blocked_managed_actions";
}) {
  const binDir = join(dir, "bin");
  await mkdir(binDir, { recursive: true });
  const intake = join(binDir, "remote-oracle-intake.sh");
  const ssh = join(binDir, "ssh");
  const key = join(dir, "tom.key");
  const discoveryConfig = join(dir, "discover-remote-oracle.json");
  const intakeCalls = join(dir, "intake-calls.txt");
  const sshCalls = join(dir, "ssh-calls.txt");
  const gateStatus = options.gateStatus || "blocked_cross_server_readonly";

  await writeFile(key, "fake tom key\n", "utf8");
  await chmod(key, 0o600);
  await writeFile(
    discoveryConfig,
    JSON.stringify(
      {
        tom: {
          host: "146.235.226.66",
          user: "ubuntu",
          port: 22,
          sshKey: key,
          deployDir: "/srv/openclaw-control-center-readonly",
          strictHostKeyChecking: "accept-new",
        },
      },
      null,
      2,
    ),
    "utf8",
  );

  await writeExecutable(
    intake,
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$INTAKE_CALLS"
cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "${options.doctorStatus}",
  "mode": "doctor",
  "missing": {
    "remoteHost": ${options.doctorStatus === "needs_remote_host" ? "true" : "false"},
    "remoteKeyPath": false
  },
  "selected": {
    "host": ${options.doctorStatus === "ready_for_apply" ? "\"129.146.10.20\"" : "null"},
    "sourceSshKeyPath": "/tmp/remote-readonly.key"
  },
  "nextCommands": [
    "REMOTE_ORACLE_HOST=<可达候选 host> REMOTE_ORACLE_KEY_PATH=<可达候选 keyPath> ops/local/remote-oracle-intake.sh doctor",
    "CONFIRM_REMOTE_ORACLE_INTAKE=I_UNDERSTAND_THIS_WRITES_LOCAL_PUSH_CONFIG_AND_TOM_RUNTIME_ONLY ops/local/remote-oracle-intake.sh apply"
  ],
  "safety": {
    "writesLocalFiles": false,
    "connectsTomSsh": false,
    "connectsSecondOracle": false,
    "callsLiveApi": false,
    "outputsPrivateKeyContent": false
  }
}
JSON
`,
  );

  await writeExecutable(
    ssh,
    `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$SSH_CALLS"
mode="status"
if printf '%s\\n' "$*" | grep -q 'go-live-gate.sh check'; then
  mode="check"
fi
cat <<JSON
__OPENCLAW_TOM_HEAD__abc123
{
  "schemaVersion": 1,
  "status": "${gateStatus}",
  "mode": "$mode",
  "stages": {
    "existingInstances": {
      "status": "$([ "$mode" = "check" ] && printf passed || printf skipped)"
    },
    "crossServerReadonlyMonitoring": {
      "status": "blocked",
      "stage": "needs_remote_credentials",
      "remoteAccess": {
        "status": "blocked",
        "issues": ["缺少 Tom runtime 里的远端只读 SSH key"]
      }
    },
    "managedActionDryRunEvidence": {
      "status": "ready",
      "issues": []
    },
    "managedActions": {
      "status": "blocked",
      "issues": ["需要人工 approval"]
    }
  },
  "nextCommands": [
    "repo/ops/tom-readonly/go-live-gate.sh check runtime/remote-onboarding/remote-oracle"
  ],
  "safety": {
    "writesOpenClawInstanceDirs": false,
    "restartsOpenClawInstances": false,
    "callsManagedActionsLiveApi": false
  }
}
JSON
`,
  );

  return { binDir, intake, ssh, key, discoveryConfig, intakeCalls, sshCalls };
}

function runStatus(
  harness: Awaited<ReturnType<typeof writeHarness>>,
  mode: "status" | "check",
  topologyMode = "cross-server",
) {
  const output = execFileSync(SCRIPT, [mode], {
    cwd: ROOT,
    env: {
      ...process.env,
      PATH: `${harness.binDir}${delimiter}${process.env.PATH ?? ""}`,
      DISCOVERY_CONFIG: harness.discoveryConfig,
      INTAKE_SCRIPT: harness.intake,
      INTAKE_CALLS: harness.intakeCalls,
      SSH_CALLS: harness.sshCalls,
      TOM_BUNDLE: "runtime/remote-onboarding/remote-oracle",
      OPENCLAW_TOPOLOGY_MODE: topologyMode,
    },
    encoding: "utf8",
  });
  return {
    output,
    report: JSON.parse(output),
  };
}

test("final go-live status reports the missing remote Oracle host while preserving readonly boundaries", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-final-go-live-status-"));
  try {
    const harness = await writeHarness(dir, { doctorStatus: "needs_remote_host" });
    const { output, report } = runStatus(harness, "status");
    const sshLog = await readFile(harness.sshCalls, "utf8");

    assert.equal(report.status, "blocked_remote_oracle_host");
    assert.equal(report.mode, "status");
    assert.equal(report.local.remoteOracleDoctor.report.status, "needs_remote_host");
    assert.equal(report.tom.goLiveGate.report.status, "blocked_cross_server_readonly");
    assert(report.blockers.some((item: string) => item.includes("缺少第二台 Oracle host")));
    assert(report.nextCommands.some((command: string) => command.includes("remote-oracle-intake.sh doctor")));
    assert.match(sshLog, /go-live-gate\.sh status/);
    assert.equal(report.safety.writesLocalFiles, false);
    assert.equal(report.safety.writesTomRuntime, false);
    assert.equal(report.safety.connectsSecondOracle, false);
    assert.equal(report.safety.writesOpenClawInstanceDirs, false);
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
    assert.doesNotMatch(output, /fake tom key/);
    assert.doesNotMatch(output, /api\/managed-actions\/live/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("final go-live check uses local-only topology without requiring remote Oracle credentials", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-final-go-live-status-"));
  try {
    const harness = await writeHarness(dir, {
      doctorStatus: "needs_remote_host",
      gateStatus: "blocked_managed_actions",
    });
    const { report } = runStatus(harness, "check", "local-only");
    const sshLog = await readFile(harness.sshCalls, "utf8");

    assert.equal(report.status, "blocked_managed_actions");
    assert.equal(report.topologyMode, "local-only");
    assert.equal(report.local.remoteOracleDoctor.status, "skipped_local_only");
    assert.equal(report.safety.crossServerRequired, false);
    assert.equal(report.safety.connectsSecondOracle, false);
    assert.equal(report.safety.writesTomRuntime, false);
    assert.equal(existsSync(harness.intakeCalls), false);
    assert.match(sshLog, /OPENCLAW_TOPOLOGY_MODE='?local-only'?/);
    assert.equal(report.blockers.some((item: string) => item.includes("第二台 Oracle")), false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("final go-live check delegates only the Tom gate check after local credentials are explicit", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-final-go-live-status-"));
  try {
    const harness = await writeHarness(dir, { doctorStatus: "ready_for_apply" });
    const { report } = runStatus(harness, "check");
    const sshLog = await readFile(harness.sshCalls, "utf8");
    const intakeLog = await readFile(harness.intakeCalls, "utf8");

    assert.equal(report.status, "blocked_cross_server_readonly");
    assert.equal(report.mode, "check");
    assert.equal(report.local.remoteOracleDoctor.report.status, "ready_for_apply");
    assert.equal(report.tom.goLiveGate.report.mode, "check");
    assert.equal(report.tom.goLiveGate.tom.head, "abc123");
    assert.match(sshLog, /go-live-gate\.sh check/);
    assert.match(intakeLog, /doctor/);
    assert.equal(report.safety.checkRunsHealthcheckOnly, true);
    assert.equal(report.safety.writesTomRuntime, false);
    assert.equal(report.safety.restartsOpenClawInstances, false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
