import Foundation
import ProcessSupport

public struct ProcessIdentity: Codable, Equatable, Hashable, Sendable {
    public let pid: Int32
    public let started: UInt64
    public init(pid: Int32, started: UInt64) { self.pid = pid; self.started = started }
    public static func read(_ pid: Int32) -> ProcessIdentity? {
        var info = AAProcess()
        guard aa_process(pid, &info) == 1 else { return nil }
        return ProcessIdentity(pid: pid, started: info.started)
    }
    public var isAlive: Bool { Self.read(pid) == self }
    public static func agentAncestor(provider: Provider) -> ProcessIdentity? {
        var pid = getppid()
        for _ in 0..<32 {
            var info = AAProcess()
            guard pid > 1, aa_process(pid, &info) == 1 else { return nil }
            let path = withUnsafePointer(to: &info.name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
            }
            let name = URL(fileURLWithPath: path).lastPathComponent
            let matches = provider == .codex ? name == "codex" :
                (name == "claude" || path.contains("/claude/versions/"))
            if matches { return ProcessIdentity(pid: pid, started: info.started) }
            pid = info.ppid
        }
        return nil
    }
    public static func discoveredAgents() -> [(Provider, ProcessIdentity)] {
        var pids = [Int32](repeating: 0, count: 8192)
        let count = aa_list_processes(&pids, Int32(pids.count))
        return pids.prefix(max(0, min(Int(count), pids.count))).compactMap { pid in
            var info = AAProcess()
            guard aa_process(pid, &info) == 1, info.uid == getuid() else { return nil }
            let path = withUnsafePointer(to: &info.name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
            }
            let name = URL(fileURLWithPath: path).lastPathComponent
            let provider: Provider
            if name == "codex" { provider = .codex }
            else if name == "claude" || path.contains("/claude/versions/") { provider = .claude }
            else { return nil }
            return (provider, ProcessIdentity(pid: pid, started: info.started))
        }
    }
}
