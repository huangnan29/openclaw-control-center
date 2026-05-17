import { readdir, readFile, stat } from "node:fs/promises";
import { basename, join } from "node:path";
import type { RuntimeLogEntry, RuntimeLogSeverity, RuntimeLogSnapshot } from "../types";

interface RuntimeLogInput {
  workspaceRoot?: string;
  openclawHome?: string;
  openclawConfigPath?: string;
  limit?: number;
}

const LOG_FILE_EXTENSIONS = new Set([".log", ".jsonl"]);
const MAX_LOG_FILE_BYTES = 64 * 1024;
const DEFAULT_LOG_LIMIT = 80;

export async function loadRuntimeLogs(input: RuntimeLogInput = {}): Promise<RuntimeLogSnapshot> {
  const limit = input.limit ?? DEFAULT_LOG_LIMIT;
  const candidateDirs = buildRuntimeLogCandidateDirs(input);
  const files = await collectRuntimeLogFiles(candidateDirs);

  if (files.length === 0) {
    return {
      status: "not_connected",
      sourcePaths: [],
      detail: "no runtime log files found.",
      entries: [],
    };
  }

  const entryGroups = await Promise.all(files.map((file) => readRuntimeLogFile(file)));
  const entries = entryGroups.flat().sort((a, b) => Date.parse(b.timestamp) - Date.parse(a.timestamp)).slice(0, limit);

  return {
    status: entries.length > 0 ? "connected" : "partial",
    sourcePaths: files,
    detail: entries.length > 0
      ? `loaded ${entries.length} runtime log event(s) from ${files.length} file(s).`
      : `found ${files.length} runtime log file(s), but no parseable events.`,
    entries,
  };
}

function buildRuntimeLogCandidateDirs(input: RuntimeLogInput): string[] {
  const roots = [
    input.workspaceRoot,
    input.openclawHome,
    input.openclawConfigPath ? input.openclawConfigPath.replace(/\/[^/]*$/, "") : undefined,
  ]
    .map((item) => item?.trim())
    .filter((item): item is string => Boolean(item));

  const dirs = new Set<string>();
  for (const root of roots) {
    dirs.add(join(root, "runtime", "logs"));
    dirs.add(join(root, "logs"));
    dirs.add(join(root, "runtime"));
  }
  return [...dirs];
}

async function collectRuntimeLogFiles(candidateDirs: string[]): Promise<string[]> {
  const files = new Set<string>();
  await Promise.all(candidateDirs.map((dir) => collectRuntimeLogFilesFromDir(dir, files)));
  return [...files].sort();
}

async function collectRuntimeLogFilesFromDir(dir: string, files: Set<string>): Promise<void> {
  try {
    const entries = await readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      if (!entry.isFile()) continue;
      const path = join(dir, entry.name);
      const extension = entry.name.slice(entry.name.lastIndexOf("."));
      if (LOG_FILE_EXTENSIONS.has(extension)) files.add(path);
    }
  } catch {
    return;
  }
}

async function readRuntimeLogFile(path: string): Promise<RuntimeLogEntry[]> {
  try {
    const file = await stat(path);
    const raw = await readFile(path, "utf8");
    const tail = raw.length > MAX_LOG_FILE_BYTES ? raw.slice(raw.length - MAX_LOG_FILE_BYTES) : raw;
    const fallbackTimestamp = new Date(file.mtimeMs).toISOString();
    return tail
      .split(/\r?\n/)
      .map((line) => parseRuntimeLogLine(line, path, fallbackTimestamp))
      .filter((entry): entry is RuntimeLogEntry => Boolean(entry));
  } catch {
    return [];
  }
}

function parseRuntimeLogLine(line: string, sourcePath: string, fallbackTimestamp: string): RuntimeLogEntry | undefined {
  const trimmed = line.trim();
  if (!trimmed) return undefined;
  if (trimmed.startsWith("{")) {
    const parsed = parseJsonLogLine(trimmed, sourcePath, fallbackTimestamp);
    if (parsed) return parsed;
  }
  return parseTextLogLine(trimmed, sourcePath, fallbackTimestamp);
}

function parseJsonLogLine(line: string, sourcePath: string, fallbackTimestamp: string): RuntimeLogEntry | undefined {
  try {
    const obj = JSON.parse(line) as Record<string, unknown>;
    const timestamp = parseTimestampField(obj.timestamp) ?? parseTimestampField(obj.time) ?? parseTimestampField(obj.createdAt) ?? fallbackTimestamp;
    const severity = normalizeSeverity(asString(obj.level) ?? asString(obj.severity) ?? asString(obj.status));
    const message = asString(obj.message) ?? asString(obj.msg) ?? asString(obj.detail) ?? asString(obj.event) ?? line;
    return {
      timestamp,
      severity,
      sourcePath,
      message,
    };
  } catch {
    return undefined;
  }
}

function parseTextLogLine(line: string, sourcePath: string, fallbackTimestamp: string): RuntimeLogEntry {
  const match = line.match(/^\[?(\d{4}-\d{2}-\d{2}[T ][0-9:.+-]+Z?)\]?\s*(.*)$/);
  const timestamp = parseTimestampField(match?.[1]) ?? fallbackTimestamp;
  const rest = (match?.[2] ?? line).trim();
  const severity = normalizeSeverity(rest.split(/\s+/)[0]);
  const message = stripLeadingSeverity(rest);
  return {
    timestamp,
    severity,
    sourcePath,
    message: message || `${basename(sourcePath)} event`,
  };
}

function parseTimestampField(value: unknown): string | undefined {
  if (typeof value !== "string" || !value.trim()) return undefined;
  const normalized = value.includes("T") ? value : value.replace(" ", "T");
  const parsed = Date.parse(normalized);
  if (Number.isNaN(parsed)) return undefined;
  return new Date(parsed).toISOString();
}

function normalizeSeverity(value: string | undefined): RuntimeLogSeverity {
  const normalized = value?.trim().toLowerCase() ?? "";
  if (normalized.includes("error") || normalized === "err" || normalized === "fatal") return "error";
  if (normalized.includes("warn")) return "warn";
  if (normalized.includes("action")) return "action-required";
  return "info";
}

function stripLeadingSeverity(value: string): string {
  return value.replace(/^(info|warn|warning|error|err|fatal|debug|trace)\b[:\s-]*/i, "").trim();
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}
