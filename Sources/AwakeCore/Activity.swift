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
        case .unknown: "Activity unknown"
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
    public var turnID: String?
    public var isWorking: Bool { activity.isWorking }
    public var shortID: String { String((agentID ?? sessionID).prefix(8)) }
}

/// Codex lifecycle hooks only. Deliberate allowlist: no prompt, transcript, cwd, command, response or descriptions survive decoding.
public struct HookEvent: Sendable {
    public let sessionID: String
    public let agentID: String?
    public let name: String
    public let turnID: String?
    public let toolID: String?
    public let asksUser: Bool
    public let process: ProcessIdentity
    public let date: Date

    public init(data: Data, process: ProcessIdentity, date: Date = Date()) throws {
        guard data.count <= 4 * 1024 * 1024,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["hook_event_name"] as? String,
              HookConfiguration.events.contains(name),
              let session = Self.identifier(json["session_id"]) else { throw AwakeError.invalidEvent }
        self.process = process; self.date = date
        self.name = name; sessionID = session
        agentID = Self.identifier(json["agent_id"])
        turnID = Self.identifier(json["turn_id"])
        toolID = Self.identifier(json["tool_use_id"])
        asksUser = json["tool_name"] as? String == "request_user_input"
    }
    static func identifier(_ value: Any?) -> String? {
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
        let key = "codex:\(e.sessionID):" + (e.agentID ?? "main")
        if e.name == "SessionEnd" {
            sessions = sessions.filter { $0.value.sessionID != e.sessionID }
            return
        }
        var s = sessions[key] ?? AgentSession(id: key, provider: .codex, sessionID: e.sessionID,
            agentID: e.agentID, process: e.process, activity: .unknown, lastEvent: e.name, updatedAt: e.date)
        if s.process != e.process {
            s.pendingTools = []; s.waitingTools = []; s.activity = .unknown
        }
        s.process = e.process
        s.lastEvent = e.name; s.updatedAt = e.date
        if let turn = e.turnID { s.turnID = turn }
        var tool = e.toolID ?? "unspecified"
        // A permission request without tool_use_id is correlated only when one pending
        // call makes the identity unambiguous. With parallel calls an unidentified
        // permission must not hide independently running tools.
        if e.name == "PermissionRequest", e.toolID == nil, s.pendingTools.count == 1 {
            tool = s.pendingTools.first!
        }
        switch e.name {
        case "SessionStart": s.activity = .idle
        case "UserPromptSubmit":
            s.activity = .thinking; s.pendingTools = []; s.waitingTools = []
        case "SubagentStart", "PreCompact", "PostCompact": s.activity = .thinking
        case "PreToolUse":
            s.pendingTools.insert(tool)
            if e.asksUser { s.waitingTools.insert(tool) } else { s.waitingTools.remove(tool) }
            s.activity = s.pendingTools.subtracting(s.waitingTools).isEmpty ? .waiting : .tool
        case "PermissionRequest":
            s.pendingTools.insert(tool); s.waitingTools.insert(tool)
            s.activity = s.pendingTools.subtracting(s.waitingTools).isEmpty ? .waiting : .tool
        case "PostToolUse":
            // An anonymous permission placeholder cannot be matched to a call.
            // Any result means its call has resolved or is running, so it must not outlive it.
            s.pendingTools.remove(tool); s.waitingTools.remove(tool)
            s.pendingTools.remove("unspecified"); s.waitingTools.remove("unspecified")
            if !s.pendingTools.subtracting(s.waitingTools).isEmpty { s.activity = .tool }
            else { s.activity = s.waitingTools.isEmpty ? .thinking : .waiting }
        case "Stop", "SubagentStop":
            s.activity = .idle; s.pendingTools = []; s.waitingTools = []
        case "Interrupt":
            s.activity = .interrupted; s.pendingTools = []; s.waitingTools = []
            // Codex's Interrupt covers the parent only. Independently running children retain their state.
        default: break
        }
        if e.name == "SubagentStop", e.agentID != nil { sessions.removeValue(forKey: key) } else { sessions[key] = s }
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
