import Foundation
import AwakeCore

final class ActivityTests {
    let process = ProcessIdentity(pid: 42, started: 100)
    func event(_ name: String, provider: Provider = .claude, session: String = "s1", fields: [String: Any] = [:]) throws -> HookEvent {
        var json = fields; json["hook_event_name"] = name; json["session_id"] = session
        return try HookEvent(data: JSONSerialization.data(withJSONObject: json), provider: provider, process: process)
    }
    func testCompleteLifecycleForBothProviders() throws {
        for provider in Provider.allCases {
            var store = SessionStore()
            for (name, state) in [("SessionStart", Activity.idle), ("UserPromptSubmit", .thinking), ("PreToolUse", .tool), ("PermissionRequest", .waiting), ("PostToolUse", .thinking), ("Stop", .idle)] {
                store.apply(try event(name, provider: provider, fields: ["tool_use_id": "tool1"]))
                expectEqual(store.sessions.values.first?.activity, state, name)
            }
            store.apply(try event("SessionEnd", provider: provider))
            expectTrue(store.sessions.isEmpty)
        }
    }
    func testSubagentOutlivesParentAndOtherSessionWaits() throws {
        var store = SessionStore()
        store.apply(try event("UserPromptSubmit"))
        store.apply(try event("UserPromptSubmit", session: "s2"))
        store.apply(try event("SubagentStart", fields: ["agent_id": "child1"]))
        store.apply(try event("PermissionRequest", session: "s2"))
        store.apply(try event("Stop"))
        expectEqual(store.sessions.values.filter(\.isWorking).count, 1)
        store.apply(try event("SubagentStop", fields: ["agent_id": "child1"]))
        expectFalse(store.sessions.values.contains(where: \.isWorking))
    }
    func testParallelPermissionDoesNotHideRunningTool() throws {
        var store = SessionStore()
        store.apply(try event("PreToolUse", fields: ["tool_use_id": "a"]))
        store.apply(try event("PreToolUse", fields: ["tool_use_id": "b"]))
        store.apply(try event("PermissionRequest", fields: ["tool_use_id": "b"]))
        expectEqual(store.sessions.values.first?.activity, .tool)
        store.apply(try event("PostToolUse", fields: ["tool_use_id": "a"]))
        expectEqual(store.sessions.values.first?.activity, .waiting)
    }
    func testClaudePermissionWithoutToolID() throws {
        var store = SessionStore()
        store.apply(try event("PreToolUse", fields: ["tool_use_id": "a", "tool_name": "Bash"]))
        store.apply(try event("PermissionRequest", fields: ["tool_name": "Bash"]))
        expectEqual(store.sessions.values.first?.activity, .waiting)
        expectEqual(store.sessions.values.first?.pendingTools, ["a"])
        store.apply(try event("PostToolUse", fields: ["tool_use_id": "a"]))
        expectEqual(store.sessions.values.first?.activity, .thinking)
        expectTrue(store.sessions.values.first!.waitingTools.isEmpty)

        // Tracking may begin at a permission event, before observing PreToolUse.
        store = SessionStore()
        store.apply(try event("PermissionRequest"))
        store.apply(try event("PostToolUse", fields: ["tool_use_id": "a"]))
        expectEqual(store.sessions.values.first?.activity, .thinking)
        expectTrue(store.sessions.values.first!.pendingTools.isEmpty)

        // Missing IDs cannot identify a particular call in a parallel batch.
        store = SessionStore()
        store.apply(try event("PreToolUse", fields: ["tool_use_id": "a"]))
        store.apply(try event("PreToolUse", fields: ["tool_use_id": "b"]))
        store.apply(try event("PermissionRequest"))
        expectEqual(store.sessions.values.first?.activity, .tool)
        expectEqual(store.sessions.values.first?.pendingTools.subtracting(store.sessions.values.first!.waitingTools), ["a", "b"])
    }
    func testSubagentStopDoesNotRetainParentBackgroundSnapshot() throws {
        var store = SessionStore()
        store.apply(try event("SubagentStart", fields: ["agent_id": "child1"]))
        store.apply(try event("Stop", fields: ["background_tasks": [["id": "child1", "status": "running"], ["id": "job1", "status": "running"]]]))
        store.apply(try event("SubagentStop", fields: ["agent_id": "child1", "background_tasks": [["id": "job1", "status": "running"]]]))
        expectFalse(store.sessions["claude:s1:child1"]!.isWorking)
        expectEqual(store.sessions["claude:s1:main"]!.backgroundIDs, ["job1"])
        expectTrue(store.sessions.values.contains(where: \.isWorking))
        store.apply(try event("Stop", fields: ["background_tasks": []]))
        expectFalse(store.sessions.values.contains(where: \.isWorking))

        // A child snapshot can be the first evidence of parent background work.
        store = SessionStore()
        store.apply(try event("SubagentStop", fields: ["agent_id": "child1", "background_tasks": [["id": "child1", "status": "running"], ["id": "job1", "status": "running"]]]))
        expectFalse(store.sessions["claude:s1:child1"]!.isWorking)
        expectEqual(store.sessions["claude:s1:main"]!.backgroundIDs, ["job1"])
        store.apply(try event("TaskCompleted", fields: ["task_id": "job1"]))
        expectFalse(store.sessions.values.contains(where: \.isWorking))
    }
    func testQuestionWaitsAndResumes() throws {
        var store = SessionStore()
        store.apply(try event("PreToolUse", fields: ["tool_name": "AskUserQuestion"]))
        expectFalse(store.sessions.values.first!.isWorking)
        store.apply(try event("PostToolUse", fields: ["tool_name": "AskUserQuestion"]))
        expectTrue(store.sessions.values.first!.isWorking)
    }
    func testInterruptAndCrash() throws {
        var store = SessionStore()
        store.apply(try event("UserPromptSubmit", provider: .codex))
        store.apply(try event("Interrupt", provider: .codex))
        expectEqual(store.sessions.values.first?.activity, .interrupted)
        store.prune { _ in false }
        expectTrue(store.sessions.isEmpty)
    }
    func testBackgroundWorkAndCompletion() throws {
        var store = SessionStore()
        store.apply(try event("Stop", fields: ["background_tasks": [["id": "job1", "status": "running", "command": "SECRET"]]]))
        expectTrue(store.sessions.values.first!.isWorking)
        store.apply(try event("TaskCompleted", fields: ["task_id": "job1"]))
        expectFalse(store.sessions.values.first!.isWorking)
    }
    func testPrivacyAllowlist() throws {
        var store = SessionStore()
        store.apply(try event("PreToolUse", fields: ["prompt": "PROMPT_SECRET", "tool_input": ["command": "COMMAND_SECRET"], "tool_response": "OUTPUT_SECRET", "cwd": "/PRIVATE_PATH", "transcript_path": "/TRANSCRIPT_SECRET"]))
        let json = String(decoding: try JSONEncoder().encode(store), as: UTF8.self)
        expectFalse(json.contains("SECRET")); expectFalse(json.contains("PRIVATE_PATH"))
    }
    func testUnknownEventsRejectedAndPIDReusePruned() throws {
        expectThrows(try event("FakeEvent"))
        var store = SessionStore(); store.apply(try event("UserPromptSubmit"))
        store.prune { $0 == ProcessIdentity(pid: 42, started: 999) }
        expectTrue(store.sessions.isEmpty)
    }
    func testRecognizesEachInstallLayout() {
        let layouts: [(String, Provider?)] = [
            ("/Users/u/.local/share/claude/versions/2.1.296", .claude),
            ("/opt/homebrew/Caskroom/claude-code/2.1.296/claude", .claude),
            ("/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe", .claude),
            ("/opt/homebrew/Caskroom/codex/0.162.0/bin/codex", .codex),
            ("/usr/local/lib/node_modules/@openai/codex/vendor/aarch64-apple-darwin/codex/codex", .codex),
            ("/usr/local/bin/node", nil),
            ("/bin/zsh", nil)
        ]
        for (path, provider) in layouts { expectEqual(Provider(executablePath: path), provider, path) }
    }
}
