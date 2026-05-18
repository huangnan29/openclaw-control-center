import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
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
commit="test-commit-1234567890"
cat <<'JSON'
{
  "schemaVersion": 1,
  "status": "ready",
  "packetFile": "fake-packet.json",
  "generatedAt": "2026-05-17T18:00:00.000Z",
  "checkedAt": "2026-05-17T18:01:00.000Z",
  "topologyMode": "local-only",
  "target": {
    "instanceId": "tom",
    "action": "healthcheck",
    "operator": "Anan"
  },
  "commit": {
    "packet": "test-commit-1234567890",
    "current": "test-commit-1234567890"
  },
  "maxAgeSeconds": 21600,
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
  await mkdir(join(deployDir, "repo", ".git"), { recursive: true });
  await writeExecutable(
    join(deployDir, "repo", "git"),
    `#!/usr/bin/env bash
set -euo pipefail
printf 'test-commit-1234567890\\n'
`,
  );
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
    assert.equal(approval.approvalPacket.status, "ready");
    assert.equal(approval.approvalPacket.commit.current, "test-commit-1234567890");
    assert.match(log, /packet check .*packet\.json/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("live healthcheck approval prepare archives consumed record and writes a fresh template", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-live-approval-consumed-"));
  try {
    const { deployDir, approvalFile } = await prepareApprovalFile(dir);
    const approval = JSON.parse(await readFile(approvalFile, "utf8"));
    approval.approved = true;
    approval.approvedBy = "Anan";
    approval.approvedAt = "2026-05-17T18:24:19.802Z";
    approval.consumed = true;
    approval.consumedAt = "2026-05-17T18:24:39.181Z";
    approval.consumedBy = "Anan";
    await writeFile(approvalFile, `${JSON.stringify(approval, null, 2)}\n`, "utf8");

    const output = execFileSync(SCRIPT, ["prepare", approvalFile], {
      env: {
        ...process.env,
        DEPLOY_DIR: deployDir,
        INSTANCE_ID: "tom",
        OPERATOR: "Anan",
      },
      encoding: "utf8",
    });

    const status = JSON.parse(output);
    const nextApproval = JSON.parse(await readFile(approvalFile, "utf8"));
    const backups = await readdir(join(deployDir, "runtime", ".backup", "live-healthcheck-approval"));

    assert.equal(status.status, "needs_manual_approval");
    assert.equal(nextApproval.approved, false);
    assert.equal(nextApproval.consumed, false);
    assert.equal(nextApproval.approvedBy, "");
    assert.equal(nextApproval.instanceId, "tom");
    assert(backups.some((name) => name.endsWith("live-healthcheck-approval.json")));
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

test("live healthcheck approval check rejects approved records without packet binding", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-live-approval-unbound-"));
  try {
    const { deployDir, approvalFile } = await prepareApprovalFile(dir);
    const logFile = join(dir, "packet.log");
    const packetScript = join(dir, "approval-packet.sh");
    await writeReadyPacketScript(packetScript, logFile);
    const approval = JSON.parse(await readFile(approvalFile, "utf8"));
    approval.approved = true;
    approval.approvedAt = new Date().toISOString();
    approval.approvedBy = "Anan";
    approval.checklist = {
      understandsTemporaryLiveGate: true,
      understandsLocalTokenRequired: true,
      understandsAutoRollback: true,
      understandsImpactSnapshot: true,
    };
    delete approval.approvalPacket;
    await writeFile(approvalFile, `${JSON.stringify(approval, null, 2)}\n`, "utf8");

    const result = spawnSync(SCRIPT, ["check", approvalFile], {
      env: {
        ...process.env,
        DEPLOY_DIR: deployDir,
        APPROVAL_PACKET_SCRIPT: packetScript,
        APPROVAL_PACKET_FILE: join(dir, "packet.json"),
        INSTANCE_ID: "tom",
        OPERATOR: "Anan",
      },
      encoding: "utf8",
    });

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /approvalPacket 必须记录本次批准绑定的证据包/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
