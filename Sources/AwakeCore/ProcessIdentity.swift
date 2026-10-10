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
            if Provider(executablePath: executable(&info)) == provider { return ProcessIdentity(pid: pid, started: info.started) }
            pid = info.ppid
        }
        return nil
    }
    public static func discoveredAgents() -> [(Provider, ProcessIdentity)] {
        var pids = [Int32](repeating: 0, count: 8192)
        let count = aa_list_processes(&pids, Int32(pids.count))
        return pids.prefix(max(0, min(Int(count), pids.count))).compactMap { pid in
            guard let process = running(pid), let provider = Provider(executablePath: process.executable) else { return nil }
            return (provider, process.identity)
        }
    }
    /// A live process owned by the current user.
    public static func running(_ pid: Int32) -> (executable: String, identity: ProcessIdentity)? {
        var info = AAProcess()
        guard aa_process(pid, &info) == 1, info.uid == getuid() else { return nil }
        return (executable(&info), ProcessIdentity(pid: pid, started: info.started))
    }
    private static func executable(_ info: inout AAProcess) -> String {
        withUnsafePointer(to: &info.name) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
        }
    }
}

extension Provider {
    public init?(executablePath path: String) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if name == "codex" { self = .codex }
        else if name == "claude" || name == "claude.exe" || path.contains("/claude/versions/") { self = .claude }
        else { return nil }
    }
}
