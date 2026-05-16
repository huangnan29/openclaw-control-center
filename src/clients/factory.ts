import { OpenClawLiveClient } from "./openclaw-live-client";
import type { ToolClient } from "./tool-client";
import type { OpenClawInstanceConfig } from "../types";

export function createToolClient(): ToolClient {
  return new OpenClawLiveClient();
}

export function createScopedToolClient(instance: OpenClawInstanceConfig): ToolClient {
  const scope = {
    openclawHome: instance.openclawHome,
    openclawConfigPath: instance.openclawConfigPath,
    workspaceRoot: instance.workspaceRoot,
    gatewayUrl: instance.gatewayUrl,
  };
  return new OpenClawLiveClient(scope);
}
