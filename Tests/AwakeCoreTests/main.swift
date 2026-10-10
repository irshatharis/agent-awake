import Foundation
import Darwin

// Dependency-free runner: works with Apple's Command Line Tools as well as Xcode.
var failures = 0
var checks = 0
func fail(_ message: String, file: StaticString, line: UInt) {
    failures += 1; fputs("FAIL \(file):\(line): \(message)\n", stderr)
}
func expectTrue(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) rethrows {
    checks += 1
    if try !value() { fail("expected true", file: file, line: line) }
}
func expectFalse(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) rethrows {
    checks += 1
    if try value() { fail("expected false", file: file, line: line) }
}
func expectEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ context: String = "", file: StaticString = #filePath, line: UInt = #line) rethrows {
    checks += 1
    let left = try a(), right = try b()
    if left != right { fail("\(left) != \(right) \(context)", file: file, line: line) }
}
func expectThrows<T>(_ value: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    checks += 1
    do { _ = try value(); fail("expected error", file: file, line: line) } catch {}
}
let activity = ActivityTests(), policy = PolicyTests(), config = ConfigurationTests()
let leases = LeaseTests()
let tests: [(String, () throws -> Void)] = [
    ("Display sleep follows lid and lease", leases.testDisplaySleepFollowsLidAndActiveLease),
    ("Display request failure retry", leases.testDisplaySleepFailureRetriesWithoutDroppingProtection),
    ("Journal before mutation; lease expiry", leases.testJournalBeforeMutationAndLeaseExpiry),
    ("Renewal preserves ownership", leases.testRenewalAndGenerationDoNotDropOwnership),
    ("Helper crash recovery", leases.testHelperCrashRecovery),
    ("Failed restore retry", leases.testFailedRestoreRetriesWithoutDiscardingJournal),
    ("Crash before power mutation", leases.testCrashBetweenJournalAndPowerWriteRestoresSafely),
    ("External override during lease", leases.testExistingOverrideAndExternalChange),
    ("Both CLI lifecycles", activity.testCompleteLifecycleForBothProviders),
    ("Independent sessions and subagents", activity.testSubagentOutlivesParentAndOtherSessionWaits),
    ("Parallel tool permissions", activity.testParallelPermissionDoesNotHideRunningTool),
    ("User question and resume", activity.testQuestionWaitsAndResumes),
    ("Interrupt and crash", activity.testInterruptAndCrash),
    ("Background completion", activity.testBackgroundWorkAndCompletion),
    ("Privacy allowlist", activity.testPrivacyAllowlist),
    ("Invalid event and PID reuse", activity.testUnknownEventsRejectedAndPIDReusePruned),
    ("Grace and restart", policy.testGraceNeverExtendsAndNewWorkCancelsIt),
    ("Indefinite, cutoff, charger", policy.testIndefiniteCutoffAndCharger),
    ("Allow sleep and resume", policy.testAllowSleepClearsManualAndPausesUntilResume),
    ("Timer expiry", policy.testTimerExpiry),
    ("Existing nosleep", policy.testExternalNosleepIsBorrowed),
    ("External rsleep", policy.testExternalRsleepIsNotFought),
    ("Owned power restoration", policy.testOwnedOverrideRestores),
    ("Preserve hooks; idempotent install/removal", config.testInstallTwiceAndRemovePreservesForeignHandlersAndSettings),
    ("Preserve dotfile symlink on install and removal", config.testDotfileSymlinkInstallAndRemoval),
    ("Reject malformed configuration", config.testMalformedConfigIsNotOverwritten),
    ("Private storage and symlinks", config.testPrivateAtomicStoreAndSymlinkRejection)
]
for (name, test) in tests {
    let before = failures
    do { try test() } catch { fail("\(name): \(error)", file: #filePath, line: #line) }
    print("\(before == failures ? "PASS" : "FAIL") \(name)")
}
print("\(tests.count) scenarios, \(checks) assertions, \(failures) failures")
exit(failures == 0 ? 0 : 1)
