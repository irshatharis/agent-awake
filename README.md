<div align="center">

# Agent Awake

**Let your agents work. Let your Mac rest.**

A native macOS menu-bar app for Claude Code, Codex, and always-available terminals.

Swift · SwiftUI · macOS 14+ · MIT · Local only

</div>

> **Developer preview.** The app builds and runs, but the full reliability goal is not
> yet proven. Current CLI hooks have documented gaps, and closed-lid behavior requires
> helper approval and physical testing on your Mac. Read the [verification report](docs/VERIFICATION.md)
> before depending on automatic mode for unattended work.

## What it does

- Follows Claude Code and Codex lifecycle hooks, with separate sessions and subagents.
- Shows working, tool execution, waiting, completion, interruption (Codex), and unknown
  states. An open process alone never counts as work. No CPU activity heuristics.
- Releases prevention after an eight-second grace period when observed work finishes.
- Offers 15-minute, 30-minute, one-hour, two-hour, custom, and **indefinite** sessions.
  Indefinite mode keeps your terminal reachable over Tailscale between agent tasks.
- Keeps the display free to turn off. An approved bundled helper controls closed-lid
  prevention on both battery and charger.
- Includes optional battery cutoff (off by default, initially 20%), launch at login,
  and **Allow sleep now**, which clears manual sessions and pauses automatic mode.
- Uses renewable leases and a recovery journal to restore its power changes after
  disconnection or a crash, provided launchd can restart the helper.
- Preserves existing hooks and offers a clean removal flow.

## Build and run

Install Apple's Command Line Tools with `xcode-select --install` if needed. Use a Swift 6+
compiler on macOS. No package downloads or third-party libraries are needed.

```sh
git clone https://github.com/irshatharis/agent-awake.git
cd agent-awake
scripts/check.sh
scripts/build-app.sh
ditto 'dist/Agent Awake.app' '/Applications/Agent Awake.app'
open '/Applications/Agent Awake.app'
```

You can also open `Package.swift` in Xcode. Run the packaged application to test its
bundled helpers and ServiceManagement integration; `swift run AgentAwake` does not create
an app bundle. The build script signs locally with an ad-hoc signature. For a Developer ID
build, set `SIGN_IDENTITY='Developer ID Application: …'` when running the script. Public
binary distribution should use Developer ID signing and notarization; this repository
does not contain an Apple signing certificate or claim a notarized release.

## Setup

1. Put the app in `/Applications` before enabling integrations.
2. In **Settings → Setup**, install the Claude and Codex hooks.
3. In Codex, open **`/hooks`**, review the exact Agent Awake commands, and trust them.
   Restart existing CLI sessions so they load the hooks. Hook installation is separate
   from hook trust; Agent Awake never bypasses Codex trust.
4. Enable the helper and approve it in **System Settings → General → Login Items &
   Extensions** if macOS requests approval. Without it, the app can prevent ordinary
   idle sleep but cannot promise closed-lid operation.
5. Run the two-minute hardware check from Setup. Close the lid and verify your terminal
   stays reachable from your phone; repeat on battery and let the session expire.

The default hook locations are `~/.claude/settings.json` and `~/.codex/hooks.json`.
The installer honors `CLAUDE_CONFIG_DIR` and `CODEX_HOME` when these variables are present
in the application's environment. GUI launches do not inherit shell startup variables;
launch the app executable from that configured shell for a custom location.

## Honest activity detection

Hooks are an activity signal, not a complete activity API. In the versions inspected:

- Claude does **not** emit `Stop` on a user interrupt. A later idle notification can
  clear the state, but immediate interrupt detection is not guaranteed.
- Neither CLI documents a “permission accepted, execution started” event. A long tool
  approved after a wait may stay marked waiting until its post-tool hook arrives.
- Stop hooks can be blocked by other hooks; detached/background work and subagent
  cancellation do not always have complete lifecycle coverage.
- Processes started before hook setup are shown as unknown. Codex's shared daemon can
  own several sessions, so process existence alone cannot distinguish their lifecycle.

These limits mean this preview does **not** meet a strict “awake if and only if any agent
is working” guarantee. Use **Stay awake indefinitely** for continuous remote access.
See the [event coverage matrix and remaining work](docs/VERIFICATION.md).

## Privacy

There are no network requests, analytics, accounts, or transcript readers in the app.
Hooks discard prompt text, tool inputs/outputs, working directories, and transcript
paths. Only the session metadata needed to track activity is stored privately in
`~/Library/Application Support/Agent Awake/`. Exited sessions are pruned. Configuration
backups may contain your pre-existing settings and remain private beside those files.

## `nosleep`, `rsleep`, and removal

The helper uses the same global `SleepDisabled` switch as
`sudo pmset -a disablesleep 1/0`. It preserves a setting already enabled by another tool
and respects an observed external `rsleep`. Repeating `nosleep` while the switch is
already on is indistinguishable; a global boolean cannot provide independent ownership
for multiple tools. The app does not edit your aliases.

Use **Settings → Diagnostics → Remove integrations** before deleting the app. That
releases owned power changes, removes only Agent Awake's hooks, unregisters the helper,
and disables login launch. Existing hooks and configuration backups remain. Quit and
move the app to Trash afterward. You can delete its private metadata directory once it
is no longer running.

If you forcibly disable/remove the helper while it owns a sleep override, restore sleep
manually with:

```sh
sudo pmset -a disablesleep 0
```

## Development

See [architecture](docs/ARCHITECTURE.md), [verification](docs/VERIFICATION.md), and
[contributing](CONTRIBUTING.md). The checks run with Command Line Tools; a full Xcode
installation and XCTest runtime are not required. CI builds the app and runs the same
checks on macOS. This is open source under the [MIT license](LICENSE).
