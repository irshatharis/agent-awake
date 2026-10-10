# Contributing

Agent Awake is a native Swift/SwiftUI app with no third-party runtime dependencies.

1. Install Xcode Command Line Tools on macOS 14 or later (Swift 6 or later).
2. Run `scripts/check.sh` for deterministic lifecycle and policy checks.
3. Run `scripts/build-app.sh` for a signed local `.app` in `dist/`.
4. Follow `docs/VERIFICATION.md` before describing power or CLI behavior as verified.

Keep raw prompts, transcripts, tool payloads, and identifying local paths out of fixtures,
logs, issues, screenshots, and commits. Use synthetic metadata in tests. Hook handlers
must never return an agent permission decision, change agent output, or require network
access. New lifecycle support needs a source reference, a reducer or presence test, and a
live test against the affected CLI version.

Changes to the privileged helper require special care: keep its interface restricted to
fixed power operations, authenticate both XPC peers, journal before changing persistent
power state, and prove recovery when either process is killed.
