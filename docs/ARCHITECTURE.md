# Architecture

Three bundled executables, one dependency-free Swift core:

- **AgentAwake**: SwiftUI menu-bar window and settings; evaluates policy every second;
  reads Claude Code session presence files; owns a timeout-bounded idle-sleep assertion;
  registers the helper and login item through `SMAppService`. It never requests a
  display-sleep assertion.
- **agent-awake-hook**: synchronous, one-second Codex CLI hook. Reads a bounded JSON payload,
  walks process ancestry to identify the owning Codex process, extracts an allowlist, and
  updates private metadata under a short file lock. Always exits zero with empty stdout. No
  permission decisions, network calls, transcript reads, or raw payload logs. A stale
  Claude hook left by an older install also exits zero without reading its payload.
- **agent-awake-helper**: launchd daemon. Accepts only signed copies of its containing
  app, with the designated requirement enforced by NSXPC for every message. The app
  likewise pins the bundled helper. Ad-hoc builds pin a cdhash; Developer ID builds pin
  the signing identity. Only `renew(awake:generation:)` and `release()` are exported.

## State and privacy

`~/Library/Application Support/Agent Awake/` is mode 0700. Its metadata and lock files
are mode 0600. A single, bounded `sessions.json` holds Codex sessions only: provider, opaque
IDs, process PID/start time, timestamps, lifecycle state, and pending tool IDs.
No prompt, tool contents, cwd, or transcript paths are stored. There is no event history.
Exited processes are pruned on ingestion and each app refresh; process birth time prevents
PID reuse from reviving a session.

Claude Code state is never stored. Each refresh reads `sessions/<pid>.json` from
`CLAUDE_CONFIG_DIR`, or `~/.claude` when it is unset. A file counts only when its PID is a
live process of the current user, the executable is Claude, and the kernel start time
matches the file's `procStart` within two seconds. Claude leaves files behind for exited
processes, so this check is what keeps a stale file or a reused PID from counting. Files
are opened with `O_NOFOLLOW` and `O_NONBLOCK`, must be user-owned regular files of at most
64 KB, and are skipped silently when malformed. Only `pid`, `sessionId`, `procStart`,
`status`, and `statusUpdatedAt` are decoded; `cwd`, the session name, and every other key
are ignored. One table maps `busy` to working, `shell` to background work, `waiting` to
waiting, and `idle` to ready. Any other status shows as unknown and never keeps the Mac
awake.

Agent processes without a source of state appear as untracked and never become active
merely because they exist: Claude processes without a presence file, and Codex processes
without hook metadata.

Only Codex receives hooks. Configuration installation preserves all unrelated keys and
handlers, uses atomic replacement, detects changes between reading and writing, and
refuses malformed config or non-user-owned configuration targets. Dotfile symlinks are preserved; their verified
user-owned regular targets are edited. Exact installed commands are recorded for removal. Private
backups stay beside the original config. Reinstalling is idempotent. Removal rereads the
current config; it does not roll the whole file back to an old backup. Removal deletes
the exact recorded command from every hook event, so entries from retired event lists
are removed too, and rewrites a file only when it held that command. On launch the app
removes the Claude hooks earlier versions installed: the recorded Claude entries, plus
this app's own Claude command in the current Claude settings, since a manifest can be
lost. It shows a notice when a file changed. Rerunning changes nothing; a failed removal
of a recorded entry stays recorded and retries at the next launch.

## Power policy

Manual indefinite or timed sessions and working agents are combined with OR. Automatic
mode can be disabled or paused. The optional battery cutoff (default off; default threshold
20%) overrides both modes only while on battery. A critical thermal state (macOS
`ProcessInfo.thermalState`) always overrides both modes, with no setting, and protection
resumes once the state drops below critical. Completion gets an eight-second grace
period measured with a monotonic clock. Manual timer expiration uses an absolute deadline.
“Allow sleep now” ends manual sessions, clears grace, and persists automatic pause until
explicit resume. Manual sessions are not restored after application restart.

The ordinary idle assertion has a 12-second timeout, renewed every second, and is released
by the OS on process exit. The helper receives a heartbeat every three seconds; its lease
expires after 12 seconds. Client disconnection also releases immediately. Loss of an
established helper connection pauses protection; it does not silently claim closed-lid
protection using an ordinary assertion.

## Closed lid and recovery

Public IOPM idle assertions do not prevent lid sleep. The approved root helper uses the
fixed operation `/usr/bin/pmset -a disablesleep 1`, affecting battery and charger alike.
Before doing so, it durably records restoration intent in the root-owned, mode-0700
`/var/db/com.irshatharis.AgentAwake/` directory. Restoring `disablesleep 0` must succeed
before the journal is removed. launchd runs the helper at boot and restarts it on crash;
startup restores an outstanding journal before accepting leases. Replacing the app leaves the registration pointing at the deleted bundle, so launchd cannot find the new helper. The old helper restores sleep and exits when its executable is replaced, and the app registers the helper again when its bundle path or inode differs from the one recorded at registration. An expired lease or
disconnected client also restores. When the helper releases its owned override with the
lid closed, it asks IOKit for system sleep; with the lid open it leaves idle sleep alone.
A closed lid counts only when IOKit's `AppleClamshellCausesSleep` says macOS would sleep for
it. In clamshell mode, with an external display in use, the helper neither blanks displays
nor requests sleep. `disablesleep` does not change that flag.
While a live lease prevents sleep, the helper follows IOKit general-interest notifications
on `IOPMrootDomain`. Each notification rereads `AppleClamshellState` and
`AppleClamshellCausesSleep`. An opening ends the current closure at once; a closure must
settle for two seconds before the helper acts, so it acts on the first one-second tick
after that. Protection that starts with the lid already closed reads the lid immediately,
without waiting for a notification. If the notification cannot be registered, the helper
logs the failure and reads lid state once per second instead. On a settled lid closure
(or when protection starts with the lid closed), it runs the fixed operation
`/usr/bin/pmset displaysleepnow`. This requests sleep for connected displays, including
external screens. It runs once per closure, retries a failed request after five seconds,
and reports failures in Diagnostics. It never issues this command with an open lid or
an expired lease, and never changes display brightness or display idle settings. It discovers its
containing bundle with `_NSGetExecutablePath`, since launchd can pass a relative argv[0].
The build verifies signature discovery with a deliberately relative argv[0].

This recovery depends on launchd being permitted to run the helper. Forcibly unloading it,
deleting its app bundle while it owns the setting, or disabling it in System Settings can
prevent journal recovery. The emergency recovery command is `sudo pmset -a disablesleep 0`.
Use the app's removal flow before deleting the bundle.

## Other power controllers

An existing global sleep-disable setting is borrowed, not owned. It is not cleared on
release. A later observed external change to `0` is treated as a conflict: do not reassert,
and require a new explicit session. The global switch is not reference-counted. Another
`nosleep` command while it already equals `1` cannot be detected or distinguished. There
is no reliable, race-free ownership protocol with arbitrary external `pmset` callers.

## Detection boundary

See `VERIFICATION.md`. Claude Code's presence file reports its own status, including
approvals, interruptions, and background shells, which its hooks never reported. It is
undocumented Claude internals and could change in any release. Unknown statuses show as
unknown, never working, and a missing or unreadable file leaves the process untracked.
Codex hooks are useful but not a complete activity API; in particular, Codex lacks a
post-permission/pre-execution event. Do not add CPU heuristics or silently interpret an
open process as active to cover gaps.
