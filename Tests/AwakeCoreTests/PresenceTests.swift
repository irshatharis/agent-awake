import Foundation
import Darwin
import AwakeCore

final class PresenceTests {
    let claude = "/Users/u/.local/share/claude/versions/2.1.296"
    // Epoch values come from `date -u -j -f`, not from the parser under test.
    let started: UInt64 = 1_791_613_958_000_000
    let startText = "Sat Oct 10 06:32:38 2026"

    func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func write(_ dir: URL, pid: Int32, file: String? = nil, _ overrides: [String: Any] = [:]) throws {
        var json: [String: Any] = ["pid": pid, "sessionId": "session-\(pid)", "procStart": startText, "status": "busy",
                                   "statusUpdatedAt": 1_791_615_789_305, "updatedAt": 1, "kind": "interactive"]
        json.merge(overrides) { $1 }
        try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent(file ?? "\(pid).json"))
    }
    func live(_ table: [Int32: (String, UInt64)]) -> (Int32) -> (executable: String, identity: ProcessIdentity)? {
        { pid in table[pid].map { ($0.0, ProcessIdentity(pid: pid, started: $0.1)) } }
    }

    func testStatusMapping() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cases: [(String, Activity, Bool)] = [("busy", .thinking, true), ("shell", .background, true),
            ("waiting", .waiting, false), ("idle", .idle, false), ("compacting", .unknown, false)]
        for (status, activity, working) in cases {
            try write(dir, pid: 100, ["status": status, "sessionId": "93e59403-aaaa", "cwd": "/PRIVATE_PATH", "name": "SECRET_NAME"])
            let sessions = ClaudePresence.sessions(in: dir, running: live([100: (claude, started)]))
            expectEqual(sessions.count, 1, status)
            guard let s = sessions.first else { continue }
            expectEqual(s.activity, activity, status)
            expectEqual(s.isWorking, working, status)
            expectEqual(s.id, "claude:93e59403-aaaa:main")
            expectEqual(s.provider, .claude)
            expectEqual(s.process, ProcessIdentity(pid: 100, started: started))
            expectEqual(s.lastEvent, "status: \(status)")
            expectEqual(s.updatedAt, Date(timeIntervalSince1970: 1_791_615_789.305))
            let encoded = String(decoding: try JSONEncoder().encode(sessions), as: UTF8.self)
            expectFalse(encoded.contains("PRIVATE_PATH")); expectFalse(encoded.contains("SECRET_NAME"))
        }
    }
    func testOnlyLiveClaudeProcessWithMatchingStartCounts() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for pid: Int32 in [200, 201, 202, 203, 204, 205] { try write(dir, pid: pid) }
        let sessions = ClaudePresence.sessions(in: dir, running: live([
            // 200 has exited: no process.
            201: (claude, started + 5_000_000),
            202: ("/usr/local/bin/node", started),
            203: (claude, started + 1_500_000),
            204: (claude, started - 3_000_000),
            205: ("/opt/homebrew/Caskroom/codex/0.162.0/bin/codex", started)
        ]))
        expectEqual(sessions.map(\.process.pid).sorted(), [203])
    }
    func testSingleDigitDayDoubleSpace() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(dir, pid: 300, ["procStart": "Thu Oct  8 11:52:04 2026"])
        let sessions = ClaudePresence.sessions(in: dir, running: live([300: (claude, 1_791_460_324_000_000)]))
        expectEqual(sessions.map(\.process.pid), [300])
        let wrongDay = ClaudePresence.sessions(in: dir, running: live([300: (claude, 1_791_460_324_000_000 + 86_400_000_000)]))
        expectTrue(wrongDay.isEmpty)
    }
    func testUnsafeAndMalformedFilesSkipped() throws {
        let dir = try directory(), outside = try directory()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: outside) }
        try write(dir, pid: 400)
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("401.json"))
        try write(dir, pid: 402, ["padding": String(repeating: "x", count: 70 * 1024)])
        try write(outside, pid: 403)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("403.json"), withDestinationURL: outside.appendingPathComponent("403.json"))
        try write(dir, pid: 404, ["sessionId": "../../etc"])
        try write(dir, pid: 406, file: "405.json")
        try write(dir, pid: 407, ["status": NSNull()])
        expectEqual(mkfifo(dir.appendingPathComponent("408.json").path, 0o600), 0)
        try Data("key".utf8).write(to: dir.appendingPathComponent("400.0123abcd.key"))
        let pids: [Int32] = [400, 401, 402, 403, 404, 405, 406, 407, 408]
        let sessions = ClaudePresence.sessions(in: dir, running: live(Dictionary(uniqueKeysWithValues: pids.map { ($0, (claude, started)) })))
        expectEqual(sessions.map(\.process.pid), [400])
    }
    func testSharedSessionIDKeepsWorkingProcess() throws {
        for (busy, idle): (Int32, Int32) in [(500, 501), (503, 502)] {
            let dir = try directory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try write(dir, pid: busy, ["sessionId": "shared", "status": "busy", "statusUpdatedAt": 1000])
            try write(dir, pid: idle, ["sessionId": "shared", "status": "idle", "statusUpdatedAt": 2000])
            let sessions = ClaudePresence.sessions(in: dir, running: live([busy: (claude, started), idle: (claude, started)]))
            expectEqual(sessions.map(\.process.pid), [busy])
        }
    }
    func testDirectoryFollowsClaudeConfigDir() {
        expectEqual(ClaudePresence.directory(environment: ["CLAUDE_CONFIG_DIR": "/tmp/alt-claude"]).path, "/tmp/alt-claude/sessions")
        expectEqual(ClaudePresence.directory(environment: [:]).path,
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions").path)
    }
}
