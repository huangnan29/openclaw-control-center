import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import os from "node:os";
import test from "node:test";

const ROOT = process.cwd();
const TSX_BIN = path.join(ROOT, "node_modules", ".bin", "tsx");
const MACOS_HOME_PATH_PATTERN = /\/Users\/[^/\s]+\//;
const EMBEDDED_LOCAL_TOKEN_PATTERN = /LOCAL_API_TOKEN\s*[:=]\s*["'][^"']{8,}["']/;
const PUBLIC_FILES = [
  "README.md",
  "docs/ARCHITECTURE.md",
  "docs/PROGRESS.md",
  "docs/mission-control-runbook-v2.md",
  "ecosystem.config.cjs",
  "scripts/run_verifier.sh",
  "scripts/mc_dod_evaluator.py",
  "scripts/mc_rollback_plan.py",
];

test("repo includes baseline open-source release metadata", () => {
  assert(existsSync(path.join(ROOT, ".gitignore")), "Expected .gitignore to exist.");
  assert(existsSync(path.join(ROOT, "LICENSE")), "Expected LICENSE to exist.");

  const ignore = readFileSync(path.join(ROOT, ".gitignore"), "utf8");
  assert.match(ignore, /(^|\r?\n)node_modules\/(\r?\n|$)/);
  assert.match(ignore, /(^|\r?\n)dist\/(\r?\n|$)/);
  assert.match(ignore, /(^|\r?\n)\/?runtime\/(\r?\n|$)/);

  const license = readFileSync(path.join(ROOT, "LICENSE"), "utf8");
  assert.match(license, /MIT License/);

  const pkg = JSON.parse(readFileSync(path.join(ROOT, "package.json"), "utf8"));
  assert.notEqual(pkg.private, true);
  assert.equal(pkg.license, "MIT");
});

test("public-facing files do not embed machine-specific paths or local token values", () => {
  for (const relativePath of PUBLIC_FILES) {
    const content = readFileSync(path.join(ROOT, relativePath), "utf8");
    assert.equal(MACOS_HOME_PATH_PATTERN.test(content), false, `${relativePath} still contains a macOS home path.`);
    assert.equal(
      EMBEDDED_LOCAL_TOKEN_PATTERN.test(content),
      false,
      `${relativePath} still contains an embedded LOCAL_API_TOKEN value.`,
    );
  }
});

test("gateway URL can be overridden from env for non-local installations", () => {
  const output = execFileSync(
    process.execPath,
    [
      "--import",
      "tsx",
      "--eval",
      "process.env.GATEWAY_URL='ws://example.invalid:9999'; const mod = require('./src/config.ts'); process.stdout.write(String(mod.GATEWAY_URL));",
    ],
    {
      cwd: ROOT,
      encoding: "utf8",
    },
  ).trim();

  assert.equal(output, "ws://example.invalid:9999");
});

