import Foundation
import Darwin

public final class LocalStore {
    public let directory: URL
    public init(directory: URL = LocalStore.defaultDirectory) { self.directory = directory }
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Awake", isDirectory: true)
    }
    public func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var st = stat()
        guard lstat(directory.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == getuid(), st.st_mode & 0o077 == 0 else { throw AwakeError.unsafePath }
    }
    public func locked<T>(_ body: () throws -> T) throws -> T {
        try prepare()
        let fd = open(directory.appendingPathComponent("store.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AwakeError.unsafePath }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o077 == 0, st.st_nlink == 1 else { throw AwakeError.unsafePath }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.4
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw AwakeError.lockTimeout }
            usleep(5_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    public func read() throws -> SessionStore {
        let url = directory.appendingPathComponent("sessions.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return SessionStore() }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AwakeError.unsafePath }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o077 == 0,
              (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= 2 * 1024 * 1024 else { throw AwakeError.unsafePath }
        // Later hook events rebuild session state, so a file from another version starts fresh.
        return (try? JSONDecoder().decode(SessionStore.self, from: handle.readToEnd() ?? Data())) ?? SessionStore()
    }
    public func write(_ state: SessionStore) throws {
        let data = try JSONEncoder().encode(state)
        guard data.count <= 2 * 1024 * 1024 else { throw AwakeError.invalidConfiguration("Session metadata exceeded its storage limit.") }
        let url = directory.appendingPathComponent("sessions.json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func ingest(_ event: HookEvent) throws {
        try locked {
            var state = try read()
            state.prune()
            state.apply(event)
            try write(state)
        }
    }
    public func snapshot() throws -> SessionStore {
        try locked {
            var state = try read()
            let count = state.sessions.count
            state.prune()
            if state.sessions.count != count { try write(state) }
            return state
        }
    }
}
