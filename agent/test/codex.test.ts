/**
 * Unit tests for codex.ts that don't need a real Codex binary: they point `codexBin` at
 * test/fixtures/fake-codex.mjs, a minimal JSON-RPC app-server stand-in (see integration.test.ts for
 * the equivalent tests against the real binary).
 */
import { describe, it, expect } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { CodexAgent, buildChildEnv, addTokenUsage, threadsPastLimit } from "../src/codex.js";
import { resolveConfig } from "../src/config.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const fakeCodex = path.join(here, "fixtures", "fake-codex.mjs");

// Codex's child env is now an explicit allowlist (buildChildEnv), so the fake binary can't just read
// an arbitrary env var a test sets — it reads its scenario from a file under CODEX_HOME instead
// (see fake-codex.mjs), which is always present since CODEX_HOME is one of the explicitly-set vars.
function mkCfg(overrides: Partial<Parameters<typeof resolveConfig>[0]> = {}, scenario?: string) {
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "oc-codex-home-"));
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), "oc-codex-ws-"));
  const userSkillsDir = fs.mkdtempSync(path.join(os.tmpdir(), "oc-codex-skills-"));
  if (scenario) fs.writeFileSync(path.join(codexHome, "fake-scenario.txt"), scenario);
  return resolveConfig({ codexHome, workspace, userSkillsDir, codexBin: fakeCodex, openaiBaseUrl: "http://127.0.0.1:1", ...overrides });
}

describe("buildChildEnv", () => {
  it("carries PATH but not an unrelated secret sitting in the shell", () => {
    const cfg = mkCfg();
    const env = buildChildEnv(cfg, { PATH: "/usr/bin", AWS_SECRET_ACCESS_KEY: "super-secret", HOME: "/home/x" });
    expect(env.PATH).toBe("/usr/bin");
    expect(env.HOME).toBe("/home/x");
    expect(env.AWS_SECRET_ACCESS_KEY).toBeUndefined();
  });

  it("carries NODE_* and proxy variables through", () => {
    const cfg = mkCfg();
    const env = buildChildEnv(cfg, { NODE_OPTIONS: "--max-old-space-size=4096", HTTPS_PROXY: "http://proxy:8080", no_proxy: "localhost" });
    expect(env.NODE_OPTIONS).toBe("--max-old-space-size=4096");
    expect(env.HTTPS_PROXY).toBe("http://proxy:8080");
    expect(env.no_proxy).toBe("localhost");
  });

  it("sets the OpenClicky variables config.toml references from cfg, never from the shell", () => {
    const cfg = mkCfg({ openaiApiKey: "oai-key", anthropicApiKey: "anth-key", composioApiKey: "ck_test" });
    // A shell OPENAI_API_KEY must never reach the child: a run uses only the key set for OpenClicky.
    const env = buildChildEnv(cfg, { OPENAI_API_KEY: "shell-openai-key", ANTHROPIC_API_KEY: "shell-anthropic-key" });
    expect(env.CODEX_HOME).toBe(cfg.codexHome);
    expect(env.OPENCLICKY_OPENAI_KEY).toBe("oai-key");
    expect(env.OPENCLICKY_ANTHROPIC_KEY).toBeUndefined();
    expect(env.COMPOSIO_API_KEY).toBe("ck_test");
    expect(env.OPENAI_API_KEY).toBeUndefined();
    expect(env.ANTHROPIC_API_KEY).toBeUndefined();
  });
});

describe("CodexAgent.run timeout and error handling (fake codex)", () => {
  it("rejects with a clear message instead of hanging forever when no terminal event ever arrives", async () => {
    const cfg = mkCfg({}, "hang");
    const agent = new CodexAgent(cfg);
    try {
      await agent.start();
      await expect(agent.run("do something", { timeoutMs: 200 })).rejects.toThrow(/timed out after 200ms/);
    } finally {
      await agent.stop();
    }
  }, 15_000);

  it("clears a retried error's message once the turn goes on to complete successfully", async () => {
    const cfg = mkCfg({}, "retry-then-complete");
    const agent = new CodexAgent(cfg);
    try {
      await agent.start();
      const result = await agent.run("do something");
      expect(result.status).toBe("completed");
      expect(result.finalMessage).toBe("done after retry");
      // The transient, retried "error" notification must not leak into a result that went on to
      // complete cleanly — see the finding this guards against: a stale error on an otherwise-fine run.
      expect(result.error).toBeUndefined();
    } finally {
      await agent.stop();
    }
  }, 15_000);

  it("still surfaces the turn's own error when the turn genuinely fails", async () => {
    const cfg = mkCfg({}, "fail-turn");
    const agent = new CodexAgent(cfg);
    try {
      await agent.start();
      const result = await agent.run("do something");
      expect(result.status).toBe("failed");
      expect(result.error).toBe("boom");
    } finally {
      await agent.stop();
    }
  }, 15_000);

  it("honors cfg.runTimeoutMs as the default when no per-call override is given", async () => {
    const cfg = mkCfg({ runTimeoutMs: 150 }, "hang");
    const agent = new CodexAgent(cfg);
    try {
      await agent.start();
      await expect(agent.run("do something")).rejects.toThrow(/timed out after 150ms/);
    } finally {
      await agent.stop();
    }
  }, 15_000);
});

describe("addTokenUsage", () => {
  it("adds each model call to the turn's counts", () => {
    const one = addTokenUsage(undefined, { inputTokens: 10, cachedInputTokens: 4, outputTokens: 2 });
    expect(addTokenUsage(one, { inputTokens: 5, cachedInputTokens: 1, outputTokens: 3 })).toEqual({ inputTokens: 15, cachedInputTokens: 5, outputTokens: 5 });
    expect(addTokenUsage(undefined, undefined)).toBeUndefined();
  });
});

describe("threadsPastLimit", () => {
  const now = Date.UTC(2026, 10, 30);
  const daysAgo = (d: number) => now / 1000 - d * 86_400;
  it("picks threads last touched before the limit", () => {
    const threads = [{ id: "new", updatedAt: daysAgo(13) }, { id: "old", updatedAt: daysAgo(15) }, { id: "edge", updatedAt: daysAgo(14) }];
    expect(threadsPastLimit(threads, 14, now)).toEqual(["old"]);
  });
  it("goes by the last touch, not the start", () => {
    expect(threadsPastLimit([{ id: "resumed", createdAt: daysAgo(99), updatedAt: daysAgo(1) }], 14, now)).toEqual([]);
    expect(threadsPastLimit([{ id: "only-created", createdAt: daysAgo(99) }], 14, now)).toEqual(["only-created"]);
  });
  it("never picks a running thread or one with no dates", () => {
    expect(threadsPastLimit([{ id: "running", updatedAt: daysAgo(99), status: { type: "active" } }, { id: "undated" }], 14, now)).toEqual([]);
  });
  it("keeps everything at zero", () => {
    expect(threadsPastLimit([{ id: "old", updatedAt: daysAgo(999) }], 0, now)).toEqual([]);
  });
});
