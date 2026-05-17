import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "tom-readonly", "live-healthcheck-approval.sh");
const CONFIRM = "I_APPROVE_LIVE_HEALTHCHECK_RECORD";

async function writeExecutable(file: string, text: string) {
  await writeFile(file, text, "utf8");
  await chmod(file, 0o755);
}

async function writeReadyPacketScript(file: string, logFile: string) {
  await writeExecutable(
    file,
    `#!/usr/bin/env bash
set -euo pipefail
printf 'packet %s\\n' "$*" >> "${logFile}"
cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "ready",
  "packetFile": "fake-packet.json",
  "target": {
    "instanceId": "tom",
    "action": "healthcheck",
    "operator": "Anan"
  },
  "safety": {
    "callsManagedActionsLiveApi": false,
    "writesOpenClawInstanceDirs": false,
    "restartsOpenClawInstances": false,
    "bypassesApproval": false
  }
}
JSON
`,
  );
}

async function writeBlockedPacketScript(file: string, logFile: string) {
  await writeExecutable(
    file,
    `#!/usr/bin/env bash
set -euo pipefail
printf 'packet %s\\n' "$*" >> "${logFile}"
cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "blocked",
  "issues": ["packet is stale"]
}
JSON
exit 2
`,
  );
}

async function prepareApprovalFile(dir: string) {
  const deployDir = join(dir, "deploy");
  const approvalFile = join(deployDir, "runtime", "live-healthcheck-approval.json");
  await mkdir(join(deployDir, "runtime"), { recursive: true });
  execFileSync(SCRIPT, ["template", approvalFile], {
    env: {
      ...process.env,
      DEPLOY_DIR: deployDir,
    },
    encoding: "utf8",
  });
  return { deployDir, approvalFile };
}

test("live healthcheck approval approve requires and runs approval packet check", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-live-approval-"));
  try {
    const { deployDir, approvalFile } = await prepareApprovalFile(dir);
    const logFile = join(dir, "packet.log");
    const packetScript = join(dir, "approval-packet.sh");
    await writeReadyPacketScript(packetScript, logFile);

    const output = execFileSync(SCRIPT, ["approve", approvalFile], {
      env: {
        ...process.env,
        DEPLOY_DIR: deployDir,
        APPROVAL_PACKET_SCRIPT: packetScript,
        APPROVAL_PACKET_FILE: join(dir, "packet.json"),
        CONFIRM_APPROVAL_RECORD: CONFIRM,
        APPROVED_BY: "Anan",
        INSTANCE_ID: "tom",
        OPERATOR: "Anan",
      },
      encoding: "utf8",
    });

    const status = JSON.parse(output);
    const approval = JSON.parse(await readFile(approvalFile, "utf8"));
    const log = await readFile(logFile, "utf8");

    assert.equal(status.status, "approved");
    assert.equal(approval.approved, true);
    assert.equal(approval.approvedBy, "Anan");
    assert.equal(approval.consumed, false);
    assert.match(log, /packet check .*packet\.json/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("live healthcheck approval approve does not write approval when packet check fails", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-live-approval-blocked-"));
  try {
    const { deployDir, approvalFile } = await prepareApprovalFile(dir);
    const logFile = join(dir, "packet.log");
    const packetScript = join(dir, "approval-packet.sh");
    await writeBlockedPacketScript(packetScript, logFile);

    const result = spawnSync(SCRIPT, ["approve", approvalFile], {
      env: {
        ...process.env,
        DEPLOY_DIR: deployDir,
        APPROVAL_PACKET_SCRIPT: packetScript,
        APPROVAL_PACKET_FILE: join(dir, "stale-packet.json"),
        CONFIRM_APPROVAL_RECORD: CONFIRM,
        APPROVED_BY: "Anan",
        INSTANCE_ID: "tom",
        OPERATOR: "Anan",
      },
      encoding: "utf8",
    });

    const approval = JSON.parse(await readFile(approvalFile, "utf8"));
    const log = await readFile(logFile, "utf8");

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /批准前证据包校验未通过/);
    assert.equal(approval.approved, false);
    assert.equal(approval.approvedBy, "");
    assert.match(log, /packet check .*stale-packet\.json/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
