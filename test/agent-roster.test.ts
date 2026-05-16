import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

test("agent roster treats openclaw.json as the current-project source of truth", async () => {
  const home = await mkdtemp(join(tmpdir(), "control-center-roster-"));
  const originalHome = process.env.OPENCLAW_HOME;
  const originalConfigPath = process.env.OPENCLAW_CONFIG_PATH;

  try {
    await mkdir(join(home, "agents", "pandas"), { recursive: true });
    await mkdir(join(home, "agents", "otter"), { recursive: true });
    await writeFile(
      join(home, "openclaw.json"),
      JSON.stringify(
        {
          agents: {
            list: [
              { id: "main", name: "main" },
              { id: "pandas", name: "pandas" },
            ],
          },
        },
        null,
        2,
      ),
      "utf8",
    );

    process.env.OPENCLAW_HOME = home;
    delete process.env.OPENCLAW_CONFIG_PATH;

    const { loadBestEffortAgentRoster } = await import("../src/runtime/agent-roster");
    const roster = await loadBestEffortAgentRoster();

    assert.equal(roster.status, "connected");
    assert.equal(roster.entries.length, 2);
    assert(roster.entries.some((entry) => entry.agentId === "main"));
    assert(roster.entries.some((entry) => entry.agentId === "pandas"));
    assert(!roster.entries.some((entry) => entry.agentId === "otter"));
    assert(roster.detail.includes("source of truth"));
  } finally {
    if (originalHome === undefined) delete process.env.OPENCLAW_HOME;
    else process.env.OPENCLAW_HOME = originalHome;
    if (originalConfigPath === undefined) delete process.env.OPENCLAW_CONFIG_PATH;
    else process.env.OPENCLAW_CONFIG_PATH = originalConfigPath;
    await rm(home, { recursive: true, force: true });
  }
});

test("agent roster stays connected from runtime when openclaw.json is missing", async () => {
  const home = await mkdtemp(join(tmpdir(), "control-center-roster-runtime-"));
  const originalHome = process.env.OPENCLAW_HOME;
  const originalConfigPath = process.env.OPENCLAW_CONFIG_PATH;

  try {
    await mkdir(join(home, "agents", "monkey"), { recursive: true });
    await mkdir(join(home, "agents", "tiger"), { recursive: true });

    process.env.OPENCLAW_HOME = home;
    delete process.env.OPENCLAW_CONFIG_PATH;

    const { loadBestEffortAgentRoster } = await import("../src/runtime/agent-roster");
    const roster = await loadBestEffortAgentRoster();

    assert.equal(roster.status, "connected");
    assert.equal(roster.entries.length, 2);
    assert(roster.entries.some((entry) => entry.agentId === "monkey"));
    assert(roster.entries.some((entry) => entry.agentId === "tiger"));
  } finally {
    if (originalHome === undefined) delete process.env.OPENCLAW_HOME;
    else process.env.OPENCLAW_HOME = originalHome;
    if (originalConfigPath === undefined) delete process.env.OPENCLAW_CONFIG_PATH;
    else process.env.OPENCLAW_CONFIG_PATH = originalConfigPath;
    await rm(home, { recursive: true, force: true });
  }
});

test("agent roster ignores name-only config entries and falls back to runtime agent ids", async () => {
  const home = await mkdtemp(join(tmpdir(), "control-center-roster-name-only-"));
  const originalHome = process.env.OPENCLAW_HOME;
  const originalConfigPath = process.env.OPENCLAW_CONFIG_PATH;

  try {
    await mkdir(join(home, "agents", "main"), { recursive: true });
    await mkdir(join(home, "agents", "pandas"), { recursive: true });
    await writeFile(
      join(home, "openclaw.json"),
      JSON.stringify(
        {
          agents: {
            list: [
              { name: "architect-agent" },
            ],
          },
        },
        null,
        2,
      ),
      "utf8",
    );

    process.env.OPENCLAW_HOME = home;
    delete process.env.OPENCLAW_CONFIG_PATH;

    const { loadBestEffortAgentRoster } = await import("../src/runtime/agent-roster");
    const roster = await loadBestEffortAgentRoster();

    assert.equal(roster.status, "partial");
    assert.equal(roster.entries.length, 2);
    assert(roster.entries.some((entry) => entry.agentId === "main"));
    assert(roster.entries.some((entry) => entry.agentId === "pandas"));
    assert(!roster.entries.some((entry) => entry.agentId === "architect-agent"));
    assert.match(roster.detail, /missing id/i);
  } finally {
    if (originalHome === undefined) delete process.env.OPENCLAW_HOME;
    else process.env.OPENCLAW_HOME = originalHome;
    if (originalConfigPath === undefined) delete process.env.OPENCLAW_CONFIG_PATH;
    else process.env.OPENCLAW_CONFIG_PATH = originalConfigPath;
    await rm(home, { recursive: true, force: true });
  }
});

test("current agent catalog can load from explicit scoped paths", async () => {
  const home = await mkdtemp(join(tmpdir(), "control-center-catalog-scope-"));
  const configPath = join(home, "custom-openclaw.json");

  try {
    await writeFile(
      configPath,
      JSON.stringify(
        {
          agents: {
            list: [
              { id: "main", name: "main" },
              { id: "qa", name: "qa" },
            ],
          },
        },
        null,
        2,
      ),
      "utf8",
    );

    const { loadCurrentAgentCatalog } = await import("../src/runtime/current-agent-catalog");
    const catalog = await loadCurrentAgentCatalog({ openclawHome: home, configPath });

    assert.equal(catalog.status, "connected");
    assert.deepEqual(catalog.entries.map((entry) => entry.agentId), ["main", "qa"]);
    assert.equal(catalog.sourcePath, configPath);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});
