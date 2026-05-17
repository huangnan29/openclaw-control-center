import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type {
  OpenClawInstanceConfig,
  OpenClawInstanceConfigIssue,
  OpenClawInstanceConfigLoadResult,
  OpenClawServerConfig,
} from "../types";

const INSTANCE_ID_PATTERN = /^[a-z0-9_-]+$/;
const SERVER_ID_PATTERN = INSTANCE_ID_PATTERN;
const DEFAULT_GATEWAY_URL = "ws://127.0.0.1:18789";

type InstanceConfigEnv = Partial<
  Pick<
    NodeJS.ProcessEnv,
    | "GATEWAY_URL"
    | "OPENCLAW_HOME"
    | "OPENCLAW_CONFIG_PATH"
    | "OPENCLAW_WORKSPACE_ROOT"
    | "OPENCLAW_INSTANCES_FILE"
    | "OPENCLAW_INSTANCES_JSON"
  >
>;

export function parseOpenClawInstanceConfigText(
  text: string,
  source = "inline",
): OpenClawInstanceConfigLoadResult {
  const issues: OpenClawInstanceConfigIssue[] = [];
  const instances: OpenClawInstanceConfig[] = [];
  const servers: OpenClawServerConfig[] = [];
  const seenIds = new Set<string>();
  const seenServerIds = new Set<string>();

  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch (error) {
    return {
      source,
      instances,
      issues: [{ message: `invalid json: ${formatErrorMessage(error)}` }],
    };
  }

  const rootEntries = readRootInstanceEntries(parsed);
  const serverEntries = readServerEntries(parsed, issues);
  if (!rootEntries && !serverEntries) {
    return {
      source,
      instances,
      issues: [{ message: "instances must be an array" }],
    };
  }

  if (rootEntries) {
    collectInstanceConfigs({
      entries: rootEntries,
      instances,
      issues,
      seenIds,
    });
  }

  for (const serverEntry of serverEntries ?? []) {
    if (!isRecord(serverEntry)) {
      issues.push({ message: "server must be an object" });
      continue;
    }

    const server = readServerConfig(serverEntry);
    if (server.issues.length > 0) {
      issues.push(...server.issues);
      continue;
    }

    if (seenServerIds.has(server.config.id)) {
      issues.push({ message: `duplicate server id: ${server.config.id}` });
      continue;
    }
    seenServerIds.add(server.config.id);
    servers.push(server.config);

    const entries = Array.isArray(serverEntry.instances) ? serverEntry.instances : undefined;
    if (!entries) {
      issues.push({ message: `instances must be an array for server id: ${server.config.id}` });
      continue;
    }

    collectInstanceConfigs({
      entries,
      instances,
      issues,
      seenIds,
      server: server.config,
      inheritedGatewayUrl: readTrimmedString(serverEntry.gatewayUrl),
    });
  }

  return { source, ...(servers.length > 0 ? { servers } : {}), instances, issues };
}

function collectInstanceConfigs(input: {
  entries: unknown[];
  instances: OpenClawInstanceConfig[];
  issues: OpenClawInstanceConfigIssue[];
  seenIds: Set<string>;
  server?: OpenClawServerConfig;
  inheritedGatewayUrl?: string;
}): void {
  for (const entry of input.entries) {
    if (!isRecord(entry)) {
      input.issues.push({ message: "instance must be an object" });
      continue;
    }

    const id = readTrimmedString(entry.id);
    if (!id || !INSTANCE_ID_PATTERN.test(id)) {
      input.issues.push({ message: `invalid id: ${id ?? String(entry.id)}` });
      continue;
    }

    if (input.seenIds.has(id)) {
      input.issues.push({ message: `duplicate id: ${id}` });
      continue;
    }

    input.seenIds.add(id);

    const instanceIssues = validateInstanceEntry(entry, id);
    if (instanceIssues.length > 0) {
      input.issues.push(...instanceIssues);
      continue;
    }

    const name = readTrimmedString(entry.name) ?? readTrimmedString(entry.label) ?? id;
    const openclawHome = readTrimmedString(entry.openclawHome) as string;
    const gatewayUrl = readTrimmedString(entry.gatewayUrl) ?? input.inheritedGatewayUrl ?? DEFAULT_GATEWAY_URL;
    const openclawConfigPath = readTrimmedString(entry.openclawConfigPath) ?? join(openclawHome, "openclaw.json");
    const workspaceRoot = readTrimmedString(entry.workspaceRoot);

    input.instances.push({
      id,
      name,
      ...(input.server
        ? {
            serverId: input.server.id,
            serverName: input.server.name,
            ...(input.server.host ? { serverHost: input.server.host } : {}),
            ...(input.server.region ? { serverRegion: input.server.region } : {}),
          }
        : {}),
      gatewayUrl,
      openclawHome,
      openclawConfigPath,
      ...(workspaceRoot ? { workspaceRoot } : {}),
      readonly: readBoolean(entry.readonly, true),
    });
  }
}

