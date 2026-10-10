import AppKit
import SwiftUI
import ServiceManagement
import AwakeCore
import Darwin

@MainActor final class AwakeModel: ObservableObject {
    static let shared = AwakeModel()
    @Published var sessions: [AgentSession] = []
    @Published var untracked: [(Provider, ProcessIdentity)] = []
    @Published var decision = PowerDecision(preventSleep: false, reason: "No active agents", graceRemaining: nil)
    @Published var automatic: Bool { didSet { defaults.set(automatic, forKey: "automatic"); policy.automatic = automatic; tick() } }
    @Published var paused: Bool { didSet { defaults.set(paused, forKey: "paused"); policy.paused = paused } }
    @Published var cutoffEnabled: Bool { didSet { defaults.set(cutoffEnabled, forKey: "cutoffEnabled"); policy.cutoffEnabled = cutoffEnabled; tick() } }
    @Published var cutoffPercent: Int { didSet { defaults.set(cutoffPercent, forKey: "cutoffPercent"); policy.cutoffPercent = cutoffPercent; tick() } }
    @Published var graceSeconds: Double { didSet { defaults.set(graceSeconds, forKey: "graceSeconds"); policy.graceSeconds = graceSeconds } }
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var helperReady = false
    @Published var helperMessage = "Helper not enabled"
    @Published var helperStatus = SMAppService.Status.notRegistered
    @Published var externalOverride = false
    @Published var idleProtected = false
    @Published var batteryPercent: Int?
    @Published var onBattery = false
    @Published var lidClosed = false
    @Published var clamshellMode = false
    @Published var codexHooksInstalled = false
    @Published var notice: String?
    @Published var manualLabel: String?
    @Published var clockNow = Date()
    @Published var busy = false
    private let defaults = UserDefaults.standard
    private let local = LocalStore()
    private let assertion = IdleAssertion()
    private let helper = HelperClient()
    private var policy = AwakePolicy()
    private var timer: Timer?
    private var lastHelperRenewal: TimeInterval = -10
    private var lastScan: TimeInterval = -10
    private var generation = UUID().uuidString
    private var settingsWindow: NSWindow?
    private var quitting = false
    private var powerFault = false

