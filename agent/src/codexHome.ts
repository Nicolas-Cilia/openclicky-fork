import fs from "node:fs";
import path from "node:path";
import type { AgentConfig } from "./config.js";
import { activeDir, syncActiveDir } from "./skillsLibrary.js";

export interface RenderVars {
  root: string;
  /** OpenAI API base for the own-key route. */
  openaiBaseUrl?: string;
  workspace: string;
  model?: string;
  composioMcpUrl?: string;
  composioApiKey?: string;
  cuaDriverBin?: string;
  /** Directory of symlinks to the user's activated skills (see skillsLibrary.ts). */
  userSkillsActive: string;
  /** Directories outside the workspace Codex's sandbox may write to; empty renders no section. */
  writableRoots?: string[];
  /** The person's own OpenAI key is set (OPENCLICKY_OPENAI_KEY); it is never written into config.toml. */
  ownOpenAIKey?: boolean;
}

const tomlString = (s: string) => JSON.stringify(s);

/**
 * Escaped contents of a TOML basic string, without the surrounding quotes. The template embeds
 * {{OPENCLICKY_ROOT}}, {{WORKSPACE}} and {{USER_SKILLS_ACTIVE}} inside its own literal quotes
 * (sometimes alongside more literal text, e.g. a root path followed by "/skills"), so substituting
 * `tomlString(v)` there would double-quote the value. TOML basic strings share JSON's escaping for
 * backslash, quote, and control characters, so stripping JSON.stringify's own quotes gives exactly
 * the escaped text the template's existing quotes need — turning an attacker- or user-influenced
 * path containing a `"` or `\` into safely-escaped text instead of broken or injected TOML.
 */
const tomlStringInner = (s: string) => tomlString(s).slice(1, -1);

/** TOML for the optional MCP servers (mirrors reference/codex-config.toml, keys stay server-side). */
export function renderMcpServers(v: Pick<RenderVars, "composioMcpUrl" | "composioApiKey" | "cuaDriverBin">): string {
  const blocks: string[] = [];
  if (v.composioMcpUrl) {
    blocks.push(
      [
        "[mcp_servers.composio]",
        `url = ${tomlString(v.composioMcpUrl)}`,
        // With a consumer key (COMPOSIO_API_KEY) Codex sends it as Composio's `x-consumer-api-key`
        // header. Without one the server is left to Codex's MCP OAuth: `codex mcp login composio`
        // (run once with this CODEX_HOME; `openclicky integrations login`) stores the token in
        // CODEX_HOME and Composio Connect's login page does the rest.
        ...(v.composioApiKey ? [`http_headers = { "x-consumer-api-key" = ${tomlString(v.composioApiKey)} }`] : []),
        // Codex starts the first turn without waiting for optional servers, so the model would see no
        // Composio tools on the turn that needs them; `required` makes it wait (and fail loudly).
        "required = true",
        // The headless doctrine auto-accepts approvals (the user's instruction is the approval); with
        // approval_policy = "never" Codex would otherwise auto-reject Composio's approval-gated tools.
        'default_tools_approval_mode = "approve"',
        "startup_timeout_sec = 30.0",
        "tool_timeout_sec = 120.0",
      ].join("\n"),
    );
  }
  if (v.cuaDriverBin) {
    blocks.push(
      [
        "[mcp_servers.computer-use]",
        `command = ${tomlString(v.cuaDriverBin)}`,
        'args = ["--socket"]',
        'env = { CUA_DRIVER_EMBEDDED = "1", CUA_DRIVER_RS_TELEMETRY_ENABLED = "false", CUA_DRIVER_RS_UPDATE_CHECK = "false" }',
        "startup_timeout_sec = 20.0",
      ].join("\n"),
    );
  }
  return blocks.join("\n\n");
}

/**
 * TOML for the writable roots. Codex's `workspace-write` sandbox allows writes inside the thread's
 * cwd and nothing else, so a request like "make a folder on my Desktop" is refused — and with
 * `approvalPolicy: "never"` (the headless default) Codex cannot even ask to escalate; it just says
 * it can't. These roots are what makes the rest of the disk writable.
 */
export function renderSandboxWritableRoots(roots: string[] | undefined): string {
  if (!roots || roots.length === 0) return "";
  return ["[sandbox_workspace_write]", `writable_roots = [${roots.map(tomlString).join(", ")}]`].join("\n");
}

/** Own OpenAI key: a custom provider on that key. Otherwise Codex's built-in provider, on the ChatGPT sign-in. */
export function renderProviderLine(v: Pick<RenderVars, "ownOpenAIKey">): string {
  return `model_provider = ${tomlString(v.ownOpenAIKey ? "openclicky" : "openai")}`;
}

