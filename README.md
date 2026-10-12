<p align="center">
  <img src="Resources/Icon/BobbinMark.svg" width="104" alt="Bobbin mark">
</p>

<h1 align="center">Bobbin</h1>

<p align="center"><strong>Thread lightly.</strong></p>

<p align="center">Spin up a thread. Keep what matters. Bobbin forgets the rest.</p>

<p align="center">
  <a href="https://bobbin.combinatrix.ai/">Website</a> ·
  <a href="https://github.com/combinatrix-ai/bobbin/releases/latest/download/Bobbin-v0.1.1.dmg">Download for macOS</a>
</p>

<p align="center">
  <img src="docs/images/bobbin-hero.png" width="720" alt="Bobbin menu bar icon above its thread list popover">
</p>

Bobbin is a small macOS menu bar client for the useful tasks that do not need to live forever in your main agent history. Open a thread, ask Codex, then get back to what you were doing.

## Install

Download the notarized [Bobbin DMG](https://github.com/combinatrix-ai/bobbin/releases/latest/download/Bobbin-v0.1.1.dmg), open it, and drag Bobbin to Applications. Bobbin requires macOS 14 or later and a locally installed Codex CLI.

## Thread lightly

**Start in one click.** Open Bobbin from the menu bar and begin a focused Codex thread without changing workspaces.

**Let the small stuff fade.** Unsaved threads become quieter with age and are deleted after seven days.

**Keep what matters.** Save a useful thread and it moves to the Saved section, exempt from automatic cleanup.

## Tune every thread to the task

Each thread keeps its own controls:

<p align="center">
  <img src="docs/images/bobbin-conversation.png" width="392" alt="A Bobbin conversation with thread controls and tool results">
</p>

| Control | What it changes |
| --- | --- |
| **Model** | Pick from the Codex models available to your account. |
| **Reasoning** | Set the effort to match a quick question or a harder piece of work. |
| **Trust** | Choose `Auto review`, `Allow all`, or `Deny all` for this thread. |
| **System prompt** | Edit the autosaved instructions inherited by new threads. |
| **Folder** | Point the thread at the workspace it should work in. |

Review modes map to the app-server like this:

- `Auto review` is the default. It uses `approvalPolicy: on-request`, `approvalsReviewer: auto_review`, and the `workspace-write` sandbox.
- `Allow all` uses `approvalPolicy: never` and the `danger-full-access` sandbox.
- `Deny all` uses `approvalPolicy: never` and the `workspace-write` sandbox. Approval requests are never routed to the review subagent.

## How Bobbin works

- Runs `codex app-server --stdio` with an isolated `CODEX_HOME`.
- Keeps its conversations separate from the normal Codex and Claude Code histories.
- Uses ChatGPT device-code authentication by default.
- Asks before using an `OPENAI_API_KEY` found in the process or launch-agent environment.
- Removes `OPENAI_API_KEY` from the app-server environment until you explicitly opt in.
- Defaults new threads to `gpt-5.6-luna` with `xhigh` reasoning.
- Supports multiple disposable threads, sorted by recent conversation time.
- Uses a template menu bar icon that adapts to light and dark menu bars.

## Computer Use

Bobbin loads the official native Computer Use plugin from `/Applications/ChatGPT.app`, or from `/Applications/Codex.app` when that distribution is available. It verifies the OpenAI signatures and installs an owned copy of the native service inside Bobbin's isolated `CodexHome`. The plugin enables computer control only. It does not import desktop authentication, browser sessions, or browser automation.

The official tool description tells Codex when to use Computer Use, so you can ask "Open Calculator and calculate 200 × 1236" without naming a tool. Bobbin adds only a short per-turn note on operating apps reliably: match controls by label, prefer text entry, and verify the result on screen. Your system prompt is not changed.

When Codex requests access to an app, Bobbin shows the native request above that chat's composer. Choose **Decline** or **Allow for this chat**. Review mode does not grant native app access. Requests expire after five minutes and are cancelled when the chat stops, completes, is deleted, or the server restarts. macOS permission prompts still require your decision.

Settings shows whether Computer Use is ready, disabled, unavailable, or failed. Explicit plugin disables and existing Computer Use server or tool restrictions remain in force. Computer Use failures do not prevent normal conversations when a Codex CLI is available. Restart the app-server to adopt a desktop update.

## Demo mode

Demo mode provides deterministic content for product screenshots and safe UI walkthroughs.

Launch with `--demo-mode` or `BOBBIN_DEMO_MODE=1`. Bobbin uses a throwaway directory under the system temporary directory and removes it on termination. It does not start `codex app-server`.

To show specific content, pass `--demo-data /path/to/state.json` or set `BOBBIN_DEMO_DATA`. This also enables demo mode. The file uses Bobbin's normal `state.json` format, so there is no second fixture schema to maintain.

Launch with `--demo-computer-use` to show a deterministic Calculator approval in the built-in demo. This mode also keeps the production app-server stopped.

## Storage

Runtime data lives under `~/Library/Application Support/Bobbin/`. Nothing there holds an API key, but two independent sets of conversation data accumulate: Bobbin's own `state.json` and Codex's isolated home under `CodexHome/`.

- `state.json` contains threads and the full text of every user and assistant message.
- `CodexHome/auth.json` contains Codex credentials.
- `CodexHome/sessions/*.jsonl` contains full conversation rollouts.
- `CodexHome/logs_2.sqlite` contains Codex logs.
- `CodexHome/memories/` is a git repository containing `MEMORY.md`, `raw_memories.md`, and rollout summaries.
- `CodexHome/state_5.sqlite` contains Codex state.
- `CodexHome/models_cache.json` contains Codex's model cache.

The seven-day cleanup calls `thread/delete` and drops the thread from `state.json`. It does not clear `CodexHome/logs_*.sqlite` or `CodexHome/memories/`, so conversation traces continue to accumulate there.

## Build and test

Bobbin requires macOS 14 or later and either a supported OpenAI desktop installation or a Codex CLI at one of the supported local install paths.

```sh
swift build
swift test
./scripts/build-app.sh /path/to/output-directory
```

To test the installed native runtime without a model API call, run:

```sh
BOBBIN_NATIVE_COMPUTER_USE_SMOKE=1 swift test --filter ComputerUseNativeSmokeTests
```

The smoke test creates a fresh temporary home, lists native apps, and explicitly declines the Calculator access request. It does not copy credentials or start a model turn. Run it outside a shell sandbox that blocks Apple signature verification. The test prints its isolated home path and leaves that home available for inspection.

The packaging script creates an ad-hoc signed `Bobbin.app`. Pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`, which tests, builds a universal app, signs it with Developer ID, notarizes its ZIP and DMG with Apple, signs the Sparkle update, and publishes the GitHub Release. The tag must match `CFBundleShortVersionString`, and `CFBundleVersion` must be a positive, monotonically increasing build number.

The release workflow uses a manually approved `release` environment restricted to `main` and `v*` tags. It requires these environment secrets: `BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`, `APPLE_ID`, `NOTARY_PASSWORD`, and `SPARKLE_ED_PRIVATE_KEY`. Existing tags can be released through **Run workflow** by supplying the tag. `scripts/release.sh` remains available as the local fallback and uses the same packaging and verification path.

Release builds use Sparkle to check the signed `appcast.xml` attached to the latest GitHub Release once per day. The Settings menu also provides **Check for Updates…** for an immediate check.

## Icon

The Bobbin mark is generated from one geometry source. `Sources/BobbinIcon/MarkSpec.swift` drives the app icon, menu bar template glyph, SVG export, and preview sheet, so there is no hand-maintained raster to drift out of step.

```sh
swift run bobbin-icon iconset  build/AppIcon.iconset
swift run bobbin-icon template build/menubar
swift run bobbin-icon svg      Resources/Icon/BobbinMark.svg
swift run bobbin-icon preview  build/icon-preview.png
```

`build-app.sh` regenerates `AppIcon.icns` for every package. It fails unless the bundle declares `CFBundleIconFile`, contains a non-empty icon with a 1024 px representation, and passes a strict signature check. Generated `.iconset` and `.icns` files are not committed.

Protocol implementation follows the [official Codex App Server documentation](https://developers.openai.com/codex/app-server) and is verified against bindings generated by the installed Codex CLI.
