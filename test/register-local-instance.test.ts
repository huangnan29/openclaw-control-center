import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const ROOT = process.cwd();
const SCRIPT = join(ROOT, "ops", "tom-readonly", "register-local-instance.sh");

function composeText(configDir: string, workspaceDir: string): string {
  return `services:
  control-center:
    image: openclaw-control-center:multi-instance-readonly
    container_name: openclaw-control-center-readonly
    environment:
      OPENCLAW_INSTANCES_FILE: "/app/config/instances.json"
      READONLY_MODE: "true"
    volumes:
      - ./runtime:/app/runtime
      - ./config/instances.json:/app/config/instances.json:ro
      - ${configDir}:/instances/main/config:ro
      - ${workspaceDir}:/instances/main/workspace:ro
`;
}

async function writeFixture(dir: string) {
  const deployDir = join(dir, "deploy");
  const registryFile = join(deployDir, "config", "instances.json");
  const composeFile = join(deployDir, "docker-compose.yml");
  const configFile = join(dir, "register-local-instance.json");
  const mainConfig = join(dir, "openclaw-main", "config");
  const mainWorkspace = join(dir, "openclaw-main", "workspace");
  const newConfig = join(dir, "openclaw-new", "config");
  const newWorkspace = join(dir, "openclaw-new", "workspace");

  await mkdir(join(deployDir, "config"), { recursive: true });
  await mkdir(join(deployDir, "runtime", "deploy-state"), { recursive: true });
  await mkdir(mainConfig, { recursive: true });
  await mkdir(mainWorkspace, { recursive: true });
  await mkdir(newConfig, { recursive: true });
  await mkdir(newWorkspace, { recursive: true });

  await writeFile(
    registryFile,
    `${JSON.stringify(
      {
        servers: [
          {
            id: "tom-oracle",
            name: "Tom Oracle",
            host: "146.235.226.66",
            collectorSnapshotPath: "/app/runtime/collectors/tom-oracle/snapshot.json",
            instances: [
              {
                id: "main",
                name: "Main",
                gatewayUrl: "ws://host.docker.internal:18789",
                openclawHome: "/instances/main/config",
                workspaceRoot: "/instances/main/workspace",
                readonly: true,
              },
            ],
          },
        ],
      },
      null,
      2,
    )}\n`,
    "utf8",
  );
  await writeFile(composeFile, composeText(mainConfig, mainWorkspace), "utf8");
  await writeFile(
    configFile,
    `${JSON.stringify(
      {
        schemaVersion: 1,
        server: {
          id: "tom-oracle",
          name: "Tom Oracle",
          host: "146.235.226.66",
        },
        instance: {
          id: "newbot",
          name: "New Bot",
          gatewayUrl: "ws://host.docker.internal:18799",
          configDir: newConfig,
          workspaceDir: newWorkspace,
        },
      },
      null,
      2,
    )}\n`,
    "utf8",
  );

  return { deployDir, registryFile, composeFile, configFile, newConfig, newWorkspace };
}

