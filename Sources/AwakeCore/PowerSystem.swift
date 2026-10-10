import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import Security

public enum PowerSystem {
    public static var lidClosed: Bool { rootFlag("AppleClamshellState") }
    /// The kernel's own clamshell decision. False in clamshell mode (external display), where the
    /// closed Mac is still in use, and unaffected by `disablesleep`.
    public static var closedLidWouldSleep: Bool { lidClosed && rootFlag("AppleClamshellCausesSleep") }
    private static func rootFlag(_ key: String) -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false
    }
    public static var sleepDisabled: Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }
    public static var battery: (percent: Int?, onBattery: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
        for source in list {
            guard let data = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  data[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = data[kIOPSCurrentCapacityKey] as? Int
            let maximum = data[kIOPSMaxCapacityKey] as? Int ?? 100
            return (current.map { min(100, max(0, $0 * 100 / max(maximum, 1))) }, data[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue)
        }
        return (nil, false)
    }
    /// Calls `handler` on `queue` for every IOPMrootDomain interest message, which includes lid
    /// and clamshell-sleep changes. Registered for the life of the process.
    public static func observeRootDomain(on queue: DispatchQueue, _ handler: @escaping () -> Void) -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return false }
        IONotificationPortSetDispatchQueue(port, queue)
        let context = Unmanaged.passRetained(InterestHandler(handler))
        var notification: io_object_t = 0
        let result = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { context, _, _, _ in
            guard let context else { return }
            Unmanaged<InterestHandler>.fromOpaque(context).takeUnretainedValue().handler()
        }, context.toOpaque(), &notification)
        guard result == KERN_SUCCESS else {
            context.release(); IONotificationPortDestroy(port)
            return false
        }
        return true
    }
    public static func requestLidSleep() {
        guard closedLidWouldSleep else { return }
        let connection = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard connection != 0 else { return }
        _ = IOPMSleepSystem(connection)
        IOServiceClose(connection)
    }
}

private final class InterestHandler {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
}

public final class IdleAssertion {
    private var identifier: IOPMAssertionID = 0
    public init() {}
    @discardableResult public func update(awake: Bool) -> Bool {
        guard awake else { release(); return true }
        if identifier != 0 {
            let timeout = IOPMAssertionSetProperty(identifier, kIOPMAssertionTimeoutKey as CFString, NSNumber(value: HelperConstants.leaseSeconds))
            let level = IOPMAssertionSetProperty(identifier, kIOPMAssertionLevelKey as CFString, NSNumber(value: kIOPMAssertionLevelOn))
            if timeout == kIOReturnSuccess && level == kIOReturnSuccess { return true }
            release()
        }
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey: kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionNameKey: "Agent Awake · active session",
            kIOPMAssertionLevelKey: kIOPMAssertionLevelOn,
            kIOPMAssertionTimeoutKey: HelperConstants.leaseSeconds,
            kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionTurnOff
        ]
        return IOPMAssertionCreateWithProperties(properties as CFDictionary, &identifier) == kIOReturnSuccess
    }
    public func release() {
        if identifier != 0 { IOPMAssertionRelease(identifier); identifier = 0 }
    }
    deinit { release() }
}

public enum CodeIdentity {
    /// Derive the peer's designated requirement from our own sealed bundle.
    /// Ad-hoc builds pin the exact cdhash; Developer ID builds pin identifier + signing identity.
    public static func requirement(at url: URL) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw AwakeError.helper("The bundled code signature is invalid. Rebuild or reinstall Agent Awake.")
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else {
            throw AwakeError.helper("Cannot authenticate bundled executable.")
        }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { throw AwakeError.helper("Missing code requirement.") }
        return text as String
    }
}
