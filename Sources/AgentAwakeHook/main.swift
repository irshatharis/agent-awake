import Foundation
import AwakeCore
import Darwin

// Hooks must never block or alter the agent's permission decisions.
// Empty stdout and exit 0 on every path are intentional.
umask(0o077)
guard CommandLine.arguments.count >= 2,
      let provider = Provider(rawValue: CommandLine.arguments[1]),
      let process = ProcessIdentity.agentAncestor(provider: provider) else { exit(0) }
let input = FileHandle.standardInput.readData(ofLength: 4 * 1024 * 1024 + 1)
if let event = try? HookEvent(data: input, provider: provider, process: process) {
    try? LocalStore().ingest(event)
}
