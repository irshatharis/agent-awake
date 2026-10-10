import Foundation

public struct AwakePolicy: Sendable {
    public var automatic = true
    public var paused = false
    public var manualUntil: Date?
    public var indefinite = false
    public var cutoffEnabled = false
    public var cutoffPercent = 20
    public var graceSeconds: TimeInterval = 8
    private var releaseAt: TimeInterval?
    private var wasWorking = false
    public init() {}
    public mutating func allowSleep() {
        paused = true; manualUntil = nil; indefinite = false; releaseAt = nil; wasWorking = false
    }
    public mutating func evaluate(sessions: [AgentSession], now: Date, uptime: TimeInterval, battery: Int?, onBattery: Bool, thermal: ProcessInfo.ThermalState) -> PowerDecision {
        if let until = manualUntil, until <= now { manualUntil = nil }
        if thermal == .critical {
            releaseAt = nil; wasWorking = false
            return PowerDecision(preventSleep: false, reason: "Mac is too hot", graceRemaining: nil)
        }
        if cutoffEnabled && onBattery, let battery, battery <= cutoffPercent {
            releaseAt = nil; wasWorking = false
            return PowerDecision(preventSleep: false, reason: "Battery at or below \(cutoffPercent)%", graceRemaining: nil)
        }
        let working = automatic && !paused ? sessions.filter(\.isWorking) : []
        if !working.isEmpty { wasWorking = true; releaseAt = nil }
        else if wasWorking { wasWorking = false; releaseAt = uptime + graceSeconds }
        if indefinite { return PowerDecision(preventSleep: true, reason: "Indefinite session", graceRemaining: nil) }
        if let until = manualUntil { return PowerDecision(preventSleep: true, reason: "Manual session until \(until.formatted(date: .omitted, time: .shortened))", graceRemaining: nil) }
        if !working.isEmpty { return PowerDecision(preventSleep: true, reason: "\(working.count) active agent\(working.count == 1 ? "" : "s")", graceRemaining: nil) }
        if automatic && !paused, let end = releaseAt, end > uptime {
            return PowerDecision(preventSleep: true, reason: "Agents finished · settling down", graceRemaining: Int(ceil(end - uptime)))
        }
        releaseAt = nil
        return PowerDecision(preventSleep: false, reason: paused ? "Automatic mode paused" : "No active agents", graceRemaining: nil)
    }
}
public struct PowerDecision: Equatable, Sendable {
    public let preventSleep: Bool
    public let reason: String
    public let graceRemaining: Int?
    public init(preventSleep: Bool, reason: String, graceRemaining: Int?) {
        self.preventSleep = preventSleep; self.reason = reason; self.graceRemaining = graceRemaining
    }
}

/// Pure ownership state, shared by the real helper and fault-injection tests.
public struct PowerOwnership: Codable, Equatable, Sendable {
    public var ownsOverride = false
    public var externalOverride = false
    public var conflict = false
    public init() {}
    public mutating func acquire(currentDisabled: Bool) -> Bool {
        guard !ownsOverride, !conflict else { return false }
        externalOverride = currentDisabled
        ownsOverride = !currentDisabled
        return ownsOverride
    }
    public mutating func observe(currentDisabled: Bool) {
        if (ownsOverride || externalOverride) && !currentDisabled { ownsOverride = false; conflict = true }
        externalOverride = !ownsOverride && currentDisabled
    }
    public mutating func release() -> Bool {
        let restore = ownsOverride
        ownsOverride = false; conflict = false
        return restore
    }
}

public enum HelperConstants {
    public static let service = "com.irshatharis.AgentAwake.helper"
    public static let plist = service + ".plist"
    public static let leaseSeconds: TimeInterval = 12
}
@objc public protocol PowerHelperProtocol {
    func renew(awake: Bool, generation: String, withReply reply: @escaping (Bool, Bool, String) -> Void)
    func release(withReply reply: @escaping (Bool, String) -> Void)
}
