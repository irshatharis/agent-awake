import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case claude, codex
    public var title: String { self == .claude ? "Claude Code" : "Codex" }
}
public enum Activity: String, Codable, Sendable {
    case idle, thinking, tool, waiting, background, interrupted, unknown
    public var isWorking: Bool { [.thinking, .tool, .background].contains(self) }
    public var title: String {
        switch self {
        case .idle: "Ready"
        case .thinking: "Working"
        case .tool: "Running a tool"
        case .waiting: "Waiting for you"
        case .background: "Background work"
        case .interrupted: "Interrupted"
        case .unknown: "Awaiting lifecycle hook"
        }
    }
}
public struct AgentSession: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var provider: Provider
    public var sessionID: String
    public var agentID: String?
    public var process: ProcessIdentity
    public var activity: Activity
    public var lastEvent: String
    public var updatedAt: Date
    public var pendingTools: Set<String> = []
    public var waitingTools: Set<String> = []
    public var backgroundIDs: Set<String> = []
    public var turnID: String?
    public var isWorking: Bool { activity.isWorking || !backgroundIDs.isEmpty }
    public var shortID: String { String((agentID ?? sessionID).prefix(8)) }
}

/// Deliberate allowlist: no prompt, transcript, cwd, command, response or descriptions survive decoding.
public struct HookEvent: Sendable {
    public let provider: Provider
    public let sessionID: String
    public let agentID: String?
    public let name: String
    public let turnID: String?
    public let toolID: String?
    public let asksUser: Bool
    public let notification: String?
    public let interrupted: Bool
    public let backgroundIDs: Set<String>?
    public let taskID: String?
    public let process: ProcessIdentity
    public let date: Date

    public init(data: Data, provider: Provider, process: ProcessIdentity, date: Date = Date()) throws {
        guard data.count <= 4 * 1024 * 1024,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["hook_event_name"] as? String,
              HookConfiguration.events(for: provider).contains(name),
              let session = Self.identifier(json["session_id"]) else { throw AwakeError.invalidEvent }
        self.provider = provider; self.process = process; self.date = date
        self.name = name; sessionID = session
        agentID = Self.identifier(json["agent_id"])
        turnID = Self.identifier(json["turn_id"])
        toolID = Self.identifier(json["tool_use_id"])
        taskID = Self.identifier(json["task_id"])
        let tool = json["tool_name"] as? String ?? ""
        asksUser = ["AskUserQuestion", "ExitPlanMode", "request_user_input"].contains(tool)
        notification = ["permission_prompt", "idle_prompt", "elicitation_dialog", "auth_success"].first { $0 == json["notification_type"] as? String }
        interrupted = json["is_interrupt"] as? Bool == true
        if let tasks = json["background_tasks"] as? [[String: Any]] {
            backgroundIDs = Set(tasks.compactMap { item in
                guard !["completed", "failed", "killed", "stopped"].contains(item["status"] as? String ?? "") else { return nil }
                return Self.identifier(item["id"])
            })
        } else { backgroundIDs = nil }
    }
    private static func identifier(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty, s.utf8.count <= 200,
              s.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_:.")).contains($0) }) else { return nil }
        return s
    }
}