    private init() {
        let d = UserDefaults.standard
        automatic = d.object(forKey: "automatic") as? Bool ?? true
        paused = d.bool(forKey: "paused")
        cutoffEnabled = d.bool(forKey: "cutoffEnabled")
        cutoffPercent = d.object(forKey: "cutoffPercent") as? Int ?? 20
        graceSeconds = d.object(forKey: "graceSeconds") as? Double ?? 8
        policy.automatic = automatic; policy.paused = paused
        policy.cutoffEnabled = cutoffEnabled; policy.cutoffPercent = cutoffPercent; policy.graceSeconds = graceSeconds
        // Manual leases are deliberately not resurrected after a crash or reboot.
        helper.onState = { [weak self] ok, external, message, lost, acknowledgedAwake in
            guard let self else { return }
            self.helperReady = ok && acknowledgedAwake && self.decision.preventSleep; self.helperMessage = message
            // Only a responding helper knows who owns the switch; otherwise keep the periodic scan's reading.
            if ok { self.externalOverride = external }
            if lost && self.decision.preventSleep {
                self.powerFault = true
                self.allowSleep()
                self.notice = "Protection stopped: \(message). Resume when the helper is available."
            }
        }
        removeLegacyClaudeHooks()
        refreshInstallation()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    var title: String {
        if idleProtected && decision.preventSleep { return helperReady ? "Sleep prevented" : "Idle sleep prevented" }
        if externalOverride { return "Sleep disabled externally" }
        return "Sleep allowed"
    }
    var symbol: String { idleProtected && decision.preventSleep ? "sun.max.fill" : "moon.zzz" }
    var accent: Color { idleProtected && decision.preventSleep ? .orange : .secondary }
    var automaticDescription: String { paused ? "Paused until you resume" : automatic ? "Following agent activity" : "Automatic mode is off" }
    var hasManual: Bool { policy.indefinite || policy.manualUntil != nil }

    func tick() {
        guard !quitting else { return }
        clockNow = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        var tracked = ClaudePresence.sessions()
        do { tracked += try local.snapshot().sessions.values.filter { $0.provider == .codex } }
        catch { notice = "Codex activity tracking unavailable: \(error.localizedDescription)" }
        sessions = tracked.sorted { a, b in
            if a.isWorking != b.isWorking { return a.isWorking }
            return a.updatedAt > b.updatedAt
        }
        if uptime - lastScan > 5 {
            let known = Set(sessions.map(\.process))
            untracked = ProcessIdentity.discoveredAgents().filter { !known.contains($0.1) }
            lastScan = uptime
            helperStatus = helper.status
            refreshInstallation()
            externalOverride = PowerSystem.sleepDisabled == true && !helperReady
        }
        let battery = PowerSystem.battery
        batteryPercent = battery.percent; onBattery = battery.onBattery; lidClosed = PowerSystem.lidClosed
        clamshellMode = lidClosed && !PowerSystem.closedLidWouldSleep
        let next = policy.evaluate(sessions: sessions, now: clockNow, uptime: uptime, battery: battery.percent, onBattery: battery.onBattery, thermal: ProcessInfo.processInfo.thermalState)
        let changed = next.preventSleep != decision.preventSleep
        if next.preventSleep && !decision.preventSleep { generation = UUID().uuidString }
        decision = next
        idleProtected = assertion.update(awake: next.preventSleep && !powerFault) && next.preventSleep && !powerFault
        if policy.indefinite { manualLabel = "Until you end it" }
        else if let until = policy.manualUntil {
            let seconds = max(0, Int(until.timeIntervalSince(clockNow)))
            manualLabel = seconds >= 3600
                ? String(format: "%d:%02d:%02d remaining", seconds / 3600, seconds / 60 % 60, seconds % 60)
                : String(format: "%d:%02d remaining", seconds / 60, seconds % 60)
        } else { manualLabel = nil }
        if changed || uptime - lastHelperRenewal >= 3 {
            helper.renew(awake: next.preventSleep && !powerFault, generation: generation)
            lastHelperRenewal = uptime
        }
    }
    func startManual(minutes: Double?) {
        powerFault = false; generation = UUID().uuidString
        policy.indefinite = minutes == nil
        policy.manualUntil = minutes.map { Date().addingTimeInterval(min(10080, max(1, $0)) * 60) }
        tick()
    }
    func endManual() { policy.indefinite = false; policy.manualUntil = nil; tick() }
    func allowSleep() {
        policy.allowSleep(); paused = true; assertion.release(); idleProtected = false
        generation = UUID().uuidString
        tick()
        helper.release { [weak self] ok, text in if !ok { self?.notice = text } }
    }
    func resume() { powerFault = false; notice = nil; paused = false; automatic = true; generation = UUID().uuidString; tick() }
    func installCodexHooks() {
        do {
            try HookInstaller().install(executable: hookExecutable)
            refreshInstallation()
            notice = "Codex hooks installed. Open /hooks in Codex and review/trust the Agent Awake commands. Restart existing CLI sessions."
        } catch { notice = error.localizedDescription }
    }
    private var hookExecutable: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/agent-awake-hook") }
    private func removeLegacyClaudeHooks() {
        do {
            if try HookInstaller().removeLegacyClaudeHooks(executable: hookExecutable) {
                notice = "Claude Code is now detected automatically. Agent Awake removed the Claude hooks it installed earlier; your other settings and hooks are unchanged."
            }
        } catch { notice = "Could not remove Agent Awake's earlier Claude hooks. It will retry at next launch. \(error.localizedDescription)" }
    }
    func refreshInstallation() {
        codexHooksInstalled = (try? HookInstaller().installed())?.contains { $0.provider == .codex } ?? false
    }
    func enableHelper() {
        do { try helper.register(); helperStatus = helper.status; SMAppService.openSystemSettingsLoginItems() }
        catch {
            helperStatus = helper.status
            if helperStatus == .requiresApproval || helperStatus == .enabled {
                notice = "macOS registered the helper. If it is awaiting approval, enable Agent Awake in Login Items & Extensions."
                SMAppService.openSystemSettingsLoginItems()
            } else { notice = "Helper registration: \(error.localizedDescription)" }
        }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { notice = "Launch at login: \(error.localizedDescription)"; loginEnabled = SMAppService.mainApp.status == .enabled }
    }
    func removeIntegrations() {
        allowSleep(); busy = true
        helper.release { [weak self] ok, text in
            guard let self else { return }
            guard ok || PowerSystem.sleepDisabled == false else { self.busy = false; self.notice = "Sleep restoration must succeed before removal: \(text)"; return }
            Task { @MainActor in
                // The root helper goes first: an unreadable hook config must not leave it registered.
                do {
                    if self.helper.status != .notRegistered { try await self.helper.unregister() }
                    if SMAppService.mainApp.status == .enabled { try await SMAppService.mainApp.unregister() }
                    self.loginEnabled = false; self.helperReady = false
                    try HookInstaller().uninstall()
                    self.notice = "Integrations removed. Existing hooks are preserved. You can now quit and delete Agent Awake."
                } catch { self.notice = "Removal incomplete: \(error.localizedDescription)" }
                self.refreshInstallation(); self.helperStatus = self.helper.status
                self.busy = false
            }
        }
    }
    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 670), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Agent Awake"
            window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: SettingsView(model: self))
            window.isReleasedWhenClosed = false; window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func quit() {
        quitting = true; timer?.invalidate(); assertion.release()
        helper.release { _, _ in NSApp.terminate(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
    }
}
