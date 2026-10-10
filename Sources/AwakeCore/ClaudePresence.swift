import Foundation
import Darwin

/// Claude Code writes `<config>/sessions/<pid>.json` for every running CLI process and leaves
/// files behind when a process exits. The format is undocumented, so unrecognized statuses map to unknown.
public enum ClaudePresence {
    private static let activities: [String: Activity] = ["busy": .thinking, "shell": .background, "waiting": .waiting, "idle": .idle]
    private static let sizeLimit = 64 * 1024

    public static func directory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
        return (home ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")).appendingPathComponent("sessions")
    }

    public static func sessions(in directory: URL = directory(),
                                running: (Int32) -> (executable: String, identity: ProcessIdentity)? = ProcessIdentity.running) -> [AgentSession] {
        var found: [String: AgentSession] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".json") {
            guard let pid = Int32(name.dropLast(5)), let process = running(pid),
                  Provider(executablePath: process.executable) == .claude,
                  let data = read(directory.appendingPathComponent(name)),
                  let record = try? JSONDecoder().decode(Record.self, from: data), record.pid == pid,
                  let sessionID = HookEvent.identifier(record.sessionId),
                  let start = startFormat.date(from: record.procStart),
                  abs(Double(process.identity.started) / 1_000_000 - start.timeIntervalSince1970) <= 2 else { continue }
            let session = AgentSession(id: "claude:\(sessionID):main", provider: .claude, sessionID: sessionID,
                process: process.identity, activity: activities[record.status] ?? .unknown,
                lastEvent: "status: " + (HookEvent.identifier(record.status) ?? "unrecognized"),
                updatedAt: Date(timeIntervalSince1970: record.statusUpdatedAt / 1000))
            // Two processes can report one session ID. Keep the one that should hold the Mac awake.
            if let kept = found[session.id], rank(kept) > rank(session) { continue }
            found[session.id] = session
        }
        return Array(found.values)
    }

    private struct Record: Decodable {
        let pid: Int32
        let sessionId: String
        let procStart: String
        let status: String
        let statusUpdatedAt: Double
    }
    private static func rank(_ s: AgentSession) -> (Int, Date) { (s.isWorking ? 1 : 0, s.updatedAt) }
    // Also parses ctime's double space before a single-digit day ("Thu Oct  8").
    private static let startFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f
    }()

    private static func read(_ url: URL) -> Data? {
        // O_NONBLOCK keeps a FIFO under a .json name from stalling the refresh.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFREG, st.st_size <= sizeLimit,
              let data = try? handle.read(upToCount: sizeLimit + 1), data.count <= sizeLimit else { return nil }
        return data
    }
}
