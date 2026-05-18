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
  const instanceImpactSnapshot = path.join(ROOT, "ops", "tom-readonly", "instance-impact-snapshot.sh");
  const liveHealthcheckApproval = path.join(ROOT, "ops", "tom-readonly", "live-healthcheck-approval.sh");
  const liveHealthcheckApprovalExample = path.join(ROOT, "ops", "tom-readonly", "live-healthcheck-approval.example.json");
  const liveHealthcheckApprovalPacket = path.join(ROOT, "ops", "tom-readonly", "live-healthcheck-approval-packet.sh");
  const liveHealthcheckApprovalReview = path.join(ROOT, "ops", "tom-readonly", "live-healthcheck-approval-review.sh");
  const liveHealthcheckPreflight = path.join(ROOT, "ops", "tom-readonly", "live-healthcheck-preflight.sh");
  const liveHealthcheckReadiness = path.join(ROOT, "ops", "tom-readonly", "live-healthcheck-readiness.sh");
  const liveHealthcheckReport = path.join(ROOT, "ops", "tom-readonly", "live-healthcheck-report.sh");
  const liveHealthcheckRolloutRunner = path.join(ROOT, "ops", "tom-readonly", "live-healthcheck-rollout-runner.sh");
  const liveHealthcheckSmoke = path.join(ROOT, "ops", "tom-readonly", "live-healthcheck-smoke.sh");
  const liveHealthcheckWindow = path.join(ROOT, "ops", "tom-readonly", "live-healthcheck-window.sh");
  const liveHealthcheckRollout = path.join(ROOT, "ops", "tom-readonly", "managed-action-healthcheck-rollout.example.json");
  const managedActionCommandRunner = path.join(ROOT, "ops", "tom-readonly", "managed-action-command-runner.sh");
  const managedActionTextBridge = path.join(ROOT, "ops", "tom-readonly", "managed-action-text-bridge.sh");
  const managedActionInboxRunner = path.join(ROOT, "ops", "tom-readonly", "managed-action-inbox-runner.sh");
  const managedActionInboxCronInstaller = path.join(ROOT, "ops", "tom-readonly", "install-managed-action-inbox-cron.sh");
  const heartbeatBurnAlertRunner = path.join(ROOT, "ops", "tom-readonly", "heartbeat-burn-alert-runner.sh");
  const heartbeatBurnAlertCronInstaller = path.join(ROOT, "ops", "tom-readonly", "install-heartbeat-burn-alert-cron.sh");
  const managedActionAgentsInstaller = path.join(ROOT, "ops", "tom-readonly", "install-managed-action-agents-instructions.sh");
  const managedActionDryRunGate = path.join(ROOT, "ops", "tom-readonly", "managed-action-dry-run-gate.sh");
  const discoverRemoteOracleCredentials = path.join(ROOT, "ops", "local", "discover-remote-oracle-credentials.sh");
  const discoverRemoteOracleCredentialsExample = path.join(ROOT, "ops", "local", "discover-remote-oracle-credentials.example.json");
  const remoteOracleIntake = path.join(ROOT, "ops", "local", "remote-oracle-intake.sh");
  const finalGoLiveStatus = path.join(ROOT, "ops", "local", "final-go-live-status.sh");
  const finalGoLiveRunner = path.join(ROOT, "ops", "local", "final-go-live-runner.sh");
  const finalGoLiveReview = path.join(ROOT, "ops", "local", "final-go-live-review.sh");
  const finalGoLiveCompletionAudit = path.join(ROOT, "ops", "local", "final-go-live-completion-audit.sh");
  const remoteCollectorOnboarding = path.join(ROOT, "ops", "tom-readonly", "remote-collector-onboarding.sh");
  const remoteCollectorOnboardingExample = path.join(ROOT, "ops", "tom-readonly", "remote-collector-onboarding.example.json");
  const remoteCollectorCredentials = path.join(ROOT, "ops", "tom-readonly", "remote-collector-credentials.sh");
  const remoteCollectorCredentialsExample = path.join(ROOT, "ops", "tom-readonly", "remote-collector-credentials.example.json");
  const pushRemoteCollectorCredentials = path.join(ROOT, "ops", "local", "push-remote-collector-credentials.sh");
  const pushRemoteCollectorCredentialsExample = path.join(ROOT, "ops", "local", "push-remote-collector-credentials.example.json");
  const remoteCollectorPreflight = path.join(ROOT, "ops", "tom-readonly", "remote-collector-preflight.sh");
  const remoteCollectorNodeSync = path.join(ROOT, "ops", "tom-readonly", "remote-collector-node-sync.sh");
  const remoteCollectorRollout = path.join(ROOT, "ops", "tom-readonly", "remote-collector-rollout.sh");
  const remoteCollectorRolloutRunner = path.join(ROOT, "ops", "tom-readonly", "remote-collector-rollout-runner.sh");
  const goLiveGate = path.join(ROOT, "ops", "tom-readonly", "go-live-gate.sh");
  const remoteCollectorPull = path.join(ROOT, "ops", "tom-readonly", "remote-collector-pull.sh");
  const remoteCollectorPullExample = path.join(ROOT, "ops", "tom-readonly", "remote-collector-pull.sources.example.json");
  const registerLocalInstance = path.join(ROOT, "ops", "tom-readonly", "register-local-instance.sh");
  const registerLocalInstanceExample = path.join(ROOT, "ops", "tom-readonly", "register-local-instance.example.json");
  const registerRemoteCollector = path.join(ROOT, "ops", "tom-readonly", "register-remote-collector.sh");
  const registerRemoteCollectorExample = path.join(ROOT, "ops", "tom-readonly", "register-remote-collector.example.json");
  const collectorNodeBootstrap = path.join(ROOT, "ops", "collector-node", "bootstrap-collector-node.sh");
  const collectorNodeExample = path.join(ROOT, "ops", "collector-node", "collector-node.example.json");

  assert(doc.includes("OPENCLAW_INSTANCES_FILE"));
  assert(doc.includes("\"servers\""));
  assert(doc.includes("serverId"));
  assert(doc.includes("collectorSnapshotPath"));
  assert(doc.includes("collector:snapshot"));
  assert(doc.includes("bootstrap-collector-node.sh"));
  assert(doc.includes("I_UNDERSTAND_THIS_ONLY_WRITES_COLLECTOR_NODE_FILES"));
  assert(doc.includes("remote-collector-onboarding.sh"));
  assert(doc.includes("push-remote-collector-credentials.sh"));
  assert(doc.includes("discover-remote-oracle-credentials.sh"));
  assert(doc.includes("remote-oracle-intake.sh"));
  assert(doc.includes("final-go-live-status.sh"));
  assert(doc.includes("final-go-live-review.sh"));
  assert(doc.includes("final-go-live-completion-audit.sh"));
  assert(doc.includes("render-push-config"));
  assert(doc.includes("I_UNDERSTAND_THIS_WRITES_LOCAL_PUSH_CONFIG_AND_TOM_RUNTIME_ONLY"));
  assert(doc.includes("I_UNDERSTAND_THIS_PUSHES_CREDENTIALS_AND_RUNS_TOM_SAFE_ROLLOUT"));
  assert(doc.includes("I_UNDERSTAND_THIS_ONLY_PROBES_SSH_READONLY"));
  assert(doc.includes("I_UNDERSTAND_THIS_ONLY_PUSHES_REMOTE_COLLECTOR_CREDENTIALS_TO_TOM_RUNTIME"));
  assert(doc.includes("remote-collector-credentials.sh"));
  assert(doc.includes("I_UNDERSTAND_THIS_ONLY_WRITES_CONTROL_CENTER_REMOTE_CREDENTIALS"));
  assert(doc.includes("I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_ONBOARDING_BUNDLE"));
  assert(doc.includes("remote-collector-preflight.sh"));
  assert(doc.includes("remote-collector-node-sync.sh"));
  assert(doc.includes("I_UNDERSTAND_THIS_ONLY_COPIES_COLLECTOR_BUNDLE_TO_REMOTE"));
  assert(doc.includes("I_UNDERSTAND_THIS_ONLY_RUNS_REMOTE_BOOTSTRAP_PLAN"));
  assert(doc.includes("I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_COLLECTOR_NODE_FILES"));
  assert(doc.includes("I_UNDERSTAND_THIS_RUNS_REMOTE_COLLECTOR_SNAPSHOT_ONLY"));
  assert(doc.includes("I_UNDERSTAND_THIS_ONLY_INSTALLS_REMOTE_COLLECTOR_CRON"));
  assert(doc.includes("remote-collector-rollout.sh"));
  assert(doc.includes("I_UNDERSTAND_THIS_ONLY_READS_REMOTE_PREREQUISITES"));
  assert(doc.includes("remote-collector-pull.sh"));
  assert(doc.includes("I_UNDERSTAND_THIS_ONLY_READS_REMOTE_COLLECTOR_SNAPSHOTS"));
  assert(doc.includes("register-local-instance.sh"));
  assert(doc.includes("I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_LOCAL_REGISTRY"));
  assert(doc.includes("register-remote-collector.sh"));
  assert(doc.includes("I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_REGISTRY"));
  assert(doc.includes("live-healthcheck-approval-packet.sh"));
  assert(doc.includes("live-healthcheck-approval-review.sh"));
  assert(doc.includes("live-healthcheck-approval-packets"));
  assert(doc.includes("install-collector-cron.sh"));
  assert(doc.includes("install-managed-action-inbox-cron.sh"));
  assert(doc.includes("install-heartbeat-burn-alert-cron.sh"));
  assert(doc.includes("服务器健康"));
  assert(doc.includes("/srv/openclaw-work"));
  assert(doc.includes(":ro"));
  assert(doc.includes("不挂载 /var/run/docker.sock"));
  assert(existsSync(path.join(ROOT, "ops", "tom-readonly", "collector-snapshot.sh")));
  assert(existsSync(cron));
  assert(existsSync(instanceImpactSnapshot));
  assert(existsSync(liveHealthcheckApproval));
  assert(existsSync(liveHealthcheckApprovalExample));
  assert(existsSync(liveHealthcheckApprovalPacket));
  assert(existsSync(liveHealthcheckApprovalReview));
  assert(existsSync(liveHealthcheckPreflight));
  assert(existsSync(liveHealthcheckReadiness));
  assert(existsSync(liveHealthcheckReport));
  assert(existsSync(liveHealthcheckRolloutRunner));
  assert(existsSync(liveHealthcheckSmoke));
  assert(existsSync(liveHealthcheckWindow));
  assert(existsSync(liveHealthcheckRollout));
  assert(existsSync(managedActionTextBridge));
  assert(existsSync(managedActionInboxRunner));
  assert(existsSync(managedActionInboxCronInstaller));
  assert(existsSync(heartbeatBurnAlertRunner));
  assert(existsSync(heartbeatBurnAlertCronInstaller));
  assert(existsSync(managedActionAgentsInstaller));
  assert(existsSync(managedActionDryRunGate));
  assert(existsSync(discoverRemoteOracleCredentials));
  assert(existsSync(discoverRemoteOracleCredentialsExample));
  assert(existsSync(remoteOracleIntake));
  assert(existsSync(finalGoLiveStatus));
  assert(existsSync(finalGoLiveReview));
  assert(existsSync(finalGoLiveCompletionAudit));
  assert(existsSync(remoteCollectorOnboarding));
  assert(existsSync(remoteCollectorOnboardingExample));
  assert(existsSync(remoteCollectorCredentials));
  assert(existsSync(remoteCollectorCredentialsExample));
  assert(existsSync(pushRemoteCollectorCredentials));
  assert(existsSync(pushRemoteCollectorCredentialsExample));
  assert(existsSync(remoteCollectorPreflight));
  assert(existsSync(remoteCollectorNodeSync));
  assert(existsSync(remoteCollectorRollout));
  assert(existsSync(remoteCollectorRolloutRunner));
  assert(existsSync(goLiveGate));
  assert(existsSync(remoteCollectorPull));
  assert(existsSync(remoteCollectorPullExample));
  assert(existsSync(registerLocalInstance));
  assert(existsSync(registerLocalInstanceExample));
  assert(existsSync(registerRemoteCollector));
  assert(existsSync(registerRemoteCollectorExample));
  assert(existsSync(collectorNodeBootstrap));
  assert(existsSync(collectorNodeExample));
  const collectorNodeBootstrapText = readFileSync(collectorNodeBootstrap, "utf8");
  assert.match(collectorNodeBootstrapText, /CONFIRM_COLLECTOR_NODE_WRITE/);
  assert.match(collectorNodeBootstrapText, /I_UNDERSTAND_THIS_ONLY_WRITES_COLLECTOR_NODE_FILES/);
  assert.match(collectorNodeBootstrapText, /startsContainers: false/);
  assert.match(collectorNodeBootstrapText, /mutatesOpenClawInstance: false/);
  assert.doesNotMatch(collectorNodeBootstrapText, /api\/managed-actions\/live/);
  const collectorNodeConfig = JSON.parse(readFileSync(collectorNodeExample, "utf8"));
  assert.equal(collectorNodeConfig.server.id, "remote-oracle");
  const remoteCollectorOnboardingText = readFileSync(remoteCollectorOnboarding, "utf8");
  assert.match(remoteCollectorOnboardingText, /CONFIRM_REMOTE_COLLECTOR_ONBOARDING/);
  assert.match(remoteCollectorOnboardingText, /verify <bundle-dir>/);
  assert.match(remoteCollectorOnboardingText, /I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_ONBOARDING_BUNDLE/);
  assert.match(remoteCollectorOnboardingText, /bundleBuildContext/);
  assert.match(remoteCollectorOnboardingText, /build-context-manifest\.json/);
  assert.match(remoteCollectorOnboardingText, /bootstrapStartsContainers: false/);
  assert.match(remoteCollectorOnboardingText, /writesActiveRegistry: false/);
  assert.match(remoteCollectorOnboardingText, /connectsSsh: false/);
  assert.match(remoteCollectorOnboardingText, /mutatesOpenClawInstance: false/);
  assert.match(remoteCollectorOnboardingText, /callsLiveApi: false/);
  assert.doesNotMatch(remoteCollectorOnboardingText, /api\/managed-actions\/live/);
  const remoteCollectorOnboardingConfig = JSON.parse(readFileSync(remoteCollectorOnboardingExample, "utf8"));
  assert.equal(remoteCollectorOnboardingConfig.server.id, "remote-oracle");
  assert.equal(remoteCollectorOnboardingConfig.collectorNode.bundleBuildContext, true);
  const remoteCollectorCredentialsText = readFileSync(remoteCollectorCredentials, "utf8");
  assert.match(remoteCollectorCredentialsText, /CONFIRM_REMOTE_COLLECTOR_CREDENTIALS/);
  assert.match(remoteCollectorCredentialsText, /I_UNDERSTAND_THIS_ONLY_WRITES_CONTROL_CENTER_REMOTE_CREDENTIALS/);
  assert.match(remoteCollectorCredentialsText, /writesControlCenterRuntimeOnly/);
  assert.match(remoteCollectorCredentialsText, /connectsSsh: false/);
  assert.match(remoteCollectorCredentialsText, /writesRemoteFiles: false/);
  assert.match(remoteCollectorCredentialsText, /writesActiveRegistry: false/);
  assert.match(remoteCollectorCredentialsText, /mutatesOpenClawInstance: false/);
  assert.match(remoteCollectorCredentialsText, /callsLiveApi: false/);
  assert.doesNotMatch(remoteCollectorCredentialsText, /api\/managed-actions\/live/);
  const remoteCollectorCredentialsConfig = JSON.parse(readFileSync(remoteCollectorCredentialsExample, "utf8"));
  assert.equal(remoteCollectorCredentialsConfig.server.id, "remote-oracle");
  assert.equal(remoteCollectorCredentialsConfig.overwrite, false);
  const discoverRemoteOracleCredentialsText = readFileSync(discoverRemoteOracleCredentials, "utf8");
  assert.match(discoverRemoteOracleCredentialsText, /CONFIRM_REMOTE_ORACLE_DISCOVERY/);
  assert.match(discoverRemoteOracleCredentialsText, /I_UNDERSTAND_THIS_ONLY_PROBES_SSH_READONLY/);
  assert.match(discoverRemoteOracleCredentialsText, /render-push-config/);
  assert.match(discoverRemoteOracleCredentialsText, /write-push-config/);
  assert.match(discoverRemoteOracleCredentialsText, /CONFIRM_REMOTE_ORACLE_PUSH_CONFIG_WRITE/);
  assert.match(discoverRemoteOracleCredentialsText, /I_UNDERSTAND_THIS_ONLY_WRITES_LOCAL_PUSH_CONFIG/);
  assert.match(discoverRemoteOracleCredentialsText, /writesLocalPushConfigOnly/);
  assert.match(discoverRemoteOracleCredentialsText, /outputsPrivateKeyContent: false/);
  assert.match(discoverRemoteOracleCredentialsText, /writesTomRuntime: false/);
  assert.match(discoverRemoteOracleCredentialsText, /writesRemoteFiles: false/);
  assert.match(discoverRemoteOracleCredentialsText, /mutatesOpenClawInstance: false/);
  assert.match(discoverRemoteOracleCredentialsText, /callsLiveApi: false/);
  assert.doesNotMatch(discoverRemoteOracleCredentialsText, /api\/managed-actions\/live/);
  const discoverRemoteOracleCredentialsConfig = JSON.parse(readFileSync(discoverRemoteOracleCredentialsExample, "utf8"));
  assert.equal(discoverRemoteOracleCredentialsConfig.tom.host, "146.235.226.66");
  const remoteOracleIntakeText = readFileSync(remoteOracleIntake, "utf8");
  assert.match(remoteOracleIntakeText, /remote-oracle-intake\.sh plan/);
  assert.match(remoteOracleIntakeText, /remote-oracle-intake\.sh apply/);
  assert.match(remoteOracleIntakeText, /remote-oracle-intake\.sh run/);
  assert.match(remoteOracleIntakeText, /remote-oracle-intake\.sh doctor/);
  assert.match(remoteOracleIntakeText, /doctor 不写文件、不联网/);
  assert.match(remoteOracleIntakeText, /CONFIRM_REMOTE_ORACLE_INTAKE/);
  assert.match(remoteOracleIntakeText, /CONFIRM_REMOTE_ORACLE_INTAKE_RUNNER/);
  assert.match(remoteOracleIntakeText, /I_UNDERSTAND_THIS_WRITES_LOCAL_PUSH_CONFIG_AND_TOM_RUNTIME_ONLY/);
  assert.match(remoteOracleIntakeText, /I_UNDERSTAND_THIS_PUSHES_CREDENTIALS_AND_RUNS_TOM_SAFE_ROLLOUT/);
  assert.match(remoteOracleIntakeText, /writesTomControlCenterRuntimeOnly/);
  assert.match(remoteOracleIntakeText, /readsLocalSshConfigOnly/);
  assert.match(remoteOracleIntakeText, /mayConnectSecondOracleViaTomReadonlyPreflight/);
  assert.match(remoteOracleIntakeText, /writesActiveRegistry: false/);
  assert.match(remoteOracleIntakeText, /writesOpenClawInstanceDirs: false/);
  assert.match(remoteOracleIntakeText, /mutatesOpenClawInstance: false/);
  assert.match(remoteOracleIntakeText, /callsLiveApi: false/);
  assert.doesNotMatch(remoteOracleIntakeText, /api\/managed-actions\/live/);
  const finalGoLiveStatusText = readFileSync(finalGoLiveStatus, "utf8");
  assert.match(finalGoLiveStatusText, /final-go-live-status\.sh status/);
  assert.match(finalGoLiveStatusText, /final-go-live-status\.sh check/);
  assert.match(finalGoLiveStatusText, /OPENCLAW_TOPOLOGY_MODE/);
  assert.match(finalGoLiveStatusText, /skipped_local_only/);
  assert.match(finalGoLiveStatusText, /crossServerRequired/);
  assert.match(finalGoLiveStatusText, /remote-oracle-intake\.sh doctor/);
  assert.match(finalGoLiveStatusText, /go-live-gate\.sh/);
  assert.match(finalGoLiveStatusText, /writesTomRuntime: false/);
  assert.match(finalGoLiveStatusText, /connectsSecondOracle: false/);
  assert.match(finalGoLiveStatusText, /writesOpenClawInstanceDirs: false/);
  assert.match(finalGoLiveStatusText, /callsManagedActionsLiveApi: false/);
  assert.doesNotMatch(finalGoLiveStatusText, /api\/managed-actions\/live/);
  const finalGoLiveRunnerText = readFileSync(finalGoLiveRunner, "utf8");
  assert.match(finalGoLiveRunnerText, /final-go-live-runner\.sh status/);
  assert.match(finalGoLiveRunnerText, /final-go-live-runner\.sh prepare/);
  assert.match(finalGoLiveRunnerText, /final-go-live-runner\.sh run-approved/);
  assert.match(finalGoLiveRunnerText, /final-go-live-runner\.sh approve-and-run/);
  assert.match(finalGoLiveRunnerText, /final-go-live-runner\.sh verify-completed/);
  assert.match(finalGoLiveRunnerText, /final-go-live-status\.sh check/);
  assert.match(finalGoLiveRunnerText, /live-healthcheck-rollout-runner\.sh prepare/);
  assert.match(finalGoLiveRunnerText, /live-healthcheck-approval-review\.sh check/);
  assert.match(finalGoLiveRunnerText, /live-healthcheck-approval\.sh approve/);
  assert.match(finalGoLiveRunnerText, /CONFIRM_FINAL_GO_LIVE_RUNNER/);
  assert.match(finalGoLiveRunnerText, /CONFIRM_FINAL_GO_LIVE_APPROVE_AND_RUN/);
  assert.match(finalGoLiveRunnerText, /I_UNDERSTAND_THIS_RUNS_APPROVED_FINAL_GO_LIVE/);
  assert.match(finalGoLiveRunnerText, /I_APPROVE_AND_RUN_FINAL_LIVE_HEALTHCHECK/);
  assert.match(finalGoLiveRunnerText, /requiresPostLiveVerification/);
  assert.match(finalGoLiveRunnerText, /approvesLiveHealthcheck: false/);
  assert.match(finalGoLiveRunnerText, /writesOpenClawInstanceDirs: false/);
  const finalGoLiveReviewText = readFileSync(finalGoLiveReview, "utf8");
  assert.match(finalGoLiveReviewText, /final-go-live-review\.sh status/);
  assert.match(finalGoLiveReviewText, /live-healthcheck-readiness\.sh status/);
  assert.match(finalGoLiveReviewText, /install-managed-action-inbox-cron\.sh status/);
  assert.match(finalGoLiveReviewText, /install-heartbeat-burn-alert-cron\.sh status/);
  assert.match(finalGoLiveReviewText, /heartbeat-burn-alert-runner\.sh status/);
  assert.match(finalGoLiveReviewText, /ready_for_human_approval_with_usage_alerts/);
  assert.match(finalGoLiveReviewText, /writesTomRuntime: false/);
  assert.match(finalGoLiveReviewText, /writesApprovalFile: false/);
  assert.match(finalGoLiveReviewText, /opensLiveGate: false/);
  assert.match(finalGoLiveReviewText, /callsManagedActionsLiveApi: false/);
  assert.match(finalGoLiveReviewText, /writesOpenClawInstanceDirs: false/);
  assert.doesNotMatch(finalGoLiveReviewText, /api\/managed-actions\/live/);
  const finalGoLiveCompletionAuditText = readFileSync(finalGoLiveCompletionAudit, "utf8");
  assert.match(finalGoLiveCompletionAuditText, /final-go-live-completion-audit\.sh status/);
  assert.match(finalGoLiveCompletionAuditText, /final-go-live-review\.sh/);
  assert.match(finalGoLiveCompletionAuditText, /\.\/healthcheck\.sh/);
  assert.match(finalGoLiveCompletionAuditText, /blocked_human_approval_required/);
  assert.match(finalGoLiveCompletionAuditText, /final_live_healthcheck/);
  assert.match(finalGoLiveCompletionAuditText, /writesTomRuntime: false/);
  assert.match(finalGoLiveCompletionAuditText, /writesApprovalFile: false/);
  assert.match(finalGoLiveCompletionAuditText, /writesOpenClawInstanceDirs: false/);
  assert.match(finalGoLiveCompletionAuditText, /clearsHeartbeatFiles: false/);
  assert.match(finalGoLiveCompletionAuditText, /opensLiveGate: false/);
  assert.match(finalGoLiveCompletionAuditText, /callsManagedActionsLiveApi: false/);
  assert.doesNotMatch(finalGoLiveCompletionAuditText, /api\/managed-actions\/live/);
  const pushRemoteCollectorCredentialsText = readFileSync(pushRemoteCollectorCredentials, "utf8");
  assert.match(pushRemoteCollectorCredentialsText, /CONFIRM_PUSH_REMOTE_COLLECTOR_CREDENTIALS/);
  assert.match(pushRemoteCollectorCredentialsText, /I_UNDERSTAND_THIS_ONLY_PUSHES_REMOTE_COLLECTOR_CREDENTIALS_TO_TOM_RUNTIME/);
  assert.match(pushRemoteCollectorCredentialsText, /writesTomControlCenterRuntimeOnly/);
  assert.match(pushRemoteCollectorCredentialsText, /connectsSecondOracle: false/);
  assert.match(pushRemoteCollectorCredentialsText, /writesActiveRegistry: false/);
  assert.match(pushRemoteCollectorCredentialsText, /mutatesOpenClawInstance: false/);
  assert.match(pushRemoteCollectorCredentialsText, /callsLiveApi: false/);
  assert.doesNotMatch(pushRemoteCollectorCredentialsText, /api\/managed-actions\/live/);
  const pushRemoteCollectorCredentialsConfig = JSON.parse(readFileSync(pushRemoteCollectorCredentialsExample, "utf8"));
  assert.equal(pushRemoteCollectorCredentialsConfig.server.id, "remote-oracle");
  assert.equal(pushRemoteCollectorCredentialsConfig.tom.host, "146.235.226.66");
  const remoteCollectorPreflightText = readFileSync(remoteCollectorPreflight, "utf8");
  assert.match(remoteCollectorPreflightText, /CONFIRM_REMOTE_COLLECTOR_PREFLIGHT/);
  assert.match(remoteCollectorPreflightText, /I_UNDERSTAND_THIS_ONLY_READS_REMOTE_PREREQUISITES/);
  assert.match(remoteCollectorPreflightText, /writesRemoteFiles: false/);
  assert.match(remoteCollectorPreflightText, /startsContainers: false/);
  assert.match(remoteCollectorPreflightText, /mutatesOpenClawInstance: false/);
  assert.match(remoteCollectorPreflightText, /callsLiveApi: false/);
  assert.doesNotMatch(remoteCollectorPreflightText, /api\/managed-actions\/live/);
  const remoteCollectorNodeSyncText = readFileSync(remoteCollectorNodeSync, "utf8");
  assert.match(remoteCollectorNodeSyncText, /remote-collector-node-sync\.sh plan/);
  assert.match(remoteCollectorNodeSyncText, /CONFIRM_REMOTE_COLLECTOR_NODE_SYNC/);
  assert.match(remoteCollectorNodeSyncText, /I_UNDERSTAND_THIS_ONLY_COPIES_COLLECTOR_BUNDLE_TO_REMOTE/);
  assert.match(remoteCollectorNodeSyncText, /CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_PLAN/);
  assert.match(remoteCollectorNodeSyncText, /I_UNDERSTAND_THIS_ONLY_RUNS_REMOTE_BOOTSTRAP_PLAN/);
  assert.match(remoteCollectorNodeSyncText, /CONFIRM_REMOTE_COLLECTOR_NODE_BOOTSTRAP_WRITE/);
  assert.match(remoteCollectorNodeSyncText, /I_UNDERSTAND_THIS_ONLY_WRITES_REMOTE_COLLECTOR_NODE_FILES/);
  assert.match(remoteCollectorNodeSyncText, /CONFIRM_REMOTE_COLLECTOR_NODE_SNAPSHOT/);
  assert.match(remoteCollectorNodeSyncText, /I_UNDERSTAND_THIS_RUNS_REMOTE_COLLECTOR_SNAPSHOT_ONLY/);
  assert.match(remoteCollectorNodeSyncText, /CONFIRM_REMOTE_COLLECTOR_NODE_CRON/);
  assert.match(remoteCollectorNodeSyncText, /I_UNDERSTAND_THIS_ONLY_INSTALLS_REMOTE_COLLECTOR_CRON/);
  assert.match(remoteCollectorNodeSyncText, /writesRemoteCollectorNode/);
  assert.match(remoteCollectorNodeSyncText, /startsCollectorContainer/);
  assert.match(remoteCollectorNodeSyncText, /writesOpenClawInstanceDirs: false/);
  assert.match(remoteCollectorNodeSyncText, /startsContainers: modeName === "snapshot"/);
  assert.match(remoteCollectorNodeSyncText, /callsLiveApi: false/);
  assert.doesNotMatch(remoteCollectorNodeSyncText, /api\/managed-actions\/live/);
  const remoteCollectorRolloutText = readFileSync(remoteCollectorRollout, "utf8");
  assert.match(remoteCollectorRolloutText, /remote-collector-rollout\.sh status/);
  assert.match(remoteCollectorRolloutText, /needs_remote_credentials/);
  assert.match(remoteCollectorRolloutText, /remote-oracle-intake\.sh run/);
  assert.match(remoteCollectorRolloutText, /write-push-config/);
  assert.match(remoteCollectorRolloutText, /needs_remote_preflight/);
  assert.match(remoteCollectorRolloutText, /needs_remote_collector_pull/);
  assert.match(remoteCollectorRolloutText, /remote-collector-node-sync\.sh/);
  assert.match(remoteCollectorRolloutText, /needs_registry_register/);
  assert.match(remoteCollectorRolloutText, /ready_for_healthcheck/);
  assert.match(remoteCollectorRolloutText, /connectsSsh: false/);
  assert.match(remoteCollectorRolloutText, /writesActiveRegistry: false/);
  assert.match(remoteCollectorRolloutText, /mutatesOpenClawInstance: false/);
  assert.match(remoteCollectorRolloutText, /callsLiveApi: false/);
  assert.doesNotMatch(remoteCollectorRolloutText, /api\/managed-actions\/live/);
  const remoteCollectorRolloutRunnerText = readFileSync(remoteCollectorRolloutRunner, "utf8");
  assert.match(remoteCollectorRolloutRunnerText, /CONFIRM_REMOTE_COLLECTOR_ROLLOUT_RUNNER/);
  assert.match(remoteCollectorRolloutRunnerText, /I_UNDERSTAND_THIS_RUNS_SAFE_REMOTE_COLLECTOR_ROLLOUT_STEPS/);
  assert.match(remoteCollectorRolloutRunnerText, /remote-collector-rollout\.sh/);
  assert.match(remoteCollectorRolloutRunnerText, /remote-collector-preflight\.sh/);
  assert.match(remoteCollectorRolloutRunnerText, /remote-collector-node-sync\.sh/);
  assert.match(remoteCollectorRolloutRunnerText, /I_UNDERSTAND_THIS_RUNS_REMOTE_COLLECTOR_SNAPSHOT_ONLY/);
  assert.match(remoteCollectorRolloutRunnerText, /I_UNDERSTAND_THIS_ONLY_INSTALLS_REMOTE_COLLECTOR_CRON/);
  assert.match(remoteCollectorRolloutRunnerText, /remote-collector-pull\.sh/);
  assert.match(remoteCollectorRolloutRunnerText, /register-remote-collector\.sh/);
  assert.match(remoteCollectorRolloutRunnerText, /mutatesOpenClawInstance/);
  assert.doesNotMatch(remoteCollectorRolloutRunnerText, /api\/managed-actions\/live/);
  const goLiveGateText = readFileSync(goLiveGate, "utf8");
  assert.match(goLiveGateText, /go-live-gate\.sh status/);
  assert.match(goLiveGateText, /go-live-gate\.sh check/);
  assert.match(goLiveGateText, /OPENCLAW_TOPOLOGY_MODE/);
  assert.match(goLiveGateText, /skipped_local_only/);
  assert.match(goLiveGateText, /crossServerRequired/);
  assert.match(goLiveGateText, /managed-action-dry-run-gate\.sh/);
  assert.match(goLiveGateText, /blocked_managed_action_dry_run/);
  assert.match(goLiveGateText, /remote-collector-rollout-runner\.sh/);
  assert.match(goLiveGateText, /live-healthcheck-window\.sh/);
  assert.match(goLiveGateText, /callsManagedActionsLiveApi: false/);
  assert.match(goLiveGateText, /writesOpenClawInstanceDirs: false/);
  assert.doesNotMatch(goLiveGateText, /api\/managed-actions\/live/);
  const remoteCollectorPullText = readFileSync(remoteCollectorPull, "utf8");
  assert.match(remoteCollectorPullText, /CONFIRM_REMOTE_COLLECTOR_PULL/);
  assert.match(remoteCollectorPullText, /I_UNDERSTAND_THIS_ONLY_READS_REMOTE_COLLECTOR_SNAPSHOTS/);
  assert.match(remoteCollectorPullText, /managed-actions live API/);
  assert.doesNotMatch(remoteCollectorPullText, /managed-actions\/live/);
  assert.match(remoteCollectorPullText, /runtime.*collectors/);
  const remoteCollectorExample = JSON.parse(readFileSync(remoteCollectorPullExample, "utf8"));
  assert.equal(remoteCollectorExample.sources[0]?.enabled, false);
  const registerLocalInstanceText = readFileSync(registerLocalInstance, "utf8");
  assert.match(registerLocalInstanceText, /CONFIRM_LOCAL_INSTANCE_REGISTER/);
  assert.match(registerLocalInstanceText, /I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_LOCAL_REGISTRY/);
  assert.match(registerLocalInstanceText, /updatesControlCenterRegistryAndComposeOnly: true/);
  assert.match(registerLocalInstanceText, /writesOpenClawInstanceDirs: false/);
  assert.match(registerLocalInstanceText, /restartsOpenClawInstance: false/);
  assert.match(registerLocalInstanceText, /callsLiveApi: false/);
  assert.doesNotMatch(registerLocalInstanceText, /api\/managed-actions\/live/);
  const registerLocalInstanceConfig = JSON.parse(readFileSync(registerLocalInstanceExample, "utf8"));
  assert.equal(registerLocalInstanceConfig.server.id, "tom-oracle");
  assert.equal(registerLocalInstanceConfig.replaceExisting, false);
  const registerRemoteCollectorText = readFileSync(registerRemoteCollector, "utf8");
  assert.match(registerRemoteCollectorText, /CONFIRM_REMOTE_COLLECTOR_REGISTER/);
  assert.match(registerRemoteCollectorText, /I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_REGISTRY/);
  assert.match(registerRemoteCollectorText, /updatesControlCenterRegistryOnly: true/);
  assert.match(registerRemoteCollectorText, /mutatesOpenClawInstance: false/);
  assert.doesNotMatch(registerRemoteCollectorText, /api\/managed-actions\/live/);
  const registerRemoteCollectorConfig = JSON.parse(readFileSync(registerRemoteCollectorExample, "utf8"));
  assert.equal(registerRemoteCollectorConfig.server.id, "remote-oracle");
  assert.match(readFileSync(cron, "utf8"), /OPENCLAW_COLLECTOR_CRON_BEGIN/);
  const impactText = readFileSync(instanceImpactSnapshot, "utf8");
  assert.match(impactText, /instance-impact-snapshot\.sh snapshot/);
  assert.match(impactText, /gateway health/);
  assert.match(impactText, /instanceMounts/);
  assert.match(impactText, /liveExecutionAvailable/);
  assert.match(impactText, /READONLY_MODE/);
  const approvalText = readFileSync(liveHealthcheckApproval, "utf8");
  assert.match(approvalText, /live-healthcheck-approval\.sh prepare/);
  assert.match(approvalText, /live-healthcheck-approval\.sh approve/);
  assert.match(approvalText, /live-healthcheck-approval\.sh consume/);
  assert.match(approvalText, /live-healthcheck-approval\.sh template/);
  assert.match(approvalText, /live-healthcheck-approval\.sh status/);
  assert.match(approvalText, /I_APPROVE_LIVE_HEALTHCHECK_RECORD/);
  assert.match(approvalText, /APPROVED_BY/);
  assert.match(approvalText, /APPROVAL_PACKET_SCRIPT/);
  assert.match(approvalText, /live-healthcheck-approval-packet\.sh/);
  assert.match(approvalText, /check_approval_packet/);
  assert.match(approvalText, /approve_record\(\)[\s\S]*check_approval_packet[\s\S]*已写入人工批准记录/);
  assert.match(approvalText, /needs_manual_approval/);
  assert.match(approvalText, /approved 必须为 true/);
  assert.match(approvalText, /批准记录已被使用/);
  assert.match(approvalText, /I_UNDERSTAND_THIS_TEMPORARILY_ENABLES_LIVE_GATE/);
  assert.match(approvalText, /I_UNDERSTAND_THIS_CALLS_LIVE_API/);
  assert.match(approvalText, /mutatesOpenClawInstance/);
  const approvalExample = JSON.parse(readFileSync(liveHealthcheckApprovalExample, "utf8"));
  assert.equal(approvalExample.approved, false);
  assert.equal(approvalExample.consumed, false);
  assert.equal(approvalExample.action, "healthcheck");
  assert.equal(approvalExample.scope.mutatesOpenClawInstance, false);
  const approvalPacketText = readFileSync(liveHealthcheckApprovalPacket, "utf8");
  assert.match(approvalPacketText, /live-healthcheck-approval-packet\.sh generate/);
  assert.match(approvalPacketText, /live-healthcheck-approval-packet\.sh check/);
  assert.match(approvalPacketText, /PACKET_MAX_AGE_SECONDS/);
  assert.match(approvalPacketText, /go-live-gate\.sh/);
  assert.match(approvalPacketText, /managed-action-dry-run-gate\.sh/);
  assert.match(approvalPacketText, /live-healthcheck-approval\.sh/);
  assert.match(approvalPacketText, /live-healthcheck-window\.sh/);
  assert.match(approvalPacketText, /instance-impact-snapshot\.sh/);
  assert.match(approvalPacketText, /callsManagedActionsLiveApi: false/);
  assert.match(approvalPacketText, /writesOpenClawInstanceDirs: false/);
  assert.doesNotMatch(approvalPacketText, /api\/managed-actions\/live/);
  const approvalReviewText = readFileSync(liveHealthcheckApprovalReview, "utf8");
  assert.match(approvalReviewText, /live-healthcheck-approval-review\.sh status/);
  assert.match(approvalReviewText, /live-healthcheck-approval-review\.sh check/);
  assert.match(approvalReviewText, /live-healthcheck-readiness\.sh/);
  assert.match(approvalReviewText, /install-managed-action-inbox-cron\.sh/);
  assert.match(approvalReviewText, /managed-action-inbox-runner\.sh/);
  assert.match(approvalReviewText, /ready_for_human_approval/);
  assert.match(approvalReviewText, /approved_ready_for_live_window/);
  assert.match(approvalReviewText, /generatesApprovalPacket: false/);
  assert.match(approvalReviewText, /writesApprovalFile: false/);
  assert.match(approvalReviewText, /opensLiveGate: false/);
  assert.match(approvalReviewText, /callsManagedActionsLiveApi: false/);
  assert.match(approvalReviewText, /writesOpenClawInstanceDirs: false/);
  assert.doesNotMatch(approvalReviewText, /api\/managed-actions\/live/);
  const readinessText = readFileSync(liveHealthcheckReadiness, "utf8");
  assert.match(readinessText, /live-healthcheck-readiness\.sh status/);
  assert.match(readinessText, /live-healthcheck-readiness\.sh check/);
  assert.match(readinessText, /live-healthcheck-approval-packet\.sh/);
  assert.match(readinessText, /live-healthcheck-rollout-runner\.sh prepare/);
  assert.match(readinessText, /live-healthcheck-rollout-runner\.sh run-approved/);
  assert.match(readinessText, /generatesApprovalPacket: false/);
  assert.match(readinessText, /writesApprovalFile: false/);
  assert.match(readinessText, /opensLiveGate: false/);
  assert.match(readinessText, /callsManagedActionsLiveApi: false/);
  assert.doesNotMatch(readinessText, /api\/managed-actions\/live/);
  const liveHealthcheckRolloutRunnerText = readFileSync(liveHealthcheckRolloutRunner, "utf8");
  assert.match(liveHealthcheckRolloutRunnerText, /live-healthcheck-rollout-runner\.sh status/);
  assert.match(liveHealthcheckRolloutRunnerText, /live-healthcheck-rollout-runner\.sh prepare/);
  assert.match(liveHealthcheckRolloutRunnerText, /live-healthcheck-rollout-runner\.sh run-approved/);
  assert.match(liveHealthcheckRolloutRunnerText, /live-healthcheck-rollout-runner\.sh verify-completed/);
  assert.match(liveHealthcheckRolloutRunnerText, /verified_live_healthcheck_completed/);
  assert.match(liveHealthcheckRolloutRunnerText, /approval_consumed/);
  assert.match(liveHealthcheckRolloutRunnerText, /CONFIRM_LIVE_HEALTHCHECK_RUNNER/);
  assert.match(liveHealthcheckRolloutRunnerText, /approved_ready_for_live_window/);
  assert.match(liveHealthcheckRolloutRunnerText, /live-healthcheck-readiness\.sh/);
  assert.match(liveHealthcheckRolloutRunnerText, /managed-action-dry-run-gate\.sh/);
  assert.match(liveHealthcheckRolloutRunnerText, /live-healthcheck-approval-packet\.sh/);
  assert.match(liveHealthcheckRolloutRunnerText, /approvesLiveHealthcheck: false/);
  assert.match(liveHealthcheckRolloutRunnerText, /opensLiveGate: false/);
  assert.match(liveHealthcheckRolloutRunnerText, /callsManagedActionsLiveApi: false/);
  assert.doesNotMatch(liveHealthcheckRolloutRunnerText, /api\/managed-actions\/live/);
  const preflightText = readFileSync(liveHealthcheckPreflight, "utf8");
  assert.match(preflightText, /api\/managed-actions\/readiness/);
  assert.doesNotMatch(preflightText, /api\/managed-actions\/live/);
  assert.match(preflightText, /MANAGED_ACTIONS_LIVE_EXECUTOR_ENABLED/);
  assert.match(preflightText, /check_rollout_file\(\)[\s\S]*-e INSTANCE_ID=/);
  assert.match(preflightText, /check_rollout_file\(\)[\s\S]*-e OPERATOR=/);
  assert.match(preflightText, /managed-action-healthcheck-rollout\.example\.json/);
  const reportText = readFileSync(liveHealthcheckReport, "utf8");
  assert.match(reportText, /operation-audit\.log/);
  assert.match(reportText, /managed_action_live_result/);
  assert.match(reportText, /managed_action_dry_run/);
  assert.match(reportText, /mutatesOpenClawInstance/);
  assert.match(reportText, /approval\.consumed === true/);
  assert.match(reportText, /markdownReport/);
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
  assert.match(liveWindowText, /APPROVAL_PACKET_SCRIPT/);
  assert.match(liveWindowText, /live-healthcheck-approval-packet\.sh/);
  assert.match(liveWindowText, /check_approval_packet/);
  assert.match(liveWindowText, /check_approval_packet[\s\S]*check_approval_file/);
  assert.match(liveWindowText, /live-healthcheck-approval\.sh/);
  assert.match(liveWindowText, /check_approval_file/);
  assert.match(liveWindowText, /consume_approval_file/);
  assert.match(liveWindowText, /APPROVAL_SCRIPT\" status/);
  assert.match(liveWindowText, /live-healthcheck-report\.sh/);
  assert.match(liveWindowText, /instance-impact-snapshot\.sh/);
  assert.match(liveWindowText, /compare "\$IMPACT_BEFORE" "\$impact_after"/);
  assert.match(readFileSync(liveHealthcheckRollout, "utf8"), /"action": "healthcheck"/);
  assert.match(readFileSync(liveHealthcheckRollout, "utf8"), /"risk": "low"/);
  const commandRunnerText = readFileSync(managedActionCommandRunner, "utf8");
  assert.match(commandRunnerText, /managed-action-command-runner\.sh status/);
  assert.match(commandRunnerText, /managed-action-command-runner\.sh plan/);
  assert.match(commandRunnerText, /managed-action-command-runner\.sh dry-run/);
  assert.match(commandRunnerText, /managed-action-command-runner\.sh parse-text/);
  assert.match(commandRunnerText, /managed-action-command-runner\.sh plan-text/);
  assert.match(commandRunnerText, /managed-action-command-runner\.sh dry-run-text/);
  assert.match(commandRunnerText, /parseTextCommand/);
  assert.match(commandRunnerText, /文本指令必须明确包含 dry-run/);
  assert.match(commandRunnerText, /高风险词/);
  assert.match(commandRunnerText, /CONFIRM_MANAGED_ACTION_COMMAND_DRY_RUN/);
  assert.match(commandRunnerText, /I_UNDERSTAND_THIS_ONLY_CALLS_MANAGED_ACTION_DRY_RUN_API/);
  assert.match(commandRunnerText, /MANAGED_ACTION_COMMAND_TOKEN_SOURCE/);
  assert.match(commandRunnerText, /RESOLVED_LOCAL_API_TOKEN_SOURCE/);
  assert.match(commandRunnerText, /api\/managed-actions\/dry-run/);
  assert.match(commandRunnerText, /callsManagedActionsLiveApi: false/);
  assert.match(commandRunnerText, /writesOpenClawInstanceDirs: false/);
  assert.doesNotMatch(commandRunnerText, /api\/managed-actions\/live/);
  const commandTextBridgeText = readFileSync(managedActionTextBridge, "utf8");
  assert.match(commandTextBridgeText, /managed-action-text-bridge\.sh parse/);
  assert.match(commandTextBridgeText, /managed-action-text-bridge\.sh plan/);
  assert.match(commandTextBridgeText, /managed-action-text-bridge\.sh dry-run/);
  assert.match(commandTextBridgeText, /MANAGED_ACTION_TEXT/);
  assert.match(commandTextBridgeText, /MANAGED_ACTION_TEXT_FILE/);
  assert.match(commandTextBridgeText, /CONFIRM_MANAGED_ACTION_TEXT_BRIDGE/);
  assert.match(commandTextBridgeText, /I_UNDERSTAND_THIS_ONLY_RUNS_MANAGED_ACTION_DRY_RUN_TEXT/);
  assert.match(commandTextBridgeText, /managed-action-command-runner/);
  assert.match(commandTextBridgeText, /parse-text/);
  assert.match(commandTextBridgeText, /plan-text/);
  assert.match(commandTextBridgeText, /dry-run-text/);
  assert.match(commandTextBridgeText, /writesControlCenterRuntimeOnly/);
  assert.match(commandTextBridgeText, /callsManagedActionsLiveApi: false/);
  assert.match(commandTextBridgeText, /writesOpenClawInstanceDirs: false/);
  assert.doesNotMatch(commandTextBridgeText, /api\/managed-actions\/live/);
  const managedActionInboxRunnerText = readFileSync(managedActionInboxRunner, "utf8");
  assert.match(managedActionInboxRunnerText, /managed-action-inbox-runner\.sh status/);
  assert.match(managedActionInboxRunnerText, /managed-action-inbox-runner\.sh plan-next/);
  assert.match(managedActionInboxRunnerText, /managed-action-inbox-runner\.sh run-next/);
  assert.match(managedActionInboxRunnerText, /managed-action-inbox-runner\.sh run-pending/);
  assert.match(managedActionInboxRunnerText, /MANAGED_ACTION_INBOX_DIR/);
  assert.match(managedActionInboxRunnerText, /MANAGED_ACTION_INBOX_SOURCE/);
  assert.match(managedActionInboxRunnerText, /MANAGED_ACTION_INBOX_MAX_PER_RUN/);
  assert.match(managedActionInboxRunnerText, /control-center-container/);
  assert.match(managedActionInboxRunnerText, /CONFIRM_MANAGED_ACTION_INBOX_RUNNER/);
  assert.match(managedActionInboxRunnerText, /I_UNDERSTAND_THIS_READS_OPENCLAW_INBOX_AND_RUNS_DRY_RUN_TEXT/);
  assert.match(managedActionInboxRunnerText, /managed-action-text-bridge\.sh/);
  assert.match(managedActionInboxRunnerText, /readsOpenClawInboxOnly/);
  assert.match(managedActionInboxRunnerText, /writesControlCenterRuntimeOnly/);
  assert.match(managedActionInboxRunnerText, /callsManagedActionsLiveApi: false/);
  assert.match(managedActionInboxRunnerText, /writesOpenClawInstanceDirs: false/);
  assert.doesNotMatch(managedActionInboxRunnerText, /api\/managed-actions\/live/);
  const managedActionInboxCronInstallerText = readFileSync(managedActionInboxCronInstaller, "utf8");
  assert.match(managedActionInboxCronInstallerText, /install-managed-action-inbox-cron\.sh status/);
  assert.match(managedActionInboxCronInstallerText, /install-managed-action-inbox-cron\.sh plan/);
  assert.match(managedActionInboxCronInstallerText, /install-managed-action-inbox-cron\.sh apply/);
  assert.match(managedActionInboxCronInstallerText, /OPENCLAW_MANAGED_ACTION_INBOX_CRON_BEGIN/);
  assert.match(managedActionInboxCronInstallerText, /managed-action-inbox-runner\.sh run-pending/);
  assert.match(managedActionInboxCronInstallerText, /CONFIRM_MANAGED_ACTION_INBOX_CRON/);
  assert.match(managedActionInboxCronInstallerText, /I_UNDERSTAND_THIS_ONLY_INSTALLS_DRY_RUN_INBOX_CRON/);
  assert.match(managedActionInboxCronInstallerText, /CONFIRM_MANAGED_ACTION_INBOX_RUNNER/);
  assert.match(managedActionInboxCronInstallerText, /MANAGED_ACTION_COMMAND_TOKEN_SOURCE=container/);
  assert.match(managedActionInboxCronInstallerText, /writesCrontabOnly/);
  assert.match(managedActionInboxCronInstallerText, /callsManagedActionsLiveApi: false/);
  assert.match(managedActionInboxCronInstallerText, /writesOpenClawInstanceDirs: false/);
  assert.doesNotMatch(managedActionInboxCronInstallerText, /api\/managed-actions\/live/);
  const heartbeatBurnAlertRunnerText = readFileSync(heartbeatBurnAlertRunner, "utf8");
  assert.match(heartbeatBurnAlertRunnerText, /heartbeat-burn-alert-runner\.sh status/);
  assert.match(heartbeatBurnAlertRunnerText, /heartbeat-burn-alert-runner\.sh run/);
  assert.match(heartbeatBurnAlertRunnerText, /heartbeat-burn-inspector\.sh/);
  assert.match(heartbeatBurnAlertRunnerText, /heartbeat-burn-alerts/);
  assert.match(heartbeatBurnAlertRunnerText, /events\.ndjson/);
  assert.match(heartbeatBurnAlertRunnerText, /writesControlCenterRuntimeOnly/);
  assert.match(heartbeatBurnAlertRunnerText, /writesOpenClawInstanceDirs: false/);
  assert.match(heartbeatBurnAlertRunnerText, /clearsHeartbeatFiles: false/);
  assert.match(heartbeatBurnAlertRunnerText, /callsModelApis: false/);
  assert.match(heartbeatBurnAlertRunnerText, /callsManagedActionsLiveApi: false/);
  assert.doesNotMatch(heartbeatBurnAlertRunnerText, /api\/managed-actions\/live/);
  const heartbeatBurnAlertCronInstallerText = readFileSync(heartbeatBurnAlertCronInstaller, "utf8");
  assert.match(heartbeatBurnAlertCronInstallerText, /install-heartbeat-burn-alert-cron\.sh status/);
  assert.match(heartbeatBurnAlertCronInstallerText, /install-heartbeat-burn-alert-cron\.sh plan/);
  assert.match(heartbeatBurnAlertCronInstallerText, /install-heartbeat-burn-alert-cron\.sh apply/);
  assert.match(heartbeatBurnAlertCronInstallerText, /OPENCLAW_HEARTBEAT_BURN_ALERT_CRON_BEGIN/);
  assert.match(heartbeatBurnAlertCronInstallerText, /heartbeat-burn-alert-runner\.sh run/);
  assert.match(heartbeatBurnAlertCronInstallerText, /CONFIRM_HEARTBEAT_BURN_ALERT_CRON/);
  assert.match(heartbeatBurnAlertCronInstallerText, /I_UNDERSTAND_THIS_ONLY_INSTALLS_READONLY_HEARTBEAT_BURN_ALERT_CRON/);
  assert.match(heartbeatBurnAlertCronInstallerText, /writesCrontabOnly/);
  assert.match(heartbeatBurnAlertCronInstallerText, /writesOpenClawInstanceDirs: false/);
  assert.match(heartbeatBurnAlertCronInstallerText, /clearsHeartbeatFiles: false/);
  assert.match(heartbeatBurnAlertCronInstallerText, /callsModelApis: false/);
  assert.match(heartbeatBurnAlertCronInstallerText, /callsManagedActionsLiveApi: false/);
  assert.doesNotMatch(heartbeatBurnAlertCronInstallerText, /api\/managed-actions\/live/);
  const managedActionAgentsInstallerText = readFileSync(managedActionAgentsInstaller, "utf8");
  assert.match(managedActionAgentsInstallerText, /install-managed-action-agents-instructions\.sh status/);
  assert.match(managedActionAgentsInstallerText, /install-managed-action-agents-instructions\.sh plan/);
  assert.match(managedActionAgentsInstallerText, /install-managed-action-agents-instructions\.sh apply/);
  assert.match(managedActionAgentsInstallerText, /CONFIRM_MANAGED_ACTION_AGENTS_INSTALL/);
  assert.match(managedActionAgentsInstallerText, /I_UNDERSTAND_THIS_UPDATES_TOM_AGENTS_INSTRUCTIONS_ONLY/);
  assert.match(managedActionAgentsInstallerText, /OPENCLAW_CONTROL_CENTER_MANAGED_ACTIONS_BEGIN/);
  assert.match(managedActionAgentsInstallerText, /control-center-commands\/inbox/);
  assert.match(managedActionAgentsInstallerText, /不要调用 control-center API/);
  assert.match(managedActionAgentsInstallerText, /不要读取或输出 LOCAL_API_TOKEN/);
  assert.match(managedActionAgentsInstallerText, /writesAgentsMdOnly/);
  assert.match(managedActionAgentsInstallerText, /writesOpenClawConfig: false/);
  assert.match(managedActionAgentsInstallerText, /restartsOpenClawInstances: false/);
  assert.match(managedActionAgentsInstallerText, /callsManagedActionsLiveApi: false/);
  assert.doesNotMatch(managedActionAgentsInstallerText, /api\/managed-actions\/live/);
  const dryRunGateText = readFileSync(managedActionDryRunGate, "utf8");
  assert.match(dryRunGateText, /managed-action-dry-run-gate\.sh status/);
  assert.match(dryRunGateText, /CONFIRM_MANAGED_ACTION_DRY_RUN/);
  assert.match(dryRunGateText, /I_UNDERSTAND_THIS_ONLY_CREATES_DRY_RUN_AUDIT_RECORD/);
  assert.match(dryRunGateText, /live-healthcheck-rollout-runner\.sh prepare/);
  assert.match(dryRunGateText, /live-healthcheck-rollout-runner\.sh run-approved/);
  assert.match(dryRunGateText, /api\/managed-actions\/dry-run/);
  assert.match(dryRunGateText, /callsManagedActionsLiveApi: false/);
  assert.match(dryRunGateText, /writesOpenClawInstanceDirs: false/);
  assert.doesNotMatch(dryRunGateText, /api\/managed-actions\/live/);
  assert(healthcheck.includes("COLLECTOR_SNAPSHOT_MAX_AGE_SECONDS"));
  assert(compose.includes("OPENCLAW_INSTANCES_FILE"));
  assert(env.includes("OPENCLAW_INSTANCES_JSON"));
  assert(env.includes("servers"));
  assert(env.includes("collectorSnapshotPath"));
  assert(env.includes("OPENCLAW_COLLECTOR_CRON_SCHEDULE"));
});
