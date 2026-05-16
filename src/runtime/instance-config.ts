import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type {
  OpenClawInstanceConfig,
  OpenClawInstanceConfigIssue,
  OpenClawInstanceConfigLoadResult,
} from "../types";

const INSTANCE_ID_PATTERN = /^[a-z0-9_-]+$/;
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
  const seenIds = new Set<string>();

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

  const entries = readInstanceEntries(parsed);
  if (!entries) {
    return {
      source,
      instances,
      issues: [{ message: "instances must be an array" }],
    };
  }

  for (const entry of entries) {
    if (!isRecord(entry)) {
      issues.push({ message: "instance must be an object" });
      continue;
    }

    const id = readTrimmedString(entry.id);
    if (!id || !INSTANCE_ID_PATTERN.test(id)) {
      issues.push({ message: `invalid id: ${id ?? String(entry.id)}` });
      continue;
    }

    if (seenIds.has(id)) {
      issues.push({ message: `duplicate id: ${id}` });
      continue;
    }

    seenIds.add(id);

    const instanceIssues = validateInstanceEntry(entry, id);
    if (instanceIssues.length > 0) {
      issues.push(...instanceIssues);
      continue;
    }

    const name = readTrimmedString(entry.name) ?? readTrimmedString(entry.label) ?? id;
    const openclawHome = readTrimmedString(entry.openclawHome) as string;
    const gatewayUrl = readTrimmedString(entry.gatewayUrl) ?? DEFAULT_GATEWAY_URL;
    const openclawConfigPath = readTrimmedString(entry.openclawConfigPath) ?? join(openclawHome, "openclaw.json");
    const workspaceRoot = readTrimmedString(entry.workspaceRoot);

    instances.push({
      id,
      name,
      gatewayUrl,
      openclawHome,
      openclawConfigPath,
      ...(workspaceRoot ? { workspaceRoot } : {}),
      readonly: readBoolean(entry.readonly, true),
    });
  }

  return { source, instances, issues };
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

function readInstanceEntries(parsed: unknown): unknown[] | undefined {
  if (Array.isArray(parsed)) return parsed;
  if (isRecord(parsed) && Array.isArray(parsed.instances)) return parsed.instances;
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
