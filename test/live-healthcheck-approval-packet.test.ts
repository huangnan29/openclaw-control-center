import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "tom-readonly", "live-healthcheck-approval-packet.sh");

async function writeExecutable(file: string, text: string) {
  await writeFile(file, text, "utf8");
  await chmod(file, 0o755);
}

async function writeHarness(dir: string) {
  const deployDir = join(dir, "deploy");
  const scriptDir = join(dir, "scripts");
  const packetDir = join(deployDir, "runtime", "live-healthcheck-approval-packets");
  const approvalFile = join(deployDir, "runtime", "live-healthcheck-approval.json");
  const logFile = join(dir, "commands.log");

  await mkdir(join(deployDir, "runtime", "impact-snapshots"), { recursive: true });
  await mkdir(scriptDir, { recursive: true });
  await writeFile(
    approvalFile,
    `${JSON.stringify(
      {
        schemaVersion: 1,
        status: "needs_manual_approval",
        approved: false,
        consumed: false,
        instanceId: "tom",
        action: "healthcheck",
        operator: "Anan",
        issues: ["approved is not true"],
      },
      null,
      2,
    )}\n`,
    "utf8",
  );

  await writeExecutable(
    join(scriptDir, "go-live-gate.sh"),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'go-live-gate %s\\n' "$*" >> "${logFile}"
cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "blocked_managed_actions",
  "mode": "check",
  "topologyMode": "local-only",
  "stages": {
    "existingInstances": { "status": "passed" },
    "crossServerReadonlyMonitoring": { "status": "skipped_local_only" },
    "managedActions": { "status": "blocked" }
  }
}
JSON
`,
  );

  await writeExecutable(
    join(scriptDir, "managed-action-dry-run-gate.sh"),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'dry-run-gate %s\\n' "$*" >> "${logFile}"
cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "ready",
  "target": { "instanceId": "tom", "action": "healthcheck", "operator": "Anan" },
  "audit": {
    "latest": {
      "timestamp": "2026-05-17T06:17:16.015Z",
      "action": "healthcheck",
      "targetInstanceId": "tom",
      "operator": "Anan",
      "mutatesOpenClawInstance": false
    }
  },
  "issues": []
}
JSON
`,
  );

  await writeExecutable(
    join(scriptDir, "live-healthcheck-approval.sh"),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'approval %s\\n' "$*" >> "${logFile}"
cat "${approvalFile}"
`,
  );

  await writeExecutable(
    join(scriptDir, "live-healthcheck-window.sh"),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'live-window %s\\n' "$*" >> "${logFile}"
cat <<'TEXT'
[测试] 未检测到临时 override 文件
READONLY_MODE=true
MANAGED_ACTIONS_LIVE_ENABLED=<unset>
MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED=<unset>
readiness.status=blocked
readiness.liveExecutionAvailable=false
readiness.executor.productionWired=false
TEXT
`,
  );

  await writeExecutable(
    join(scriptDir, "instance-impact-snapshot.sh"),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'impact-snapshot %s\\n' "$*" >> "${logFile}"
output="${deployDir}/runtime/impact-snapshots/pre-live-approval-packet-test.json"
cat > "$output" <<'JSON'
{
  "schemaVersion": 1,
  "generatedAt": "2026-05-17T13:57:00.000Z",
  "repoCommit": "b408244d83cf3ff35ea6c79acdd8bf050c1da613",
  "controlCenter": {
    "env": {
      "READONLY_MODE": "true",
      "MANAGED_ACTIONS_LIVE_ENABLED": null,
      "MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED": null
    }
  },
  "readiness": {
    "liveExecutionAvailable": false,
    "executorProductionWired": false
  },
  "gateways": []
}
JSON
printf '%s\\n' "$output"
`,
  );

  return { deployDir, scriptDir, packetDir, approvalFile, logFile };
}

test("live healthcheck approval packet generates pre-approval evidence without live calls", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-live-approval-packet-"));
  try {
    const { deployDir, scriptDir, packetDir, approvalFile, logFile } = await writeHarness(dir);
    const packetPath = execFileSync(SCRIPT, ["generate"], {
      env: {
        ...process.env,
        DEPLOY_DIR: deployDir,
        SCRIPT_DIR: scriptDir,
        PACKET_DIR: packetDir,
        APPROVAL_FILE: approvalFile,
      },
      encoding: "utf8",
    }).trim();

    assert(packetPath.endsWith(".json"));
    assert(existsSync(packetPath));
    const packet = JSON.parse(await readFile(packetPath, "utf8"));
    assert.equal(packet.status, "ready_for_manual_approval");
    assert.equal(packet.topologyMode, "local-only");
    assert.equal(packet.gates.goLive.status, "blocked_managed_actions");
    assert.equal(packet.gates.goLive.existingInstancesStatus, "passed");
    assert.equal(packet.gates.dryRun.status, "ready");
    assert.equal(packet.gates.approval.status, "needs_manual_approval");
    assert.equal(packet.gates.liveWindow.readonlyMode, "true");
    assert.equal(packet.safety.callsManagedActionsLiveApi, false);
    assert.equal(packet.safety.writesOpenClawInstanceDirs, false);
    assert(existsSync(packet.artifacts.markdownPacket));
    assert(existsSync(packet.artifacts.impactSnapshot));

    const log = await readFile(logFile, "utf8");
    assert.match(log, /go-live-gate check/);
    assert.match(log, /dry-run-gate status/);
    assert.match(log, /approval status/);
    assert.match(log, /live-window status/);
    assert.match(log, /impact-snapshot snapshot pre-live-approval-packet/);
    assert.doesNotMatch(log, /live api|managed-actions\/live|approve /i);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
