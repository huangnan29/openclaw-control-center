import assert from "node:assert/strict";
import test from "node:test";
import { ReadonlyToolClient } from "../src/clients/tool-client";
import { startUiServer } from "../src/ui/server";

test("readonly mode blocks mutation routes before local token auth", async () => {
  const server = startUiServer(0, new ReadonlyToolClient(), {
    localTokenAuthRequired: false,
  });
  try {
    const baseUrl = await listen(server);
    const response = await fetch(`${baseUrl}/api/ui/preferences`, {
      method: "PATCH",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ language: "zh" }),
    });

    assert.equal(response.status, 403);
    const payload = await response.json() as { error?: { message?: string } };
    assert.match(payload.error?.message ?? "", /修改类接口已禁用/);
  } finally {
    await close(server);
  }
});

test("multi-instance mode blocks mutation routes even when readonly option is disabled", async () => {
  const previousInstancesJson = process.env.OPENCLAW_INSTANCES_JSON;
  const previousInstancesFile = process.env.OPENCLAW_INSTANCES_FILE;
  process.env.OPENCLAW_INSTANCES_JSON = JSON.stringify({
    instances: [
      {
        id: "tom",
        name: "Tom",
        gatewayUrl: "ws://127.0.0.1:18789",
        openclawHome: "/instances/tom",
      },
      {
        id: "spark",
        name: "Spark",
        gatewayUrl: "ws://127.0.0.1:18790",
        openclawHome: "/instances/spark",
      },
    ],
  });
  delete process.env.OPENCLAW_INSTANCES_FILE;

  const server = startUiServer(0, new ReadonlyToolClient(), {
    localTokenAuthRequired: false,
    readonlyMode: false,
  });
  try {
    const baseUrl = await listen(server);
    const response = await fetch(`${baseUrl}/api/tasks/heartbeat`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({}),
    });

    assert.equal(response.status, 403);
    const payload = await response.json() as { error?: { message?: string } };
    assert.match(payload.error?.message ?? "", /修改类接口已禁用/);
  } finally {
    await close(server);
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

async function listen(server: ReturnType<typeof startUiServer>): Promise<string> {
  if (!server.listening) {
    await new Promise<void>((resolve, reject) => {
      server.once("listening", resolve);
      server.once("error", reject);
    });
  }
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("Failed to bind ephemeral UI port.");
  return `http://127.0.0.1:${address.port}`;
}

async function close(server: ReturnType<typeof startUiServer>): Promise<void> {
  if (!server.listening) return;
  await new Promise<void>((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
}
