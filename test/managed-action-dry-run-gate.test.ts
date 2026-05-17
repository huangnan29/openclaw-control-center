import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "tom-readonly", "managed-action-dry-run-gate.sh");
const CONFIRM = "I_UNDERSTAND_THIS_ONLY_CREATES_DRY_RUN_AUDIT_RECORD";

async function writeFakeCurl(dir: string, options: { hasAudit?: boolean } = {}) {
  const fakeBin = join(dir, "bin");
  const callsFile = join(dir, "curl-calls.txt");
  await mkdir(fakeBin, { recursive: true });
  const fakeCurl = join(fakeBin, "curl");
  const hasAudit = options.hasAudit !== false;
  await writeFile(
    fakeCurl,
    `#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$FAKE_CURL_CALLS"
if printf '%s\\n' "$*" | grep -q '/api/managed-actions/dry-run'; then
  cat <<'JSON'
{"ok":true,"status":"dry_run_ready","dryRun":true,"liveExecution":false,"action":"healthcheck","review":{"operationRequestId":"dry-run-new","confirmationTextMatched":true},"safety":{"mutatesOpenClawInstance":false}}
JSON
  exit 0
fi
if printf '%s\\n' "$*" | grep -q '/api/managed-actions/readiness'; then
  cat <<'JSON'
{"ok":true,"status":"blocked","liveExecutionAvailable":false,"dryRun":{"auditPath":"/app/runtime/operation-audit.log","count":1,"latest":{"operationRequestId":"dry-run-1","action":"healthcheck","targetInstanceId":"tom","operator":"Anan"},"referenceMaxAgeMs":86400000}}
JSON
  exit 0
fi
if printf '%s\\n' "$*" | grep -q '/api/managed-actions/audit'; then
  if [ "${hasAudit ? "1" : "0"}" = "1" ]; then
    cat <<'JSON'
{"ok":true,"path":"/app/runtime/operation-audit.log","count":1,"records":[{"timestamp":"2099-01-01T00:00:00.000Z","operationRequestId":"dry-run-1","source":"api","ok":true,"action":"healthcheck","detail":"previewed healthcheck for tom","targetInstanceId":"tom","targetInstanceName":"Tom","operator":"Anan","reason":"test","confirmationTextMatched":true,"mutatesOpenClawInstance":false,"commandPreview":["control-center healthcheck for instance tom"]}]}
JSON
  else
    cat <<'JSON'
{"ok":true,"path":"/app/runtime/operation-audit.log","count":0,"records":[]}
JSON
  fi
  exit 0
fi
echo "unexpected curl call" >&2
exit 2
`,
    "utf8",
  );
  await chmod(fakeCurl, 0o755);
  return { fakeBin, callsFile };
}

test("managed action dry-run gate reports ready when a valid audit exists", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-dry-run-gate-"));
  try {
    const { fakeBin, callsFile } = await writeFakeCurl(dir);
    const output = execFileSync(SCRIPT, ["status"], {
      env: {
        ...process.env,
        PATH: `${fakeBin}${delimiter}${process.env.PATH ?? ""}`,
        FAKE_CURL_CALLS: callsFile,
      },
      encoding: "utf8",
    });
    const report = JSON.parse(output);
    const calls = await readFile(callsFile, "utf8");

    assert.equal(report.status, "ready");
    assert.equal(report.audit.latest.operationRequestId, "dry-run-1");
    assert(report.nextCommands.some((command: string) => command.includes("live-healthcheck-approval-packet.sh generate")));
    assert(report.nextCommands.some((command: string) => command.includes("live-healthcheck-approval-packet.sh check")));
    assert(report.nextCommands.some((command: string) => command.includes("live-healthcheck-approval.sh approve")));
    assert.equal(report.safety.callsManagedActionsLiveApi, false);
    assert.doesNotMatch(calls, /managed-actions\/live/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("managed action dry-run gate blocks run mode without confirmation and token", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-dry-run-gate-"));
  try {
    const { fakeBin, callsFile } = await writeFakeCurl(dir, { hasAudit: false });
    const result = spawnSync(SCRIPT, ["run"], {
      env: {
        ...process.env,
        PATH: `${fakeBin}${delimiter}${process.env.PATH ?? ""}`,
        FAKE_CURL_CALLS: callsFile,
      },
      encoding: "utf8",
    });

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /CONFIRM_MANAGED_ACTION_DRY_RUN/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("managed action dry-run gate run creates only a dry-run audit request", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-dry-run-gate-"));
  try {
    const { fakeBin, callsFile } = await writeFakeCurl(dir);
    const output = execFileSync(SCRIPT, ["run"], {
      env: {
        ...process.env,
        PATH: `${fakeBin}${delimiter}${process.env.PATH ?? ""}`,
        FAKE_CURL_CALLS: callsFile,
        LOCAL_API_TOKEN: "test-token",
        CONFIRM_MANAGED_ACTION_DRY_RUN: CONFIRM,
      },
      encoding: "utf8",
    });
    const report = JSON.parse(output);
    const calls = await readFile(callsFile, "utf8");

    assert.equal(report.status, "ready");
    assert.equal(report.runResult.status, "dry_run_ready");
    assert.equal(report.safety.createsDryRunAuditOnly, true);
    assert.match(calls, /api\/managed-actions\/dry-run/);
    assert.doesNotMatch(calls, /api\/managed-actions\/live/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
