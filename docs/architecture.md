# How OpenClicky works

The pieces, how a request travels through them, and where the skills live.

## Architecture

```
  Mac or Windows app
    ├─ answers: claude -p or codex exec on your plan, or an API key straight to its vendor
    │    ProviderRouter picks the default; the backup plan takes over at a limit
    ├─ usage: ~/.openclicky/usage.jsonl (counts only) + the plans' limits as the CLIs report them
    └─ agent tasks: the openclicky CLI (agent/)
         └─ codex app-server, CODEX_HOME=~/.openclicky/codex-home
              ├─ on your ChatGPT sign-in, linked from ~/.codex/auth.json
              └─ or an own OpenAI key (OPENCLICKY_OPENAI_KEY)
```

There is no server of our own. Keys in `~/.openclicky/shell.json` go only to their own vendor.

### Repository layout

| Path | What |
|---|---|
| `agent/src/codex.ts` | Codex bridge: spawn, JSON-RPC, threads, turns, streaming deltas, approvals, artifacts, token counts |
| `agent/src/cli.ts` | `openclicky run\|ask\|do\|voice\|talk\|threads\|skills` |
| `agent/src/codexHome.ts`, `config/codex-config.toml` | renders the isolated `CODEX_HOME`: provider, sign-in link, skills, MCP servers |
| `agent/src/skillsLibrary.ts`, `skillMarkdown.ts` | the user skill library in `~/.openclicky/skills` |
| `app-skills/` | app-teaching skills, copied into the app at build time |
| `skills/` | `ModelInstructions.md` and the built-in agent skills |
| `macos/OpenClicky/` | the Mac app. `ProviderRoute.swift` picks who answers; `PlanUsage.swift` holds usage, limits and failover state; `NotchOccupancy.swift` shares the notch |
| `windows/` | the Windows app |

## Skills

HeyClicky ships skills in three layers, and so does OpenClicky. All of them are Hermes-style
`SKILL.md` files (YAML frontmatter with `name`, `description`, optional `apps`, `sites`, `surfaces`;
lists inline like `[a, b]`; Markdown body). Nothing is compiled into the app or the backend; the
files are read at run time. `docs/skills.md` is the authoring guide.

| Layer | Where | Who reads it |
|---|---|---|
| Built-in agent skills (15) | `skills/` | Codex, always on, via `[[skills.config]]` |
| App-teaching skills (16) | `app-skills/<id>/SKILL.md`, `apps: [bundle ids]` / `sites: [hosts]`, `surfaces: [talk]` | the Mac app: the one matching the frontmost app or site is injected into the Realtime and teacher prompts (≤ 4,000 chars) |
| User library | `~/.openclicky/skills/library/<id>/SKILL.md` (`OPENCLICKY_USER_SKILLS_DIR`) | activated ones only: Codex through `~/.openclicky/skills/active/` (symlinks, second `[[skills.config]]`), and the voice prompts when `surfaces` includes `talk` (≤ 6,000 chars total) |

Activation lives in `~/.openclicky/skills/activations.json` (`{ "active": [ids], "updatedAt" }`).
The CLI and the app read the same files: `openclicky skills list|activate|deactivate|path`, or drop
a folder into `library/` by hand. Every agent run re-syncs `active/` so Codex sees the current set.
Skills are not drafted in the app: shared ones arrive as reviewed pull requests to `app-skills/`.
Matching rules: bundle id exact; a site matches
the browser host or any of its subdomains; a site skill beats the browser's own app skill; the most
specific site wins. Add an app skill by creating the folder; the app picks it up on the next voice turn.

Not ported from HeyClicky: the community approval queue with email, "My Skills" filter, and
team-private sharing (v1.0.34–36, v1.0.44).

### The behavior contract

`skills/ModelInstructions.md` is the agent contract (routing ladder, approval gate,
style, macOS permission-prompt-storm avoidance), rebranded. Codex loads it via
`model_instructions_file`; the 15 skills are exposed through `[[skills.config]]` . Regenerate from `reference/` with `npm run port-skills`. See `skills/ATTRIBUTION.md`.

## Plans, limits and failover

`ProviderCredentials.activeAnswerSource` decides who answers: the person's default, or the backup while the
default has run out. `ClaudeAPI.answerThroughProvider` retries a refused question on the backup once, if
nothing has been spoken yet. `PlanAvailability` remembers how long a plan is out (its reset time, else 30
minutes). Only plans can be backups.

Neither plan gives a per-request cost. `claude -p` reports tokens, a list-price estimate, and the 5-hour and
7-day limits on every request; `codex exec` reports tokens, and `codex app-server`'s
`account/rateLimits/read` reports its limits and any purchased credits.
