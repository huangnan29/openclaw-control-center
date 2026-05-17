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
          name: "Main",
          gatewayUrl: "ws://127.0.0.1:18789",
          openclawHome: "/instances/main/config",
          workspaceRoot: "/instances/main/workspace",
        },
        {
          id: "tom",
          name: "Tom",
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
  assert.equal(result.instances[0]?.name, "Main");
});

test("parseOpenClawInstanceConfigText accepts cross-server registry", () => {
  const result = parseOpenClawInstanceConfigText(
    JSON.stringify({
      servers: [
        {
          id: "tom-oracle",
          name: "Tom Oracle",
          host: "146.235.226.66",
          region: "oracle-us",
          instances: [
            {
              id: "tom-main",
              name: "Tom Main",
              gatewayUrl: "ws://127.0.0.1:18789",
              openclawHome: "/instances/main/config",
              workspaceRoot: "/instances/main/workspace",
            },
          ],
        },
      ],
    }),
    "inline",
  );

  assert.equal(result.issues.length, 0);
  assert.equal(result.servers?.[0]?.id, "tom-oracle");
  assert.equal(result.servers?.[0]?.name, "Tom Oracle");
  assert.equal(result.instances.length, 1);
  assert.equal(result.instances[0]?.serverId, "tom-oracle");
  assert.equal(result.instances[0]?.serverName, "Tom Oracle");
  assert.equal(result.instances[0]?.serverHost, "146.235.226.66");
  assert.equal(result.instances[0]?.serverRegion, "oracle-us");
});

test("parseOpenClawInstanceConfigText attaches server collector snapshot path", () => {
  const result = parseOpenClawInstanceConfigText(
    JSON.stringify({
      servers: [
        {
          id: "remote-oracle",
          name: "Remote Oracle",
          collectorSnapshotPath: "/collectors/remote-oracle/snapshot.json",
          instances: [
            {
              id: "remote-main",
              name: "Remote Main",
              openclawHome: "/remote/main/config",
              workspaceRoot: "/remote/main/workspace",
            },
          ],
        },
      ],
    }),
    "inline",
  );

  assert.equal(result.issues.length, 0);
  assert.equal(result.servers?.[0]?.collectorSnapshotPath, "/collectors/remote-oracle/snapshot.json");
  assert.equal(result.instances[0]?.collectorSnapshotPath, "/collectors/remote-oracle/snapshot.json");
});

test("parseOpenClawInstanceConfigText rejects duplicate and unsafe ids", () => {
  const result = parseOpenClawInstanceConfigText(
    JSON.stringify({
      instances: [
        {
          id: "tom",
          name: "Tom",
          gatewayUrl: "ws://127.0.0.1:18789",
          openclawHome: "/instances/tom/config",
          workspaceRoot: "/instances/tom/workspace",
        },
        {
          id: "tom",
          name: "Tom Duplicate",
          gatewayUrl: "ws://127.0.0.1:18790",
          openclawHome: "/instances/tom-duplicate/config",
          workspaceRoot: "/instances/tom-duplicate/workspace",
        },
        {
          id: "../bad",
          name: "Bad",
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
      name: "default",
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
          name: "Spark",
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

test("loadOpenClawInstanceConfigs reads OPENCLAW_INSTANCES_JSON", () => {
  const result = loadOpenClawInstanceConfigs({
    OPENCLAW_INSTANCES_JSON: JSON.stringify({
      instances: [
        {
          id: "json_instance",
          name: "JSON Instance",
          gatewayUrl: "ws://127.0.0.1:18801",
          openclawHome: "/instances/json/config",
          workspaceRoot: "/instances/json/workspace",
        },
      ],
    }),
  });

  assert.equal(result.source, "OPENCLAW_INSTANCES_JSON");
  assert.equal(result.issues.length, 0);
  assert.equal(result.instances[0]?.id, "json_instance");
  assert.equal(result.instances[0]?.name, "JSON Instance");
});

test("parseOpenClawInstanceConfigText reports invalid JSON without throwing", () => {
  const result = parseOpenClawInstanceConfigText("{", "broken");

  assert.equal(result.source, "broken");
  assert.equal(result.instances.length, 0);
  assert.match(result.issues[0]?.message ?? "", /^invalid json:/);
});

test("loadOpenClawInstanceConfigs reports file read failure without throwing", () => {
  const missingPath = join(tmpdir(), "openclaw-missing-instances.json");
  const result = loadOpenClawInstanceConfigs({
    OPENCLAW_INSTANCES_FILE: missingPath,
  });

  assert.equal(result.source, missingPath);
  assert.equal(result.instances.length, 0);
  assert.match(result.issues[0]?.message ?? "", /^failed to read instances file:/);
});

test("parseOpenClawInstanceConfigText rejects missing and invalid typed fields", () => {
  const result = parseOpenClawInstanceConfigText(
    JSON.stringify({
      instances: [
        {
          id: "missing_home",
          name: "Missing Home",
          gatewayUrl: "ws://127.0.0.1:18802",
        },
        {
          id: "bad_types",
          name: 42,
          gatewayUrl: 18803,
          openclawHome: false,
          workspaceRoot: ["bad"],
        },
      ],
    }),
    "inline",
  );

  assert.equal(result.instances.length, 0);
  assert.deepEqual(
    result.issues.map((issue) => issue.message),
    [
      "missing openclawHome for id: missing_home",
      "invalid name for id: bad_types",
      "invalid openclawHome for id: bad_types",
      "invalid gatewayUrl for id: bad_types",
      "invalid workspaceRoot for id: bad_types",
    ],
  );
});

test("loadOpenClawInstanceConfigs fallback honors OPENCLAW_CONFIG_PATH", () => {
  const result = loadOpenClawInstanceConfigs({
    OPENCLAW_HOME: "/default/openclaw",
    OPENCLAW_CONFIG_PATH: "/custom/openclaw.json",
  });

  assert.equal(result.instances[0]?.openclawConfigPath, "/custom/openclaw.json");
});