test("register local instance plans and applies readonly registry and compose changes", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-register-local-instance-"));
  try {
    const { deployDir, registryFile, composeFile, configFile, newConfig, newWorkspace } = await writeFixture(dir);
    const env = { ...process.env, DEPLOY_DIR: deployDir, REGISTRY_FILE: registryFile, COMPOSE_FILE: composeFile };
    const beforeRegistry = await readFile(registryFile, "utf8");
    const beforeCompose = await readFile(composeFile, "utf8");

    const plan = JSON.parse(execFileSync(SCRIPT, ["plan", configFile], { env, encoding: "utf8" }));
    assert.equal(plan.status, "planned");
    assert.equal(plan.action, "add");
    assert.equal(plan.instance.id, "newbot");
    assert.equal(plan.registryChanged, true);
    assert.equal(plan.composeChanged, true);
    assert.equal(plan.safety.updatesControlCenterRegistryAndComposeOnly, true);
    assert.equal(plan.safety.writesOpenClawInstanceDirs, false);
    assert.equal(plan.safety.restartsOpenClawInstance, false);
    assert.equal(plan.safety.callsLiveApi, false);
    assert.equal(await readFile(registryFile, "utf8"), beforeRegistry);
    assert.equal(await readFile(composeFile, "utf8"), beforeCompose);

    const blocked = spawnSync(SCRIPT, ["apply", configFile], { env, encoding: "utf8" });
    assert.notEqual(blocked.status, 0);
    assert.match(blocked.stderr, /CONFIRM_LOCAL_INSTANCE_REGISTER/);

    const applied = JSON.parse(
      execFileSync(SCRIPT, ["apply", configFile], {
        env: {
          ...env,
          CONFIRM_LOCAL_INSTANCE_REGISTER: "I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_LOCAL_REGISTRY",
        },
        encoding: "utf8",
      }),
    );
    assert.equal(applied.status, "applied");
    assert(existsSync(applied.registryBackupFile));
    assert(existsSync(applied.composeBackupFile));

    const registry = JSON.parse(await readFile(registryFile, "utf8"));
    const server = registry.servers.find((item: { id: string }) => item.id === "tom-oracle");
    const instance = server.instances.find((item: { id: string }) => item.id === "newbot");
    assert.equal(instance.name, "New Bot");
    assert.equal(instance.openclawHome, "/instances/newbot/config");
    assert.equal(instance.workspaceRoot, "/instances/newbot/workspace");
    assert.equal(instance.readonly, true);

    const compose = await readFile(composeFile, "utf8");
    assert.match(compose, new RegExp(`${escapeRegExp(newConfig)}:/instances/newbot/config:ro`));
    assert.match(compose, new RegExp(`${escapeRegExp(newWorkspace)}:/instances/newbot/workspace:ro`));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("register local instance reports already registered without rewriting", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-register-local-instance-"));
  try {
    const { deployDir, registryFile, composeFile, configFile } = await writeFixture(dir);
    const env = {
      ...process.env,
      DEPLOY_DIR: deployDir,
      REGISTRY_FILE: registryFile,
      COMPOSE_FILE: composeFile,
      CONFIRM_LOCAL_INSTANCE_REGISTER: "I_UNDERSTAND_THIS_ONLY_UPDATES_CONTROL_CENTER_LOCAL_REGISTRY",
    };
    JSON.parse(execFileSync(SCRIPT, ["apply", configFile], { env, encoding: "utf8" }));
    const beforeRegistry = await readFile(registryFile, "utf8");
    const beforeCompose = await readFile(composeFile, "utf8");

    const plan = JSON.parse(execFileSync(SCRIPT, ["plan", configFile], { env, encoding: "utf8" }));
    assert.equal(plan.status, "already_registered");
    assert.equal(plan.registryChanged, false);
    assert.equal(plan.composeChanged, false);

    const appliedAgain = JSON.parse(execFileSync(SCRIPT, ["apply", configFile], { env, encoding: "utf8" }));
    assert.equal(appliedAgain.status, "already_registered");
    assert.equal(await readFile(registryFile, "utf8"), beforeRegistry);
    assert.equal(await readFile(composeFile, "utf8"), beforeCompose);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("register local instance rejects missing instance directories", async () => {
  const dir = await mkdtemp(join(tmpdir(), "openclaw-register-local-instance-"));
  try {
    const { deployDir, registryFile, composeFile, configFile, newWorkspace } = await writeFixture(dir);
    await writeFile(
      configFile,
      `${JSON.stringify(
        {
          schemaVersion: 1,
          server: { id: "tom-oracle", name: "Tom Oracle" },
          instance: {
            id: "missing",
            name: "Missing",
            gatewayUrl: "ws://host.docker.internal:18801",
            configDir: join(dir, "does-not-exist", "config"),
            workspaceDir: newWorkspace,
          },
        },
        null,
        2,
      )}\n`,
      "utf8",
    );
    const result = spawnSync(SCRIPT, ["plan", configFile], {
      env: { ...process.env, DEPLOY_DIR: deployDir, REGISTRY_FILE: registryFile, COMPOSE_FILE: composeFile },
      encoding: "utf8",
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /instance\.configDir/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
