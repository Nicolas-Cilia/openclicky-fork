# Building and releasing

## Prerequisites

- Node 22+
- Codex CLI (`npm i -g @openai/codex`), signed in with `codex login`
- Mac: Xcode, and `ffmpeg` for the CLI's voice commands (`brew install ffmpeg`)
- Windows: .NET 8 SDK

## Build and test

```bash
npm ci
npm run build -w agent
npm test                    # agent tests

# Mac app, from macos/OpenClicky
xcodebuild test -project OpenClicky.xcodeproj -scheme OpenClicky -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO -only-testing:OpenClickyTests

# Windows shared code
dotnet test windows/tests/OpenClicky.Core.Tests/OpenClicky.Core.Tests.csproj
```

## Run the agent

Agent tasks run through the `openclicky` tool in `agent/`, which starts Codex in its own folder
(`~/.openclicky/codex-home`) and shares your ChatGPT sign-in from `~/.codex/auth.json`. With an
OpenAI key set, it uses the key instead.

The tool ships inside the app (`Contents/Resources/agent-tool` on Mac, `agent-tool\\` beside the exe on
Windows). It runs on this machine's Node.js 22 or later, or on a copy the app downloads once from
nodejs.org, checked against a pinned SHA-256, when agent tasks are set up and there is no Node to use.

To work on the tool itself, point the app at your build in `~/.openclicky/shell.json`:

```json
{ "cliCommand": ["node", "/path/to/openclicky-fork/agent/dist/cli.js"] }
```

From a terminal, after `npm link -w agent`:

```bash
openclicky run "create a file called hello.txt"   # a full agent task
openclicky do "what is a monad"                   # picks a quick answer or an agent task
openclicky threads list
```

`.env.example` lists every setting.

## Release

Run this once, ever, on the Mac you publish from:

```bash
macos/OpenClicky/scripts/setup-release-keys.sh
```

It creates a self-signed certificate and Sparkle's update key in your login keychain and writes the public
key to `Info.plist`. **Back up both.** Losing the update key means every installed copy has to be
replaced by hand. The certificate is what keeps macOS's permissions across updates.

To publish (this needs `gh`, signed in, and a `CHANGELOG.md` section for the version in
`macos/OpenClicky/VERSION`):

```bash
npm run release:mac            # build, sign and install to /Applications
npm run release:mac:publish    # ...and publish the GitHub release the app updates from
```

Then run **Actions → windows-release** with the same tag to attach the Windows installers. Windows
updates come from those releases through Velopack; signing stays optional (`windows/docs/code-signing.md`).