export function renderProviderBlock(v: Pick<RenderVars, "openaiBaseUrl" | "ownOpenAIKey">): string {
  if (!v.ownOpenAIKey) return "";
  return [
    "[model_providers.openclicky]",
    'name = "OpenClicky"',
    `base_url = ${tomlString((v.openaiBaseUrl ?? "https://api.openai.com/v1").replace(/\/+$/, ""))}`,
    'env_key = "OPENCLICKY_OPENAI_KEY"',
    // Codex rejects `wire_api = "chat"`; both routes speak the Responses API (/v1/responses).
    'wire_api = "responses"',
    "requires_openai_auth = false",
    "supports_websockets = false",
  ].join("\n");
}

/**
 * Point the isolated CODEX_HOME at the person's ChatGPT sign-in. A link rather than a copy: the
 * refresh token rotates, so two copies would sign each other out. Where Codex has replaced the link
 * with a file during a refresh (or links are not allowed, as on Windows without developer mode), the
 * newer file wins, so the freshest token always reaches both places.
 */
export function linkCodexLogin(codexHome: string, source: string): void {
  const target = path.join(codexHome, "auth.json");
  const stat = fs.lstatSync(target, { throwIfNoEntry: false });
  const sourceStat = fs.statSync(source, { throwIfNoEntry: false });
  if (stat?.isSymbolicLink() && sourceStat && path.resolve(codexHome, fs.readlinkSync(target)) === path.resolve(source)) return;
  if (stat?.isFile() && (!sourceStat || stat.mtimeMs > sourceStat.mtimeMs)) {
    fs.mkdirSync(path.dirname(source), { recursive: true });
    fs.copyFileSync(target, source);
    fs.chmodSync(source, 0o600);
  }
  if (stat) fs.rmSync(target);
  if (!fs.existsSync(source)) return;
  try {
    fs.symlinkSync(source, target);
  } catch {
    fs.copyFileSync(source, target);
    fs.chmodSync(target, 0o600);
  }
}

/** Fill the placeholders in config/codex-config.toml. */
export function renderCodexConfig(template: string, v: RenderVars): string {
  const modelLine = v.model ? `model = ${tomlString(v.model)}` : "";
  return template
    .replaceAll("{{MODEL_LINE}}", modelLine)
    .replaceAll("{{MODEL_PROVIDER_LINE}}", renderProviderLine(v))
    .replaceAll("{{MODEL_PROVIDER_BLOCK}}", renderProviderBlock(v))
    .replaceAll("{{OPENCLICKY_ROOT}}", tomlStringInner(v.root))
    .replaceAll("{{WORKSPACE}}", tomlStringInner(v.workspace))
    .replaceAll("{{USER_SKILLS_ACTIVE}}", tomlStringInner(v.userSkillsActive))
    .replaceAll("{{MCP_SERVERS}}", renderMcpServers(v))
    .replaceAll("{{SANDBOX_WRITABLE_ROOTS}}", renderSandboxWritableRoots(v.writableRoots));
}

/**
 * Materialize the isolated CODEX_HOME: create the directory and (re)write config.toml from the
 * template so the provider, skills paths, MCP servers, and trusted workspace are always current.
 * Also syncs the user's `active/` skills dir so Codex sees exactly the activated skills.
 */
/** Why an agent run cannot start, in a sentence; nil when it can. */
export function codexCredentialsProblem(cfg: Pick<AgentConfig, "openaiApiKey" | "codexAuthFile">): string | undefined {
  if (cfg.openaiApiKey || fs.existsSync(cfg.codexAuthFile)) return undefined;
  return "Codex is not signed in: run `codex login` and sign in with ChatGPT, or set your own OpenAI key (OPENCLICKY_OPENAI_KEY)";
}

export function ensureCodexHome(cfg: AgentConfig): { configPath: string } {
  const templatePath = path.join(cfg.root, "config", "codex-config.toml");
  const template = fs.readFileSync(templatePath, "utf8");
  fs.mkdirSync(cfg.codexHome, { recursive: true });
  const configPath = path.join(cfg.codexHome, "config.toml");
  if (!cfg.openaiApiKey) linkCodexLogin(cfg.codexHome, cfg.codexAuthFile);
  // A broken user skills dir must not stop the agent: warn and run with whatever active/ holds.
  try {
    syncActiveDir(cfg.userSkillsDir);
  } catch (e) {
    process.stderr.write(`warning: user skills not synced: ${(e as Error).message}\n`);
  }
  fs.writeFileSync(
    configPath,
    renderCodexConfig(template, {
      root: cfg.root,
      openaiBaseUrl: cfg.openaiBaseUrl,
      workspace: cfg.workspace,
      model: cfg.model,
      composioMcpUrl: cfg.composioMcpUrl,
      composioApiKey: cfg.composioApiKey,
      cuaDriverBin: cfg.cuaDriverBin,
      userSkillsActive: activeDir(cfg.userSkillsDir),
      writableRoots: cfg.writableRoots,
      ownOpenAIKey: Boolean(cfg.openaiApiKey),
    }),
  );
  return { configPath };
}
