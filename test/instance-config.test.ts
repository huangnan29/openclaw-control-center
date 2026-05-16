import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  loadOpenClawInstanceConfigs,
  parseOpenClawInstanceConfigText,
} from "../src/runtime/instance-config";

test("parseOpenClawInstanceConfigText accepts multiple readonly instances", () => {
  const result = parseOpenClawInstanceConfigText(
    JSON.stringify({
      instances: [
        {
          id: "main",
          gatewayUrl: "ws://127.0.0.1:18789",
          openclawHome: "/instances/main/config",
          workspaceRoot: "/instances/main/workspace",
        },
        {
          id: "tom",
          gatewayUrl: "ws://127.0.0.1:18790",
          openclawHome: "/instances/tom/config",
          workspaceRoot: "/instances/tom/workspace",
        },
      ],
    }),
    "inline",
  );

  assert.equal(result.issues.length, 0);
  assert.equal(result.instances.length, 2);
  assert.deepEqual(
    result.instances.map((instance) => instance.id),
    ["main", "tom"],
  );
  assert.equal(result.instances[0]?.openclawConfigPath, "/instances/main/config/openclaw.json");
});

test("parseOpenClawInstanceConfigText rejects duplicate and unsafe ids", () => {
  const result = parseOpenClawInstanceConfigText(
    JSON.stringify({
      instances: [
        {
          id: "tom",
          gatewayUrl: "ws://127.0.0.1:18789",
          openclawHome: "/instances/tom/config",
          workspaceRoot: "/instances/tom/workspace",
        },
        {
          id: "tom",
          gatewayUrl: "ws://127.0.0.1:18790",
          openclawHome: "/instances/tom-duplicate/config",
          workspaceRoot: "/instances/tom-duplicate/workspace",
        },
        {
          id: "../bad",
          gatewayUrl: "ws://127.0.0.1:18791",
          openclawHome: "/instances/bad/config",
          workspaceRoot: "/instances/bad/workspace",
        },
      ],
    }),
    "inline",
  );

  assert.equal(result.instances.length, 1);
  assert.deepEqual(
    result.issues.map((issue) => issue.message),
    ["duplicate id: tom", "invalid id: ../bad"],
  );
});

test("loadOpenClawInstanceConfigs falls back to default single instance", () => {
  const result = loadOpenClawInstanceConfigs({
    GATEWAY_URL: "ws://127.0.0.1:18888",
    OPENCLAW_HOME: "/default/openclaw",
    OPENCLAW_WORKSPACE_ROOT: "/default/workspace",
  });

  assert.equal(result.source, "fallback");
  assert.equal(result.issues.length, 0);
  assert.deepEqual(result.instances, [
    {
      id: "default",
      label: "default",
      gatewayUrl: "ws://127.0.0.1:18888",
      openclawHome: "/default/openclaw",
      openclawConfigPath: "/default/openclaw/openclaw.json",
      workspaceRoot: "/default/workspace",
      readonly: true,
    },
  ]);
});

test("loadOpenClawInstanceConfigs reads OPENCLAW_INSTANCES_FILE", () => {
  const tempDir = mkdtempSync(join(tmpdir(), "openclaw-instances-"));
  const filePath = join(tempDir, "instances.json");
  writeFileSync(
    filePath,
    JSON.stringify({
      instances: [
        {
          id: "spark",
          gatewayUrl: "ws://127.0.0.1:18799",
          openclawHome: "/instances/spark/config",
          workspaceRoot: "/instances/spark/workspace",
        },
      ],
    }),
  );

  const result = loadOpenClawInstanceConfigs({
    OPENCLAW_INSTANCES_FILE: filePath,
  });

  assert.equal(result.source, filePath);
  assert.equal(result.issues.length, 0);
  assert.deepEqual(
    result.instances.map((instance) => instance.id),
    ["spark"],
  );
});