test("config loads LOCAL_API_TOKEN from cwd .env when env is not preloaded", () => {
  const tempDir = mkdtempSync(path.join(os.tmpdir(), "openclaw-config-env-"));
  try {
    const localTokenKey = ["LOCAL", "API", "TOKEN"].join("_");
    writeFileSync(path.join(tempDir, ".env"), `${localTokenKey}=from-dotenv\n`, "utf8");
    const output = execFileSync(
      TSX_BIN,
      [
        "--eval",
        `delete process.env.LOCAL_API_TOKEN; const mod = require(${JSON.stringify(path.join(ROOT, "src", "config.ts"))}); process.stdout.write(mod.LOCAL_API_TOKEN);`,
      ],
      {
        cwd: tempDir,
        encoding: "utf8",
      },
    ).trim();

    assert.equal(output, "from-dotenv");
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});

test("config keeps defaults when cwd .env is absent", () => {
  const tempDir = mkdtempSync(path.join(os.tmpdir(), "openclaw-config-no-env-"));
  try {
    const output = execFileSync(
      TSX_BIN,
      [
        "--eval",
        `delete process.env.LOCAL_API_TOKEN; delete process.env.GATEWAY_URL; const mod = require(${JSON.stringify(path.join(ROOT, "src", "config.ts"))}); process.stdout.write(JSON.stringify({ token: mod.LOCAL_API_TOKEN, gateway: mod.GATEWAY_URL }));`,
      ],
      {
        cwd: tempDir,
        encoding: "utf8",
      },
    ).trim();

    assert.deepEqual(JSON.parse(output), {
      token: "",
      gateway: "ws://127.0.0.1:18789",
    });
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});

test("core source directories are present and tracked in git", () => {
  assert(existsSync(path.join(ROOT, "src", "ui", "server.ts")), "Expected src/ui/server.ts to exist.");
  assert(existsSync(path.join(ROOT, "src", "runtime", "usage-cost.ts")), "Expected src/runtime/usage-cost.ts to exist.");

  const tracked = execFileSync("git", ["ls-files", "src/ui/server.ts", "src/runtime/usage-cost.ts"], {
    cwd: ROOT,
    encoding: "utf8",
  })
    .trim()
    .split("\n")
    .filter(Boolean);

  assert.deepEqual(tracked.sort(), ["src/runtime/usage-cost.ts", "src/ui/server.ts"]);
});

test("multi-instance readonly docs describe safe Oracle deployment", async () => {
  const doc = readFileSync(path.join(ROOT, "docs", "MULTI_INSTANCE_READONLY.md"), "utf8");
  const compose = readFileSync(path.join(ROOT, "docker-compose.example.yml"), "utf8");
  const env = readFileSync(path.join(ROOT, ".env.example"), "utf8");
  const healthcheck = readFileSync(path.join(ROOT, "ops", "tom-readonly", "healthcheck.sh"), "utf8");
  const cron = path.join(ROOT, "ops", "tom-readonly", "install-collector-cron.sh");
  const liveHealthcheckPreflight = path.join(ROOT, "ops", "tom-readonly", "live-healthcheck-preflight.sh");
  const liveHealthcheckSmoke = path.join(ROOT, "ops", "tom-readonly", "live-healthcheck-smoke.sh");
  const liveHealthcheckWindow = path.join(ROOT, "ops", "tom-readonly", "live-healthcheck-window.sh");
  const liveHealthcheckRollout = path.join(ROOT, "ops", "tom-readonly", "managed-action-healthcheck-rollout.example.json");

  assert(doc.includes("OPENCLAW_INSTANCES_FILE"));
  assert(doc.includes("\"servers\""));
  assert(doc.includes("serverId"));
  assert(doc.includes("collectorSnapshotPath"));
  assert(doc.includes("collector:snapshot"));
  assert(doc.includes("install-collector-cron.sh"));
  assert(doc.includes("服务器健康"));
  assert(doc.includes("/srv/openclaw-work"));
  assert(doc.includes(":ro"));
  assert(doc.includes("不挂载 /var/run/docker.sock"));
  assert(existsSync(path.join(ROOT, "ops", "tom-readonly", "collector-snapshot.sh")));
  assert(existsSync(cron));
  assert(existsSync(liveHealthcheckPreflight));
  assert(existsSync(liveHealthcheckSmoke));
  assert(existsSync(liveHealthcheckWindow));
  assert(existsSync(liveHealthcheckRollout));
  assert.match(readFileSync(cron, "utf8"), /OPENCLAW_COLLECTOR_CRON_BEGIN/);
  const preflightText = readFileSync(liveHealthcheckPreflight, "utf8");
  assert.match(preflightText, /api\/managed-actions\/readiness/);
  assert.doesNotMatch(preflightText, /api\/managed-actions\/live/);
  assert.match(preflightText, /MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED/);
  assert.match(preflightText, /check_rollout_file\(\)[\s\S]*-e INSTANCE_ID=/);
  assert.match(preflightText, /check_rollout_file\(\)[\s\S]*-e OPERATOR=/);
  assert.match(preflightText, /managed-action-healthcheck-rollout\.example\.json/);
  assert.match(readFileSync(liveHealthcheckSmoke, "utf8"), /CONFIRM_LIVE_HEALTHCHECK/);
  assert.match(readFileSync(liveHealthcheckSmoke, "utf8"), /LIVE-ACTION-APPROVED/);
  assert.match(readFileSync(liveHealthcheckSmoke, "utf8"), /DRY-RUN-ONLY/);
  assert.match(readFileSync(liveHealthcheckSmoke, "utf8"), /set \+x/);
  const liveWindowText = readFileSync(liveHealthcheckWindow, "utf8");
  assert.match(liveWindowText, /CONFIRM_LIVE_HEALTHCHECK_WINDOW/);
  assert.match(liveWindowText, /I_UNDERSTAND_THIS_TEMPORARILY_ENABLES_LIVE_GATE/);
  assert.match(liveWindowText, /MANAGED_ACTIONS_LIVE_ALLOWED_ACTIONS: "healthcheck"/);
  assert.match(liveWindowText, /trap rollback_on_exit EXIT/);
  assert.match(liveWindowText, /stop_live_window/);
  assert.match(readFileSync(liveHealthcheckRollout, "utf8"), /"action": "healthcheck"/);
  assert.match(readFileSync(liveHealthcheckRollout, "utf8"), /"risk": "low"/);
  assert(healthcheck.includes("COLLECTOR_SNAPSHOT_MAX_AGE_SECONDS"));
  assert(compose.includes("OPENCLAW_INSTANCES_FILE"));
  assert(env.includes("OPENCLAW_INSTANCES_JSON"));
  assert(env.includes("servers"));
  assert(env.includes("collectorSnapshotPath"));
  assert(env.includes("OPENCLAW_COLLECTOR_CRON_SCHEDULE"));
});
