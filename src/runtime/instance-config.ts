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

    const openclawHome = readTrimmedString(entry.openclawHome) ?? join(homedir(), ".openclaw");
    const gatewayUrl = readTrimmedString(entry.gatewayUrl) ?? DEFAULT_GATEWAY_URL;
    const openclawConfigPath = readTrimmedString(entry.openclawConfigPath) ?? join(openclawHome, "openclaw.json");
    const workspaceRoot = readTrimmedString(entry.workspaceRoot);

    instances.push({
      id,
      label: readTrimmedString(entry.label) ?? id,
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
  const workspaceRoot = readTrimmedString(env.OPENCLAW_WORKSPACE_ROOT);
  return {
    source: "fallback",
    issues: [],
    instances: [
      {
        id: "default",
        label: "default",
        gatewayUrl: readTrimmedString(env.GATEWAY_URL) ?? DEFAULT_GATEWAY_URL,
        openclawHome,
        openclawConfigPath: join(openclawHome, "openclaw.json"),
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
