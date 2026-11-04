# OpenClicky (personal fork)

> **This is an unofficial fork of [OpenClicky](https://github.com/prasanthsasikumar/openclicky) by
> [Prasanth Sasikumar](https://github.com/prasanthsasikumar) and its contributors.** Credit for the app
> belongs to them. This fork isn't made, endorsed or supported by them, so please report problems with it
> here and not to the original project. See [Credits](#credits).

**Ask your computer. It shows you where.** Hold ⌃ control + ⌥ option and ask out loud: a pointer flies
to the answer on your screen. Hold fn and talk, and your words are typed where your cursor is. Hand
bigger jobs to a Codex agent.

This fork runs on **your own Claude and Codex subscriptions**. There are no accounts, trials or servers
of its own: it talks only to the services you connect. API keys still work if you ever want one.

It shares no accounts or servers with the original project and takes no updates from it.

## What needs the internet

| Works on your machine | Needs the internet |
|---|---|
| Dictation with on-device recognition, the Mac voice, and Kokoro after its one download | Answers and agent tasks, which run on Anthropic's and OpenAI's servers |
| Your history, dictionary, styles and usage counts | Weather, web search, picture lookup and update checks |

## Install

These links always give you the newest version:

- **[Download for Mac](https://github.com/Nicolas-Cilia/openclicky-fork/releases/latest/download/OpenClicky.dmg)** (macOS 14.2 or later)
- **[Download for Windows](https://github.com/Nicolas-Cilia/openclicky-fork/releases/latest/download/OpenClicky-Setup.exe)** (Windows 10 version 2004 or later, or 11; for ARM PCs use the [ARM64 installer](https://github.com/Nicolas-Cilia/openclicky-fork/releases/latest/download/OpenClicky-Setup-arm64.exe))

**Mac:** open the dmg and drag the app to Applications. It is self-signed rather than notarized, so the
first time on each Mac you need to right-click it and choose Open (on newer macOS: System Settings →
Privacy & Security → Open Anyway).

**Windows:** run the installer. It is unsigned, so SmartScreen warns the first time: choose More info →
Run anyway.

Later updates install themselves.

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

Agent tasks only run on Codex, so they pause until the reset when Codex runs out. The tool they run
through is in the app. It needs Node.js 22 or later: if your computer doesn't have it, the app downloads
it once (about 30 MB, about 110 MB on disk) when you have agent tasks set up.

Fast realtime voice has no subscription route: it needs an OpenAI or Gemini API key.

## Sharing the notch

The island's default placement, **Automatic**, stays in the notch until another app such as Vorssaint has
a window there, then moves to the right edge, and moves back when that app quits. Pick a fixed place in
Settings → General.

## Develop

[docs/setup.md](docs/setup.md) covers building and releasing, [docs/architecture.md](docs/architecture.md)
how it fits together, and [docs/skills.md](docs/skills.md) writing skills.

## Credits

- **[OpenClicky](https://github.com/prasanthsasikumar/openclicky)** by Prasanth Sasikumar and contributors
  is the project this fork is built from. Nearly all of the code and design here is their work. This fork
  mainly removes the hosted services and adds support for running on your own plans.
- **[Clicky](https://github.com/farzaa/clicky)** by Farza is the open-source app that parts of the Mac
  app's first version came from.
- **[AI pointer](https://deepmind.google/blog/ai-pointer/)** by Adrien Baranes, Rob Marchant and the Google
  DeepMind team is where the original project says the idea began.
- **Kivi** by the [Sarvam AI](https://www.sarvam.ai) team inspired the original project's dictation and
  settings. No Kivi code, art or fonts are used.

Any bugs added by this fork are the fork's own.

## License

MIT, the same as the original project. The original copyright and license notices are kept in
[LICENSE](LICENSE) and [macos/OpenClicky/LICENSE](macos/OpenClicky/LICENSE). Bundled skills and other
third-party parts keep their own licenses where they include them.

This fork isn't affiliated with Google, Sarvam AI or HeyClicky, which is a separate product.
