import type { AgentConfig } from "./config.js";

/**
 * Own keys go straight to their vendor; nothing here goes through a server of ours. A capability
 * with no key has no route: the plans (`codex login`, `claude`) run through their own CLIs instead.
 */
export const ANTHROPIC_VERSION = "2023-06-01";

export const DIRECT_DEFAULTS = {
  openaiModel: "gpt-5.5",
  anthropicModel: "claude-haiku-4-5-20251001",
  realtimeModel: "gpt-realtime",
  transcribeModel: "gpt-4o-mini-transcribe",
} as const;

export interface Route {
  url: string;
  headers: Record<string, string>;
}

type OpenAICreds = Pick<AgentConfig, "openaiApiKey" | "openaiBaseUrl">;
type AnthropicCreds = Pick<AgentConfig, "anthropicApiKey" | "anthropicBaseUrl">;

/** OpenAI capabilities: the person's OpenAI key straight to OpenAI, else null. */
export function openaiRoute(cfg: OpenAICreds, openaiPath: string, extra: Record<string, string> = {}): Route | null {
  if (!cfg.openaiApiKey) return null;
  return { url: cfg.openaiBaseUrl + openaiPath, headers: { ...extra, authorization: `Bearer ${cfg.openaiApiKey}` } };
}

/** Claude capabilities: the person's Anthropic key straight to Anthropic, else null. */
export function anthropicRoute(cfg: AnthropicCreds, extra: Record<string, string> = {}): Route | null {
  if (!cfg.anthropicApiKey) return null;
  return { url: `${cfg.anthropicBaseUrl}/v1/messages`, headers: { ...extra, "x-api-key": cfg.anthropicApiKey, "anthropic-version": ANTHROPIC_VERSION } };
}

/** What a capability with no route needs, said plainly. */
export const needsOpenAI = "needs your own OpenAI key (OPENCLICKY_OPENAI_KEY)";
export const needsAnthropic = "needs your own Anthropic key (OPENCLICKY_ANTHROPIC_KEY)";

/** The OpenAI Realtime client-secret request. */
export function realtimeSecretBody(opts: { voice?: string; instructions?: string; expiresInSeconds?: number }) {
  return {
    expires_after: { anchor: "created_at", seconds: opts.expiresInSeconds ?? 600 },
    session: {
      type: "realtime",
      model: DIRECT_DEFAULTS.realtimeModel,
      ...(opts.instructions ? { instructions: opts.instructions } : {}),
      ...(opts.voice ? { audio: { output: { voice: opts.voice } } } : {}),
    },
  };
}
