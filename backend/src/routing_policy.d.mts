export const routingPolicy: {
  version: number;
  aiGroup: string;
  nativeProxies: string[];
  warpProxies: string[];
};
export function applyRoutingPolicy(input: Record<string, unknown>): Record<string, unknown>;
export function normalizeRoutingContent(content: string): string;