export function loadOpenClawInstanceConfigs(
  env: InstanceConfigEnv = process.env,
): OpenClawInstanceConfigLoadResult {
  const instancesFile = readTrimmedString(env.OPENCLAW_INSTANCES_FILE);
  if (instancesFile) {
    try {
      return parseOpenClawInstanceConfigText(readFileSync(instancesFile, "utf8"), instancesFile);
    } catch (error) {
      return {
        source: instancesFile,
        instances: [],
        issues: [{ message: `failed to read instances file: ${formatErrorMessage(error)}` }],
      };
    }
  }

  const instancesJson = readTrimmedString(env.OPENCLAW_INSTANCES_JSON);
  if (instancesJson) {
    return parseOpenClawInstanceConfigText(instancesJson, "OPENCLAW_INSTANCES_JSON");
  }

  const openclawHome = readTrimmedString(env.OPENCLAW_HOME) ?? join(homedir(), ".openclaw");
  const openclawConfigPath = readTrimmedString(env.OPENCLAW_CONFIG_PATH) ?? join(openclawHome, "openclaw.json");
  const workspaceRoot = readTrimmedString(env.OPENCLAW_WORKSPACE_ROOT);
  return {
    source: "fallback",
    issues: [],
    instances: [
      {
        id: "default",
        name: "default",
        gatewayUrl: readTrimmedString(env.GATEWAY_URL) ?? DEFAULT_GATEWAY_URL,
        openclawHome,
        openclawConfigPath,
        ...(workspaceRoot ? { workspaceRoot } : {}),
        readonly: true,
      },
    ],
  };
}

function readRootInstanceEntries(parsed: unknown): unknown[] | undefined {
  if (Array.isArray(parsed)) return parsed;
  if (isRecord(parsed) && Array.isArray(parsed.instances)) return parsed.instances;
  return undefined;
}

function readServerEntries(parsed: unknown, issues: OpenClawInstanceConfigIssue[]): unknown[] | undefined {
  if (!isRecord(parsed) || parsed.servers === undefined) return undefined;
  if (Array.isArray(parsed.servers)) return parsed.servers;
  issues.push({ message: "servers must be an array" });
  return undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function validateInstanceEntry(entry: Record<string, unknown>, id: string): OpenClawInstanceConfigIssue[] {
  const issues: OpenClawInstanceConfigIssue[] = [];
  if (entry.name !== undefined && readTrimmedString(entry.name) === undefined) {
    issues.push({ message: `invalid name for id: ${id}` });
  } else if (entry.name === undefined && entry.label !== undefined && readTrimmedString(entry.label) === undefined) {
    issues.push({ message: `invalid name for id: ${id}` });
  } else if (entry.name === undefined && entry.label === undefined) {
    issues.push({ message: `missing name for id: ${id}` });
  }

  if (entry.openclawHome === undefined) {
    issues.push({ message: `missing openclawHome for id: ${id}` });
  } else if (readTrimmedString(entry.openclawHome) === undefined) {
    issues.push({ message: `invalid openclawHome for id: ${id}` });
  }

  if (entry.gatewayUrl !== undefined && readTrimmedString(entry.gatewayUrl) === undefined) {
    issues.push({ message: `invalid gatewayUrl for id: ${id}` });
  }

  if (entry.workspaceRoot !== undefined && readTrimmedString(entry.workspaceRoot) === undefined) {
    issues.push({ message: `invalid workspaceRoot for id: ${id}` });
  }

  return issues;
}

function readServerConfig(entry: Record<string, unknown>): { config: OpenClawServerConfig; issues: OpenClawInstanceConfigIssue[] } {
  const issues: OpenClawInstanceConfigIssue[] = [];
  const id = readTrimmedString(entry.id);
  if (!id || !SERVER_ID_PATTERN.test(id)) {
    issues.push({ message: `invalid server id: ${id ?? String(entry.id)}` });
  }

  const name = readTrimmedString(entry.name) ?? readTrimmedString(entry.label);
  if (!name) {
    issues.push({ message: `missing server name for id: ${id ?? String(entry.id)}` });
  }

  if (entry.host !== undefined && readTrimmedString(entry.host) === undefined) {
    issues.push({ message: `invalid host for server id: ${id ?? String(entry.id)}` });
  }
  if (entry.region !== undefined && readTrimmedString(entry.region) === undefined) {
    issues.push({ message: `invalid region for server id: ${id ?? String(entry.id)}` });
  }
  if (entry.description !== undefined && readTrimmedString(entry.description) === undefined) {
    issues.push({ message: `invalid description for server id: ${id ?? String(entry.id)}` });
  }
  if (entry.gatewayUrl !== undefined && readTrimmedString(entry.gatewayUrl) === undefined) {
    issues.push({ message: `invalid gatewayUrl for server id: ${id ?? String(entry.id)}` });
  }

  return {
    config: {
      id: id ?? "",
      name: name ?? id ?? "",
      ...(readTrimmedString(entry.host) ? { host: readTrimmedString(entry.host) } : {}),
      ...(readTrimmedString(entry.region) ? { region: readTrimmedString(entry.region) } : {}),
      ...(readTrimmedString(entry.description) ? { description: readTrimmedString(entry.description) } : {}),
    },
    issues,
  };
}

function readTrimmedString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed === "" ? undefined : trimmed;
}

function readBoolean(value: unknown, fallback: boolean): boolean {
  return typeof value === "boolean" ? value : fallback;
}

function formatErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
