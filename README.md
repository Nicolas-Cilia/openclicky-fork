# OpenClicky (personal fork)

**Ask your computer. It shows you where.** Hold ⌃ control + ⌥ option and ask out loud: a pointer flies
to the answer on your screen. Hold fn and talk, and your words are typed where your cursor is. Hand
bigger jobs to a Codex agent.

This fork runs on **your own Claude and Codex subscriptions**. There are no accounts, trials or servers
of its own: it talks only to the services you connect. API keys still work if you ever want one.

Built from [prasanthsasikumar/openclicky](https://github.com/prasanthsasikumar/openclicky) (MIT, see
[LICENSE](LICENSE)). It shares no accounts or servers with that project and takes no updates from it.

## What needs the internet

| Works on your machine | Needs the internet |
|---|---|
| Dictation with on-device recognition, the Mac voice, and Kokoro after its one download | Answers and agent tasks, which run on Anthropic's and OpenAI's servers |
| Your history, dictionary, styles and usage counts | Weather, web search, picture lookup and update checks |

## Install

**Mac (macOS 14.2 or later):** download the dmg from [Releases](https://github.com/Nicolas-Cilia/openclicky-fork/releases/latest)
and move the app to Applications. It is self-signed rather than notarized, so the first time on each Mac
you need to right-click it and choose Open (on newer macOS: System Settings → Privacy & Security → Open
Anyway). Later updates install themselves.

**Windows (10 version 2004 or later, or 11):** run the Setup.exe from
[Releases](https://github.com/Nicolas-Cilia/openclicky-fork/releases/latest). It is unsigned, so SmartScreen
warns the first time: choose More info → Run anyway.

## Connect your plans

Sign in once in a terminal. OpenClicky finds what is signed in when it starts.

```bash
npm i -g @openai/codex && codex login     # your ChatGPT plan
claude                                    # your Claude plan: install Claude Code, then sign in
```

In Settings:

- **Clicky → Answers come from** picks your default.
- **Clicky → When it runs out** picks the backup. When the default hits its limit, the backup answers
  until the limit resets. A key is never used as a backup, so running out can't turn into a bill.
- **Keys & Plans** shows each plan's usage: what OpenClicky sent (requests and tokens, today and this
  month) and how full the plan's own limits are. The limit bars count everything on that account.

Agent tasks only run on Codex, so they pause until the reset when Codex runs out. They also need the
`openclicky` tool: see [Run the agent](docs/setup.md#run-the-agent).

Fast realtime voice has no subscription route: it needs an OpenAI or Gemini API key.

## Sharing the notch

The island's default placement, **Automatic**, stays in the notch until another app such as Vorssaint has
a window there, then moves to the right edge, and moves back when that app quits. Pick a fixed place in
Settings → General.

## Develop

[docs/setup.md](docs/setup.md) covers building and releasing, [docs/architecture.md](docs/architecture.md)
how it fits together, and [docs/skills.md](docs/skills.md) writing skills.

MIT licensed.
