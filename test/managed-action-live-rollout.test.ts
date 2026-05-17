import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  defaultManagedActionLiveRolloutConfig,
  evaluateManagedActionLiveRollout,
  loadManagedActionLiveRolloutConfig,
  normalizeManagedActionLiveRolloutConfig,
} from "../src/runtime/managed-action-live-rollout";

test("managed action live rollout config defaults to disabled", () => {
  const config = defaultManagedActionLiveRolloutConfig();
  assert.equal(config.source, "default");
  assert.equal(config.enabled, false);
  assert.deepEqual(config.rules, []);
  assert.deepEqual(config.issues, []);

  const decision = evaluateManagedActionLiveRollout({
    config,
    action: "healthcheck",
    instanceId: "tom",
    operator: "Anan",
  });
  assert.equal(decision.allowed, false);
  assert.equal(decision.status, "disabled");
});

test("managed action live rollout config accepts a narrow matching rule", () => {
  const config = normalizeManagedActionLiveRolloutConfig({
    enabled: true,
    rules: [
      {
        action: "healthcheck",
        instanceId: "tom",
        operators: ["Anan"],
        risk: "low",
        maxDryRunAgeMinutes: 30,
      },
    ],
  });

  assert.equal(config.enabled, true);
  assert.equal(config.issues.length, 0);
  assert.equal(config.rules[0]?.enabled, true);
  assert.equal(config.rules[0]?.maxDryRunAgeMinutes, 30);

  const allowed = evaluateManagedActionLiveRollout({
    config,
    action: "healthcheck",
    instanceId: "tom",
    operator: "Anan",
  });
  assert.equal(allowed.allowed, true);
  assert.equal(allowed.status, "allowed");
  assert.equal(allowed.rule?.risk, "low");

  const blocked = evaluateManagedActionLiveRollout({
    config,
    action: "healthcheck",
    instanceId: "main",
    operator: "Anan",
  });
  assert.equal(blocked.allowed, false);
  assert.equal(blocked.status, "no_matching_rule");
});

test("managed action live rollout config supports wildcard operators but ignores disabled rules", () => {
  const config = normalizeManagedActionLiveRolloutConfig({
    enabled: true,
    rules: [
      {
        action: "healthcheck",
        instanceId: "tom",
        operators: ["*"],
        risk: "low",
        enabled: false,
      },
      {
        action: "collector_refresh",
        instanceId: "tom",
        operators: ["*"],
        risk: "medium",
      },
    ],
  });

  const disabledRuleDecision = evaluateManagedActionLiveRollout({
    config,
    action: "healthcheck",
    instanceId: "tom",
    operator: "Someone",
  });
  assert.equal(disabledRuleDecision.allowed, false);
  assert.equal(disabledRuleDecision.status, "no_matching_rule");

  const wildcardDecision = evaluateManagedActionLiveRollout({
    config,
    action: "collector_refresh",
    instanceId: "tom",
    operator: "Someone",
  });
  assert.equal(wildcardDecision.allowed, true);
  assert.equal(wildcardDecision.rule?.risk, "medium");
});

test("managed action live rollout config reports invalid rules without allowing them", () => {
  const config = normalizeManagedActionLiveRolloutConfig({
    enabled: true,
    rules: [
      { action: "restart", instanceId: "tom", operators: ["Anan"], risk: "high" },
      { action: "healthcheck", operators: [], risk: "low" },
    ],
  });

  assert.equal(config.enabled, true);
  assert.equal(config.rules.length, 0);
  assert(config.issues.some((issue) => issue.includes("rules[0].action")));
  assert(config.issues.some((issue) => issue.includes("rules[1].instanceId")));
});

test("managed action live rollout config can load from file", async () => {
  const dir = await mkdtemp(join(tmpdir(), "managed-action-rollout-"));
  const path = join(dir, "rollout.json");
  await writeFile(
    path,
    JSON.stringify({
      enabled: true,
      rules: [
        {
          action: "healthcheck",
          instanceId: "tom",
          operators: ["Anan"],
          risk: "low",
        },
      ],
    }),
    "utf8",
  );

  try {
    const config = await loadManagedActionLiveRolloutConfig(path);
    assert.equal(config.source, "file");
    assert.equal(config.path, path);
    assert.equal(config.enabled, true);
    assert.equal(config.rules.length, 1);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
