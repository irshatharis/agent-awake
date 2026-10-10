import Foundation
import AwakeCore
final class ConfigurationTests {
    func testInstallTwiceAndRemovePreservesForeignHandlersAndSettings() throws {
        let original = Data(#"{"theme":"dark","hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"notify me","timeout":4}]}],"UnknownFutureEvent":[{"hooks":[{"type":"command","command":"custom"}]}]}}"#.utf8)
        let command = HookConfiguration.command(executable: URL(fileURLWithPath: "/Applications/Agent Awake.app/Contents/Helpers/agent-awake-hook"))
        let first = try HookConfiguration.merge(original, command: command)
        let second = try HookConfiguration.merge(first, command: command)
        expectEqual(first, second)
        let removed = try HookConfiguration.merge(second, command: command, remove: true)
        try expectEqual(try JSONSerialization.jsonObject(with: original) as? NSDictionary, try JSONSerialization.jsonObject(with: removed) as? NSDictionary)
    }
    func testDotfileSymlinkInstallAndRemoval() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("dotfile.json")
        let link = dir.appendingPathComponent("settings.json")
        let original = Data(#"{"theme":"dark"}"#.utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let installer = HookInstaller(store: LocalStore(directory: dir.appendingPathComponent("metadata")))
        try installer.install(executable: URL(fileURLWithPath: "/Applications/Agent Awake.app/Contents/Helpers/agent-awake-hook"), config: link)
        try expectEqual(FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        try expectTrue(String(contentsOf: target, encoding: .utf8).contains("UserPromptSubmit"))
        try installer.uninstall()
        try expectEqual(JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? NSDictionary, JSONSerialization.jsonObject(with: original) as? NSDictionary)
        try expectEqual(FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }
    func testMalformedConfigIsNotOverwritten() {
        expectThrows(try HookConfiguration.merge(Data("invalid".utf8), command: "x"))
        expectThrows(try HookConfiguration.merge(Data(#"{"hooks":{"Stop":"bad"}}"#.utf8), command: "x"))
    }
    func testPrivateAtomicStoreAndSymlinkRejection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalStore(directory: dir)
        try store.locked { try store.write(SessionStore()) }
        try expectTrue(try store.snapshot().sessions.isEmpty)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("sessions.json").path)
        expectEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("sessions.json"))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("sessions.json"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        expectThrows(try store.snapshot())
    }
    func testUnreadableStoreDoesNotBlockTracking() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalStore(directory: dir)
        try store.prepare()
        let file = dir.appendingPathComponent("sessions.json")
        try Data(#"{"version":2,"sessions":{"codex:old:main":{"id":"codex:old:main"}}}"#.utf8).write(to: file)
        chmod(file.path, 0o600)
        let me = ProcessIdentity.read(getpid())!
        let event = try HookEvent(data: Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1"}"#.utf8), process: me)
        try store.ingest(event)
        try expectEqual(store.snapshot().sessions.keys.sorted(), ["codex:s1:main"])
    }
    func testLegacyClaudeHookCleanupPreservesEverythingElse() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = dir.appendingPathComponent("settings.json"), codex = dir.appendingPathComponent("hooks.json")
        let hook = URL(fileURLWithPath: "/Applications/Agent Awake.app/Contents/Helpers/agent-awake-hook")
        // One command is recorded in the manifest from a former app location; the other,
        // from the current location, has no manifest entry.
        let recorded = "'/Users/u/Downloads/Agent Awake.app/Contents/Helpers/agent-awake-hook' claude --managed-by-agent-awake-v1"
        let unrecorded = HookConfiguration.shellQuote(hook.path) + " claude --managed-by-agent-awake-v1"
        let ours: [String: Any] = ["type": "command", "command": recorded, "timeout": 1]
        let current: [String: Any] = ["type": "command", "command": unrecorded, "timeout": 1]
        let notify: [String: Any] = ["matcher": "", "hooks": [["type": "command", "command": "notify me"]]]
        let other: [String: Any] = ["type": "command", "command": "other tool"]
        let foreign: [String: Any] = ["theme": "dark", "hooks": ["Stop": [notify], "UserPromptSubmit": [["hooks": [other]]]]]
        let installed: [String: Any] = ["theme": "dark", "hooks": [
            "Stop": [notify, ["hooks": [ours]]],
            "UserPromptSubmit": [["hooks": [ours, other]]],
            "Notification": [["matcher": "permission_prompt|idle_prompt|elicitation_dialog", "hooks": [ours]]],
            "TaskCompleted": [["hooks": [current]]],
            "PreToolUse": [["hooks": [current]]]
        ]]
        try JSONSerialization.data(withJSONObject: installed).write(to: settings)
        let installer = HookInstaller(store: LocalStore(directory: dir.appendingPathComponent("metadata")))
        try installer.install(executable: hook, config: codex)
        let manifest = dir.appendingPathComponent("metadata/installed-hooks.json")
        var entries = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [[String: Any]]
        entries.append(["provider": "claude", "path": settings.resolvingSymlinksInPath().path, "command": recorded])
        try JSONSerialization.data(withJSONObject: entries).write(to: manifest)

        try expectTrue(installer.removeLegacyClaudeHooks(executable: hook, config: settings))
        try expectEqual(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? NSDictionary, foreign as NSDictionary)
        try expectTrue(String(contentsOf: codex, encoding: .utf8).contains("agent-awake-hook' codex"))
        try expectEqual(installer.installed().map(\.provider), [.codex])
        let cleaned = try Data(contentsOf: settings)
        try expectFalse(installer.removeLegacyClaudeHooks(executable: hook, config: settings))
        try expectEqual(Data(contentsOf: settings), cleaned)
    }
    func testUninstallRemovesWhatItCanAndKeepsFailures() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let broken = dir.appendingPathComponent("broken.json"), codex = dir.appendingPathComponent("codex.json")
        let installer = HookInstaller(store: LocalStore(directory: dir.appendingPathComponent("metadata")))
        let hook = URL(fileURLWithPath: "/Applications/Agent Awake.app/Contents/Helpers/agent-awake-hook")
        try installer.install(executable: hook, config: broken)
        try installer.install(executable: hook, config: codex)
        try Data("{ not json".utf8).write(to: broken)
        expectThrows(try installer.uninstall())
        try expectFalse(String(contentsOf: codex, encoding: .utf8).contains("agent-awake-hook"))
        try expectEqual(installer.installed().map(\.path), [broken.path])
    }
}

