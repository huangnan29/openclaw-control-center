import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

export type CurrentAgentCatalogStatus = "connected" | "partial" | "not_connected";

export interface CurrentAgentCatalogEntry {
  agentId: string;
  displayName: string;
}

export interface CurrentAgentCatalog {
  status: CurrentAgentCatalogStatus;
  sourcePath: string;
  detail: string;
  entries: CurrentAgentCatalogEntry[];
}

export interface CurrentAgentCatalogInput {
  openclawHome?: string;
  configPath?: string;
}

export async function loadCurrentAgentCatalog(input: CurrentAgentCatalogInput = {}): Promise<CurrentAgentCatalog> {
  const sourcePath = resolveOpenClawConfigPath(input);

  try {
    const raw = JSON.parse(await readFile(sourcePath, "utf8")) as unknown;
    const root = asObject(raw) ?? {};
    const agents = asObject(root.agents) ?? {};
    const list = asArray(agents.list);
    const merged = new Map<string, CurrentAgentCatalogEntry>();
    let skippedNameOnlyEntries = 0;

    for (const item of list) {
      const obj = asObject(item);
      if (!obj) continue;
      const agentId = asString(obj.id)?.trim();
      if (!agentId) {
        if (asString(obj.name)?.trim()) skippedNameOnlyEntries += 1;
        continue;
      }
      const key = normalizeKey(agentId);
      if (merged.has(key)) continue;
      merged.set(key, {
        agentId,
        displayName: asString(obj.name)?.trim() || agentId,
      });
    }

    const entries = [...merged.values()].sort((a, b) => a.agentId.localeCompare(b.agentId));
    if (entries.length === 0) {
      return {
        status: "partial",
        sourcePath,
        detail: skippedNameOnlyEntries > 0
          ? `openclaw.json found but ${skippedNameOnlyEntries} agent entr${skippedNameOnlyEntries === 1 ? "y is" : "ies are"} missing id.`
          : "openclaw.json found but agents.list is empty.",
        entries: [],
      };
    }

    return {
      status: "connected",
      sourcePath,
      detail: `loaded ${entries.length} current agent(s) from openclaw.json.${skippedNameOnlyEntries > 0 ? ` Skipped ${skippedNameOnlyEntries} name-only entr${skippedNameOnlyEntries === 1 ? "y" : "ies"} without id.` : ""}`,
      entries,
    };
  } catch (error) {
    if (isFsNotFound(error)) {
      return {
        status: "not_connected",
        sourcePath,
        detail: "openclaw.json not found.",
        entries: [],
      };
    }
    return {
      status: "partial",
      sourcePath,
      detail: "openclaw.json exists but could not be parsed.",
      entries: [],
    };
  }
}

export function resolveOpenClawHomePath(input: CurrentAgentCatalogInput = {}): string {
  return input.openclawHome?.trim() || process.env.OPENCLAW_HOME?.trim() || join(homedir(), ".openclaw");
}

export function resolveOpenClawConfigPath(input: CurrentAgentCatalogInput = {}): string {
  const scoped = input.configPath?.trim();
  if (scoped) return scoped;
  const explicit = process.env.OPENCLAW_CONFIG_PATH?.trim();
  if (explicit) return explicit;
  return join(resolveOpenClawHomePath(input), "openclaw.json");
}

function isFsNotFound(error: unknown): boolean {
  return Boolean(
    error &&
      typeof error === "object" &&
      "code" in error &&
      typeof (error as { code?: unknown }).code === "string" &&
      (error as { code: string }).code === "ENOENT",
  );
}

function normalizeKey(input: string): string {
  return input.trim().toLowerCase();
}

function asObject(input: unknown): Record<string, unknown> | undefined {
  return input !== null && typeof input === "object" && !Array.isArray(input)
    ? (input as Record<string, unknown>)
    : undefined;
}

function asArray(input: unknown): unknown[] {
  return Array.isArray(input) ? input : [];
}

function asString(input: unknown): string | undefined {
  return typeof input === "string" ? input : undefined;
}
