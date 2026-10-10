import Foundation
import AwakeCore

final class FakePower: PowerBackend {
    var disabled: Bool? = false
    var hasJournal = false
    var closedLidWouldSleep = false
    var operations: [String] = []
    var failWrite = false
    var failDisplay = false
    func sleepDisplays() throws {
        operations.append("displaySleep")
        if failDisplay { throw AwakeError.helper("injected display failure") }
    }
    func setDisabled(_ value: Bool) throws {
        operations.append(value ? "disable" : "restore")
        if failWrite { throw AwakeError.helper("injected failure") }
        disabled = value
    }
    func recordJournal() throws { operations.append("journal"); hasJournal = true }
    func clearJournal() throws { operations.append("clear"); hasJournal = false }
    func sleepIfLidClosed() { operations.append("checkLid") }
}
final class LeaseTests {
    func testDisplaySleepFollowsLidAndActiveLease() throws {
        let backend = FakePower(); var clock = 0.0
        let lease = PowerLeaseController(backend: backend, now: { clock })
        _ = lease.renew(awake: true, generation: "a")
        expectFalse(backend.operations.contains("displaySleep"))
        backend.closedLidWouldSleep = true; lease.tick()
        expectEqual(backend.operations.filter { $0 == "displaySleep" }.count, 1)
        clock = 1; lease.tick(); _ = lease.renew(awake: true, generation: "a")
        expectEqual(backend.operations.filter { $0 == "displaySleep" }.count, 1)
        backend.closedLidWouldSleep = false; lease.tick()
        backend.closedLidWouldSleep = true; lease.tick()
        expectEqual(backend.operations.filter { $0 == "displaySleep" }.count, 2)
        try lease.release(); backend.operations = []; lease.tick()
        expectTrue(backend.operations.isEmpty)
        _ = lease.renew(awake: true, generation: "b")
        expectTrue(backend.operations.contains("displaySleep"))
        clock = 20; backend.operations = []; lease.tick()
        expectFalse(backend.operations.contains("displaySleep"))
        expectEqual(backend.disabled, false)
    }
    func testDisplaySleepFailureRetriesWithoutDroppingProtection() {
        let backend = FakePower(); var clock = 0.0
        backend.closedLidWouldSleep = true; backend.failDisplay = true
        let lease = PowerLeaseController(backend: backend, now: { clock })
        let result = lease.renew(awake: true, generation: "a")
        expectTrue(result.0); expectTrue(result.2.contains("Display sleep request failed"))
        expectEqual(backend.disabled, true)
        clock = 4; lease.tick()
        expectEqual(backend.operations.filter { $0 == "displaySleep" }.count, 1)
        backend.failDisplay = false; clock = 5; lease.tick()
        expectEqual(backend.operations.filter { $0 == "displaySleep" }.count, 2)
        expectFalse(lease.renew(awake: true, generation: "a").2.contains("failed"))
    }
    func testJournalBeforeMutationAndLeaseExpiry() {
        let backend = FakePower(); var clock = 0.0
        let lease = PowerLeaseController(backend: backend, now: { clock })
        expectTrue(lease.renew(awake: true, generation: "a").0)
        expectEqual(backend.operations, ["journal", "disable"])
        clock = 11; lease.tick(); expectEqual(backend.disabled, true)
        clock = 12; lease.tick(); expectEqual(backend.disabled, false)
        expectFalse(backend.hasJournal)
        expectEqual(backend.operations, ["journal", "disable", "restore", "clear", "checkLid"])
    }
    func testRenewalAndGenerationDoNotDropOwnership() {
        let backend = FakePower(); var clock = 0.0
        let lease = PowerLeaseController(backend: backend, now: { clock })
        _ = lease.renew(awake: true, generation: "a")
        clock = 10; _ = lease.renew(awake: true, generation: "b")
        expectEqual(backend.operations, ["journal", "disable"])
        clock = 13; lease.tick(); expectEqual(backend.disabled, true)
        expectTrue(lease.renew(awake: false, generation: "b").0)
        expectEqual(backend.disabled, false)
    }
    func testHelperCrashRecovery() {
        let backend = FakePower()
        var first: PowerLeaseController? = PowerLeaseController(backend: backend)
        _ = first?.renew(awake: true, generation: "a")
        first = nil // Simulates SIGKILL: no release or deinit cleanup.
        expectTrue(backend.hasJournal)
        _ = PowerLeaseController(backend: backend)
        expectEqual(backend.disabled, false); expectFalse(backend.hasJournal)
    }
    func testFailedRestoreRetriesWithoutDiscardingJournal() throws {
        let backend = FakePower()
        let lease = PowerLeaseController(backend: backend)
        _ = lease.renew(awake: true, generation: "a")
        backend.failWrite = true
        expectThrows(try lease.release())
        expectTrue(backend.hasJournal)
        expectFalse(lease.renew(awake: true, generation: "a").0)
        backend.failWrite = false; lease.tick()
        expectEqual(backend.disabled, false); expectFalse(backend.hasJournal)
    }
    func testCrashBetweenJournalAndPowerWriteRestoresSafely() {
        let backend = FakePower(); backend.hasJournal = true
        _ = PowerLeaseController(backend: backend)
        expectEqual(backend.disabled, false); expectFalse(backend.hasJournal)
    }
    func testExistingOverrideAndExternalChange() {
        let backend = FakePower(); backend.disabled = true
        let lease = PowerLeaseController(backend: backend)
        let result = lease.renew(awake: true, generation: "a")
        expectTrue(result.0); expectTrue(result.1); expectFalse(backend.hasJournal)
        backend.disabled = false
        expectFalse(lease.renew(awake: true, generation: "a").0)
        expectEqual(backend.disabled, false)
        expectTrue(lease.renew(awake: true, generation: "b").0)
        expectTrue(backend.hasJournal)
        _ = lease.renew(awake: false, generation: "b")
        expectEqual(backend.disabled, false)
    }
}
