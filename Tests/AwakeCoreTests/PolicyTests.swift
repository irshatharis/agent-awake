import Foundation
import AwakeCore
final class PolicyTests {
    let now = Date(timeIntervalSince1970: 1000)
    func working() -> AgentSession {
        var store = SessionStore()
        let event = try! HookEvent(data: Data(#"{"session_id":"x","hook_event_name":"UserPromptSubmit"}"#.utf8), process: .init(pid: 1, started: 1))
        store.apply(event)
        return store.sessions.values.first!
    }
    func testGraceNeverExtendsAndNewWorkCancelsIt() {
        var p = AwakePolicy()
        expectTrue(p.evaluate(sessions: [working()], now: now, uptime: 0, battery: 10, onBattery: true).preventSleep)
        expectEqual(p.evaluate(sessions: [], now: now, uptime: 2, battery: nil, onBattery: true).graceRemaining, 8)
        expectEqual(p.evaluate(sessions: [], now: now, uptime: 5, battery: nil, onBattery: true).graceRemaining, 5)
        expectFalse(p.evaluate(sessions: [], now: now, uptime: 10, battery: nil, onBattery: true).preventSleep)
        expectTrue(p.evaluate(sessions: [working()], now: now, uptime: 11, battery: nil, onBattery: true).preventSleep)
    }
    func testIndefiniteCutoffAndCharger() {
        var p = AwakePolicy(); p.indefinite = true
        expectTrue(p.evaluate(sessions: [], now: now, uptime: 1, battery: 5, onBattery: true).preventSleep)
        p.cutoffEnabled = true
        expectFalse(p.evaluate(sessions: [], now: now, uptime: 2, battery: 20, onBattery: true).preventSleep)
        expectTrue(p.evaluate(sessions: [], now: now, uptime: 3, battery: 20, onBattery: false).preventSleep)
    }
    func testAllowSleepClearsManualAndPausesUntilResume() {
        var p = AwakePolicy(); p.indefinite = true; p.allowSleep()
        expectFalse(p.evaluate(sessions: [working()], now: now, uptime: 1, battery: nil, onBattery: false).preventSleep)
        p.paused = false
        expectTrue(p.evaluate(sessions: [working()], now: now, uptime: 2, battery: nil, onBattery: false).preventSleep)
    }
    func testTimerExpiry() {
        var p = AwakePolicy(); p.manualUntil = now.addingTimeInterval(60)
        expectTrue(p.evaluate(sessions: [], now: now, uptime: 0, battery: nil, onBattery: false).preventSleep)
        expectFalse(p.evaluate(sessions: [], now: now.addingTimeInterval(60), uptime: 60, battery: nil, onBattery: false).preventSleep)
    }
    func testExternalNosleepIsBorrowed() {
        var ownership = PowerOwnership()
        expectFalse(ownership.acquire(currentDisabled: true))
        expectTrue(ownership.externalOverride)
        expectFalse(ownership.release())
    }
    func testExternalRsleepIsNotFought() {
        var ownership = PowerOwnership()
        expectTrue(ownership.acquire(currentDisabled: false))
        ownership.observe(currentDisabled: false)
        expectTrue(ownership.conflict)
        expectFalse(ownership.acquire(currentDisabled: false))
        expectFalse(ownership.release())
    }
    func testOwnedOverrideRestores() {
        var ownership = PowerOwnership()
        expectTrue(ownership.acquire(currentDisabled: false))
        ownership.observe(currentDisabled: true)
        expectTrue(ownership.release())
        expectFalse(ownership.release())
    }
}
