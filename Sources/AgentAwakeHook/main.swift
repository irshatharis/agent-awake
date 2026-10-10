import Foundation
import AwakeCore
import Darwin

// Hooks must never block or alter the agent's permission decisions.
// Empty stdout and exit 0 on every path are intentional.
// Only Codex uses hooks. A stale Claude hook from an older install lands in the guard.
umask(0o077)
guard CommandLine.arguments.count >= 2, CommandLine.arguments[1] == Provider.codex.rawValue,
      let process = ProcessIdentity.agentAncestor(provider: .codex) else { exit(0) }
let input = FileHandle.standardInput.readData(ofLength: 4 * 1024 * 1024 + 1)
if let event = try? HookEvent(data: input, process: process) {
    try? LocalStore().ingest(event)
}
