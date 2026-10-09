# Verification and support boundary

This document distinguishes deterministic tests, live observations, and unverified
hardware behavior. Passing reducer tests is not proof that a CLI emits every necessary
event, and a successful `pmset` call is not proof of physical closed-lid behavior.

## Development machine

- Apple Silicon, macOS 26.6.2; Swift 6.3.3 Command Line Tools.
- Claude Code 2.1.295; Codex CLI 0.162.0.
- No Developer ID signing identity available. Local app is ad-hoc signed.
- Administrator approval and a physical close-lid test have not been completed.

## Automated checks

Run `scripts/check.sh`. Current coverage:

- Both CLI event sequences: session start, submit, tool, permission wait, result, stop, end.
- Multiple independent sessions, parent completion while a subagent keeps working.
- Parallel running tool plus permission-waiting tool; user-question tools.
- Codex interruption, process exit, and PID reuse cleanup.
- Claude background task snapshot and an observed completion event.
- Privacy allowlist, malformed input/configuration, private file modes, symlink rejection.
- Hook installation idempotence and exact-handler removal preserving other configuration,
  including user-owned dotfile symlinks.
- Grace expiry without sliding the deadline; a new task cancels grace.
- Timer expiry, indefinite sessions, battery cutoff, simulated charger changes, pause/resume.
- Journal-before-mutation ordering, heartbeat expiry, helper restart after simulated SIGKILL,
  restoration retry on injected failure, crash between journaling and mutation.
- Existing external `nosleep`, an observed external `rsleep`, and renewed ownership.

These are synthetic events and an injected power backend. They do not change global
power settings or prove administrator-approved daemon behavior.

## Live observations

- Release build and strict deep code-signature verification pass on the development Mac.
- The packaged app launches with a native menu-bar item and a readable setup window.
- A real Claude headless smoke run completed successfully with the bundled hook, and the
  running app acquired its named idle assertion. It did not acquire a display-sleep assertion.
- Two real Claude sessions ran concurrently through UserPromptSubmit, PreToolUse,
  PostToolUse, and Stop. Both returned successfully; the metadata showed two working
  sessions at once.
- Full Codex hooks remain dependent on review/trust in `/hooks`.
- Physical lid/display testing, actual helper SIGKILL recovery, and real charger transitions
  remain pending. They are not advertised as verified.

## Lifecycle coverage

| Case | Signal | Boundary |
| --- | --- | --- |
| Prompt starts work | `UserPromptSubmit` | Hooks must be installed/enabled/trusted; bare or disabled-hook sessions are unknown |
| Tool work | `PreToolUse` / `PostToolUse` | Some specialized or hosted tools do not emit tool hooks; parent turn usually covers them |
| Permission prompt | `PermissionRequest` | Does not cover every CLI-internal/network approval path |
| Accepted permission | Next tool/prompt event | **No immediate accepted-and-running event; a long approved tool can be under-counted** |
| User question | Known question tool / elicitation hooks | Specialized paths may differ |
| Parent completion | `Stop`, failures where supported | Other Stop hooks can block completion after our hook runs |
| Codex interruption | `Interrupt` | Main thread only; canceled subagents may lack a terminal hook |
| Claude interruption | Later idle event or process exit | **Claude explicitly does not emit Stop on interrupt** |
| Subagents | `SubagentStart` / `SubagentStop` and agent IDs | Completion blockers/cancellation may leave gaps |
| Background work | Child lifecycle, Claude Stop `background_tasks` IDs | Detached shell/MCP jobs lack universal completion hooks; `TaskCompleted` is not a universal shell completion event |
| CLI crash/exit | PID + process birth time | A shared Codex daemon can stay alive after an individual session disappears |
| Existing CLI at app start | Saved hook metadata or process discovery | Unknown is displayed, never assumed working |

The implementation retains the last observed lifecycle state until another event or
process exit changes it. It does not guess using CPU load or a short inactivity timeout.
Consequently, incomplete hook sequences can over- or under-count active work. This is a
known functional limitation, not a solved edge case.

## Hardware acceptance checklist (requires a person at the Mac)

1. Install in `/Applications`; enable and approve the helper. Confirm Diagnostics reports
   a responsive helper. Approve Codex hooks without bypassing trust.
2. Start an indefinite session. `pmset -g` should show `SleepDisabled 1`; `pmset -g assertions`
   should list Agent Awake's idle assertion and no Agent Awake display assertion.
3. Close the lid on battery. From another device, verify a terminal heartbeat continues
   for several minutes and inspect whether the internal panel is off. Repeat on charger.
4. Run agents in multiple terminals; complete one while another works. Verify continued
   prevention. Complete the last and check the grace countdown.
5. With lid closed, expire a timer/finish all agents and verify the Mac sleeps. With lid
   open, verify ordinary idle-sleep behavior resumes without forcing immediate sleep.
6. Present a permission prompt; verify waiting. Approve a long command and explicitly
   test the documented resumption gap. Interrupt Claude/Codex and test subagent cancellation.
7. Kill the app while active. Verify the helper restores within 12 seconds (plus scheduler
   latency). Kill the helper; verify launchd restarts it and consumes the recovery journal.
8. Switch charger/battery while active. With cutoff enabled, cross the configured threshold
   and verify prevention releases. With cutoff disabled, confirm no charger-dependent policy.
9. Run `nosleep` before a session: ending the app's session must preserve the external setting.
   Run `rsleep` during an owned session: the app must not repeatedly fight it. Remember that a
   second write of `1` to an already-true global switch cannot be detected.
10. Remove integrations, restart both CLIs, and verify unrelated hooks still work and no
    Agent Awake helper or idle assertion remains. Leave the global setting as it was before testing.

## Primary references

- [Claude Code hook reference](https://code.claude.com/docs/en/hooks), particularly Stop,
  PermissionRequest, Notification, background tasks, and subagent fields.
- [Official OpenAI hook documentation](https://learn.chatgpt.com/docs/hooks), particularly
  tool coverage, hook trust, Interrupt, and subagent lifecycle.
- [Apple PowerManagement source](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.m),
  the system-wide SleepDisabled setting.
- [Apple assertion implementation](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmconfigd/PMAssertions.c),
  the entitlement restrictions on applying assertions to lid-close/battery behavior.
- [Apple NSXPC code-signing requirement API](https://developer.apple.com/documentation/foundation/nsxpclistener/setconnectioncodesigningrequirement(_:)),
  used to authenticate helper clients.