public struct SessionStore: Codable, Sendable {
    public var version = 1
    public var sessions: [String: AgentSession] = [:]
    public init() {}
    public mutating func prune(isAlive: (ProcessIdentity) -> Bool = { $0.isAlive }) {
        sessions = sessions.filter { isAlive($0.value.process) }
    }
    public mutating func apply(_ e: HookEvent) {
        let prefix = "\(e.provider.rawValue):\(e.sessionID)"
        let key = prefix + ":" + (e.agentID ?? "main")
        if e.name == "SessionEnd" {
            sessions = sessions.filter { !($0.value.provider == e.provider && $0.value.sessionID == e.sessionID) }
            return
        }
        var s = sessions[key] ?? AgentSession(id: key, provider: e.provider, sessionID: e.sessionID,
            agentID: e.agentID, process: e.process, activity: .unknown, lastEvent: e.name, updatedAt: e.date)
        if s.process != e.process {
            s.pendingTools = []; s.waitingTools = []; s.backgroundIDs = []; s.activity = .unknown
        }
        s.process = e.process
        s.lastEvent = e.name; s.updatedAt = e.date
        if let turn = e.turnID { s.turnID = turn }
        var tool = e.toolID ?? "unspecified"
        // Claude PermissionRequest deliberately omits tool_use_id. Correlate only
        // when one pending call makes the identity unambiguous. With parallel calls
        // an unidentified permission must not hide independently running tools.
        if e.name == "PermissionRequest", e.toolID == nil, s.pendingTools.count == 1 {
            tool = s.pendingTools.first!
        }
        // A permission request may be our first event (e.g. setup mid-session).
        // Its anonymous placeholder is resolved by the sole subsequent result.
        if ["PostToolUse", "PostToolUseFailure", "PermissionDenied"].contains(e.name),
           s.pendingTools == ["unspecified"] {
            tool = "unspecified"
        }
        switch e.name {
        case "SessionStart": s.activity = .idle
        case "UserPromptSubmit":
            s.activity = .thinking; s.pendingTools = []; s.waitingTools = []
        case "SubagentStart", "PreCompact", "PostCompact", "ElicitationResult": s.activity = .thinking
        case "PreToolUse":
            s.pendingTools.insert(tool)
            if e.asksUser { s.waitingTools.insert(tool) } else { s.waitingTools.remove(tool) }
            s.activity = s.pendingTools.subtracting(s.waitingTools).isEmpty ? .waiting : .tool
        case "PermissionRequest", "Elicitation":
            s.pendingTools.insert(tool); s.waitingTools.insert(tool)
            s.activity = s.pendingTools.subtracting(s.waitingTools).isEmpty ? .waiting : .tool
        case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
            s.pendingTools.remove(tool); s.waitingTools.remove(tool)
            if e.interrupted { s.activity = .interrupted; s.pendingTools = []; s.waitingTools = [] }
            else if !s.pendingTools.subtracting(s.waitingTools).isEmpty { s.activity = .tool }
            else { s.activity = s.waitingTools.isEmpty ? .thinking : .waiting }
        case "Stop", "SubagentStop", "StopFailure", "TeammateIdle":
            s.activity = .idle; s.pendingTools = []; s.waitingTools = []
            // Claude's SubagentStop background_tasks snapshot belongs to the parent
            // session. Keeping it on the stopped child duplicates tasks and can keep
            // protection alive after the parent's later snapshot is empty.
            if e.provider == .claude, e.name == "SubagentStop", e.agentID != nil {
                s.backgroundIDs = []
                if let ids = e.backgroundIDs {
                    let parentKey = prefix + ":main"
                    var parent = sessions[parentKey] ?? AgentSession(id: parentKey, provider: e.provider,
                        sessionID: e.sessionID, process: e.process, activity: .unknown,
                        lastEvent: e.name, updatedAt: e.date)
                    // This snapshot belongs to the currently owning CLI process.
                    if parent.process != e.process {
                        parent.pendingTools = []; parent.waitingTools = []; parent.activity = .unknown
                    }
                    parent.process = e.process
                    parent.backgroundIDs = ids
                    parent.lastEvent = e.name; parent.updatedAt = e.date
                    if sessions[parentKey] != nil || !ids.isEmpty { sessions[parentKey] = parent }
                }
            } else if let ids = e.backgroundIDs { s.backgroundIDs = ids }
            if e.name == "SubagentStop", let agent = e.agentID {
                // A parent's background snapshot may include this same child.
                for id in sessions.keys where sessions[id]?.sessionID == e.sessionID && sessions[id]?.provider == e.provider {
                    sessions[id]?.backgroundIDs.remove(agent)
                }
            }
        case "Interrupt":
            s.activity = .interrupted; s.pendingTools = []; s.waitingTools = []
            // Codex's Interrupt covers the parent only. Independently running children retain their state.
        case "Notification":
            if e.notification == "idle_prompt" { s.activity = .idle; s.pendingTools = []; s.waitingTools = []; s.backgroundIDs = [] }
            else if e.notification == "permission_prompt" || e.notification == "elicitation_dialog" { s.activity = .waiting }
        case "TaskCompleted":
            if let task = e.taskID {
                s.backgroundIDs.remove(task)
                for id in sessions.keys where sessions[id]?.sessionID == e.sessionID && sessions[id]?.provider == e.provider {
                    sessions[id]?.backgroundIDs.remove(task)
                }
            }
        default: break
        }
        sessions[key] = s
        if sessions.count > 512 {
            for old in sessions.values.sorted(by: { $0.updatedAt < $1.updatedAt }).prefix(sessions.count - 512) { sessions.removeValue(forKey: old.id) }
        }
    }
}

public enum AwakeError: Error, LocalizedError {
    case invalidEvent, invalidConfiguration(String), unsafePath, lockTimeout, helper(String)
    public var errorDescription: String? {
        switch self {
        case .invalidEvent: "Unsupported or malformed hook event."
        case .invalidConfiguration(let text): text
        case .unsafePath: "Agent Awake found an unsafe file owner, permission, or symbolic link."
        case .lockTimeout: "Session storage is busy."
        case .helper(let text): text
        }
    }
}
