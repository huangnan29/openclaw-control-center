import assert from "node:assert/strict";
import test from "node:test";
import { ReadonlyToolClient } from "../src/clients/tool-client";
import { startUiServer } from "../src/ui/server";

function instance(id: string) {
  return {
    id,
    name: id,
    gatewayUrl: `ws://127.0.0.1:${id === "main" ? "18789" : "18791"}`,
    openclawHome: `/instances/${id}/config`,
    openclawConfigPath: `/instances/${id}/config/openclaw.json`,
    workspaceRoot: `/instances/${id}/workspace`,
    readonly: true,
  };
}

test("managed action dry-run previews whitelisted actions without executing in readonly multi-instance mode", async () => {
  const previousInstancesJson = process.env.OPENCLAW_INSTANCES_JSON;
  const previousInstancesFile = process.env.OPENCLAW_INSTANCES_FILE;
  process.env.OPENCLAW_INSTANCES_JSON = JSON.stringify({
    servers: [
      {
        id: "tom-oracle",
        name: "Tom Oracle",
        collectorSnapshotPath: "/app/runtime/collectors/tom-oracle/snapshot.json",
        instances: [instance("main"), instance("tom")],
      },
    ],
  });
  delete process.env.OPENCLAW_INSTANCES_FILE;

  const server = startUiServer(0, new ReadonlyToolClient(), {
    readonlyMode: true,
    localTokenAuthRequired: false,
  });

  try {
    if (!server.listening) {
      await new Promise<void>((resolve, reject) => {
        server.once("listening", resolve);
        server.once("error", reject);
      });
    }
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("Failed to bind ephemeral UI port.");
    const baseUrl = `http://127.0.0.1:${address.port}`;

    const response = await fetch(`${baseUrl}/api/managed-actions/dry-run`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        instanceId: "tom",
        action: "healthcheck",
        reason: "上线前只读演练",
      }),
    });
    assert.equal(response.status, 200);
    const body = await response.json() as {
      ok: boolean;
      dryRun: boolean;
      liveExecution: boolean;
      action: string;
      target: { instanceId: string; serverId?: string };
      commandPreview: string[];
      safety: { mutatesOpenClawInstance: boolean; requiresConfirmation: boolean };
    };

    assert.equal(body.ok, true);
    assert.equal(body.dryRun, true);
    assert.equal(body.liveExecution, false);
    assert.equal(body.action, "healthcheck");
    assert.equal(body.target.instanceId, "tom");
    assert.deepEqual(body.commandPreview, ["control-center healthcheck for instance tom"]);
    assert.equal(body.safety.mutatesOpenClawInstance, false);
    assert.equal(body.safety.requiresConfirmation, true);

    const blockedResponse = await fetch(`${baseUrl}/api/managed-actions/dry-run`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        instanceId: "missing",
        action: "healthcheck",
      }),
    });
    assert.equal(blockedResponse.status, 404);
  } finally {
    if (server.listening) {
      await new Promise<void>((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
    }
    if (previousInstancesJson === undefined) {
      delete process.env.OPENCLAW_INSTANCES_JSON;
    } else {
      process.env.OPENCLAW_INSTANCES_JSON = previousInstancesJson;
    }
    if (previousInstancesFile === undefined) {
      delete process.env.OPENCLAW_INSTANCES_FILE;
    } else {
      process.env.OPENCLAW_INSTANCES_FILE = previousInstancesFile;
    }
  }
});
