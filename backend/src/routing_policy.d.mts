export const routingPolicy: {
  version: number;
  aiGroup: string;
};
export function applyRoutingPolicy(input: Record<string, unknown>): Record<string, unknown>;
export function normalizeRoutingContent(content: string): string;

export function normalizePushedAiContent(content: string): string;
