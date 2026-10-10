import Foundation

public protocol PowerBackend: AnyObject {
    var disabled: Bool? { get }
    var hasJournal: Bool { get }
    var lidClosed: Bool { get }
    func setDisabled(_ value: Bool) throws
    func recordJournal() throws
    func clearJournal() throws
    func sleepIfLidClosed()
    func sleepDisplays() throws
}

/// Serialized by the helper's private queue. Dependency injection makes crash and lease
/// behavior testable without changing real machine power settings.
public final class PowerLeaseController {
    private let backend: PowerBackend
    private let now: () -> TimeInterval
    private var ownership = PowerOwnership()
    private var expiresAt: TimeInterval?
    private var generation = ""
    private var requested = false
    private var recoveryError: String?
    private var displaySleepRequested = false
    private var displayRetryAt: TimeInterval = 0
    private var displayError: String?

    public init(backend: PowerBackend, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.backend = backend; self.now = now
        if backend.hasJournal {
            do { _ = try release() } catch { recoveryError = error.localizedDescription }
        }
    }
    public func renew(awake: Bool, generation: String) -> (Bool, Bool, String) {
        do {
            if let error = recoveryError { throw AwakeError.helper(error) }
            guard let current = backend.disabled else { throw AwakeError.helper("Cannot read the current sleep setting.") }
            if !awake {
                _ = try release()
                return (true, backend.disabled == true, "Sleep allowed")
            }
            if self.generation != generation || !requested {
                if !ownership.ownsOverride { ownership = PowerOwnership() }
                self.generation = generation
            }
            requested = true
            ownership.observe(currentDisabled: current)
            if ownership.conflict {
                try backend.clearJournal()
                return (false, backend.disabled == true, "Sleep was enabled outside Agent Awake. Resume to take control again.")
            }
            if !ownership.ownsOverride && !current {
                try backend.recordJournal()
                do { try backend.setDisabled(true) }
                catch { recoveryError = error.localizedDescription; throw error }
                _ = ownership.acquire(currentDisabled: false)
            } else if !ownership.ownsOverride { _ = ownership.acquire(currentDisabled: true) }
            expiresAt = now() + HelperConstants.leaseSeconds
            updateDisplaySleep()
            let message = ownership.externalOverride ? "Sleep is also disabled by another tool" : "Closed-lid protection active"
            return (true, ownership.externalOverride, displayError.map { "\(message) · \($0)" } ?? message)
        } catch { return (false, false, error.localizedDescription) }
    }
    @discardableResult public func release() throws -> Bool {
        requested = false; expiresAt = nil
        resetDisplaySleep()
        do {
            if ownership.ownsOverride || backend.hasJournal {
                try backend.setDisabled(false)
                try backend.clearJournal()
                _ = ownership.release(); recoveryError = nil
                backend.sleepIfLidClosed()
            } else { _ = ownership.release(); recoveryError = nil }
            return true
        } catch { recoveryError = error.localizedDescription; throw error }
    }
    public func tick() {
        if recoveryError != nil || (!requested && backend.hasJournal) || (expiresAt.map { now() >= $0 } ?? false) {
            _ = try? release()
        }
        updateDisplaySleep()
    }
    private func resetDisplaySleep() {
        displaySleepRequested = false; displayRetryAt = 0; displayError = nil
    }
    private func updateDisplaySleep() {
        guard requested, let expiry = expiresAt, now() < expiry,
              backend.disabled == true, backend.lidClosed else {
            resetDisplaySleep()
            return
        }
        // One request per lid closure, including a session started with the lid already
        // closed. Do not fight external keyboard/mouse activity or blank an open laptop.
        guard !displaySleepRequested, now() >= displayRetryAt else { return }
        do {
            try backend.sleepDisplays()
            displaySleepRequested = true; displayError = nil
        } catch {
            displayError = "Display sleep request failed"
            displayRetryAt = now() + 5
        }
    }
}
