import Foundation
import Darwin

public enum HookConfiguration {
    public static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
                                "PostToolUse", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact", "Stop", "Interrupt"]
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func command(executable: URL) -> String {
        shellQuote(executable.path) + " codex --managed-by-agent-awake-v1"
    }
    public static func merge(_ data: Data?, command: String, remove: Bool = false) throws -> Data {
        var root: [String: Any] = [:]
        if let data {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AwakeError.invalidConfiguration("Hook configuration must be a JSON object. No changes were made.")
            }
            root = decoded
        }
        if let existing = root["hooks"], !(existing is [String: Any]) {
            throw AwakeError.invalidConfiguration("Existing hooks have an unsupported format. No changes were made.")
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        // Removal scans every event so commands installed under retired event lists, such as
        // the former Claude Code hooks, are removed too.
        for event in remove ? hooks.keys.sorted() : events {
            if let value = hooks[event], !(value is [[String: Any]]) {
                throw AwakeError.invalidConfiguration("Existing \(event) hooks have an unsupported format. No changes were made.")
            }
            let groups = hooks[event] as? [[String: Any]] ?? []
            var updated: [[String: Any]] = []
            for var group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    throw AwakeError.invalidConfiguration("Existing \(event) hook group is malformed. No changes were made.")
                }
                let kept = handlers.filter { ($0["command"] as? String) != command || ($0["type"] as? String) != "command" }
                if !kept.isEmpty { group["hooks"] = kept; updated.append(group) }
            }
            if !remove { updated.append(["hooks": [["type": "command", "command": command, "timeout": 1]]]) }
            if updated.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = updated }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
    }
}

public struct InstalledHook: Codable {
    public var provider: Provider
    public var path: String
    public var command: String
}
public final class HookInstaller {
    public let store: LocalStore
    public init(store: LocalStore = LocalStore()) { self.store = store }
    public var configURL: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
        return (home ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")).appendingPathComponent("hooks.json")
    }
    private var manifestURL: URL { store.directory.appendingPathComponent("installed-hooks.json") }
    public func installed() throws -> [InstalledHook] {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return [] }
        return try JSONDecoder().decode([InstalledHook].self, from: Data(contentsOf: manifestURL))
    }
    public func install(executable: URL, config: URL? = nil) throws {
        try store.locked {
            var entries = try installed()
            let url = try resolvedConfiguration(config ?? configURL)
            let command = HookConfiguration.command(executable: executable)
            // Preserve exact previous commands so relocating the application remains removable.
            let original = try existing(url)
            var data = original
            for old in entries where old.provider == .codex && old.path == url.path {
                data = try HookConfiguration.merge(data, command: old.command, remove: true)
            }
            let merged = try HookConfiguration.merge(data, command: command)
            try replace(url, data: merged, expected: original)
            entries.removeAll { $0.provider == .codex && $0.path == url.path }
            entries.append(InstalledHook(provider: .codex, path: url.path, command: command))
            try JSONEncoder().encode(entries).write(to: manifestURL, options: .atomic)
            chmod(manifestURL.path, 0o600)
        }
    }
    public func uninstall() throws {
        try store.locked {
            var remaining: [InstalledHook] = []
            var failures: [String] = []
            for entry in try installed() {
                let url = URL(fileURLWithPath: entry.path)
                do {
                    if let data = try existing(url) {
                        try replace(url, data: HookConfiguration.merge(data, command: entry.command, remove: true), expected: data)
                    }
                } catch {
                    remaining.append(entry)
                    failures.append("\(entry.path): \(error.localizedDescription)")
                }
            }
            try JSONEncoder().encode(remaining).write(to: manifestURL, options: .atomic)
            chmod(manifestURL.path, 0o600)
            if !failures.isEmpty {
                throw AwakeError.invalidConfiguration("Could not remove hooks from " + failures.joined(separator: "; "))
            }
        }
    }
    private func resolvedConfiguration(_ url: URL) throws -> URL {
        var source = stat()
        if lstat(url.path, &source) == 0 {
            guard source.st_uid == getuid() else { throw AwakeError.unsafePath }
        } else if errno != ENOENT { throw AwakeError.unsafePath }
        // Dotfile managers commonly symlink settings. Resolve once and record the
        // owned regular target in the manifest; never replace the user's symlink.
        let resolved = url.resolvingSymlinksInPath()
        _ = try existing(resolved)
        return resolved
    }
    private func existing(_ url: URL) throws -> Data? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            if errno == ENOENT { return nil }
            throw AwakeError.unsafePath
        }
        guard st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1 else { throw AwakeError.unsafePath }
        return try Data(contentsOf: url)
    }
    private func replace(_ url: URL, data: Data, expected: Data?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Detect editor saves since `expected` was read, rather than silently overwriting them.
        guard try existing(url) == expected else { throw AwakeError.invalidConfiguration("Configuration changed during setup. Try again.") }
        // Backups are private and local. They can contain pre-existing user configuration.
        if let expected {
            let backup = url.appendingPathExtension("agent-awake-\(UUID().uuidString).bak")
            try expected.write(to: backup, options: .withoutOverwriting)
            chmod(backup.path, 0o600)
        }
        try data.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }
}
