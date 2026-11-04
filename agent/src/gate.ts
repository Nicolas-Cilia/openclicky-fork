import type { AgentConfig } from "./config.js";
import { anthropicRoute, DIRECT_DEFAULTS } from "./providerRoute.js";

/**
 * The cheap "gate" in front of every launch (HeyClicky's Haiku launch-label gate): decide whether a
 * request is a quick question for the ask lane or real work for a Codex agent thread.
 */
export type Lane = "ask" | "agent";
export interface GateDecision {
  lane: Lane;
  reason: string;
  /** false when the gate could not run and the default lane was used. */
  gated: boolean;
}

export const GATE_SYSTEM_PROMPT = `You are OpenClicky's launch gate. Classify the user's request into exactly one lane:
- "ask": a question, explanation, opinion, translation, summary of provided text, or anything answerable in a short spoken reply with no files, tools, apps, or web work.
- "agent": anything that requires doing work: creating/editing files or code, running commands, research with sources, using apps or integrations, multi-step tasks, or anything referring to "my" files/repo/project.
Reply with ONLY a JSON object: {"lane":"ask"|"agent","reason":"<one short sentence>"}`;

export function parseGateReply(text: string): { lane: Lane; reason: string } | undefined {
  const m = /\{[\s\S]*\}/.exec(text);
  if (!m) return undefined;
  try {
    const j = JSON.parse(m[0]);
    if (j.lane === "ask" || j.lane === "agent") return { lane: j.lane, reason: String(j.reason ?? "") };
  } catch {
    /* fall through */
  }
  return undefined;
}

/** What people say before the request itself: "hey clicky, okay so…". */
const SPOKEN_OPENING = /^(?:(?:hey|hi|hello|ok|okay|um+|uh+|so|well|yeah|right|alright|clicky|openclicky)\b[,.!\s]*)+/;
/** Asking for the work: "please", "can you"… (but not "can I", which asks how). */
const REQUEST_OPENING = /^(?:(?:please|can you|could you|would you|will you|i need you to|i want you to|go ahead and)\s+)+/;
/** Starting with one of these, it is work to do rather than something to explain. */
const WORK_VERB = /^(?:create|make|write|edit|fix|add|remove|delete|run|build|deploy|install|refactor|rename|move|research|commit|push|draft|generate|update|download|convert|organi[sz]e|set up|clean up|search the web)\b/;

/**
 * Local heuristic used when the gate model is unavailable, which is whenever someone is on their
 * plans with no Anthropic key. Errs toward the ask lane: only it points, guides step by step and
 * writes for the ear, and it can still do quick actions. So only a request that opens with the work
 * goes to an agent. "how do I fix my repo" asks; "fix my repo" and "can you fix my repo" are work.
 */
export function heuristicLane(text: string): Lane {
  const request = text.trim().toLowerCase().replace(SPOKEN_OPENING, "").replace(REQUEST_OPENING, "");
  return WORK_VERB.test(request) ? "agent" : "ask";
}

export async function gate(cfg: AgentConfig, text: string, opts: { fetchImpl?: typeof fetch } = {}): Promise<GateDecision> {
  const f = opts.fetchImpl ?? fetch;
  // Claude decides the lane when the person has an Anthropic key; otherwise the local heuristic does.
  const route = anthropicRoute(cfg, { "content-type": "application/json" });
  if (!route) return { lane: heuristicLane(text), reason: "no anthropic key; heuristic", gated: false };
  try {
    const res = await f(route.url, {
      method: "POST",
      headers: route.headers,
      body: JSON.stringify({
        model: DIRECT_DEFAULTS.anthropicModel,
        max_tokens: 80,
        system: GATE_SYSTEM_PROMPT,
        messages: [{ role: "user", content: text }],
      }),
    });
    if (!res.ok) return { lane: heuristicLane(text), reason: `gate unavailable (anthropic ${res.status}); heuristic`, gated: false };
    const json: any = await res.json();
    const reply = (json.content ?? []).filter((c: any) => c.type === "text").map((c: any) => c.text).join("\n");
    const parsed = parseGateReply(reply);
    if (!parsed) return { lane: heuristicLane(text), reason: "gate reply unparseable; heuristic", gated: false };
    return { ...parsed, gated: true };
  } catch (e) {
    return { lane: heuristicLane(text), reason: `gate error (${(e as Error).message}); heuristic`, gated: false };
  }
}
