import Foundation
import ServiceManagement
import AwakeCore

@MainActor final class HelperClient {
    private var connection: NSXPCConnection?
    private var inFlight = false
    private var sentAt: TimeInterval = 0
    private var requestID = UUID()
    private var hadConnection = false
    private var requestedAwake = false
    var onState: ((Bool, Bool, String, Bool, Bool) -> Void)?
    var status: SMAppService.Status { SMAppService.daemon(plistName: HelperConstants.plist).status }
    func register() throws { try SMAppService.daemon(plistName: HelperConstants.plist).register() }
    func unregister() async throws {
        try await SMAppService.daemon(plistName: HelperConstants.plist).unregister()
        connection?.invalidate(); connection = nil
    }
    private func connect() throws -> NSXPCConnection {
        if let connection { return connection }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/agent-awake-helper")
        let connection = NSXPCConnection(machServiceName: HelperConstants.service, options: .privileged)
        connection.setCodeSigningRequirement(try CodeIdentity.requirement(at: helper))
        connection.remoteObjectInterface = NSXPCInterface(with: PowerHelperProtocol.self)
        connection.invalidationHandler = { [weak self] in Task { @MainActor in self?.failed("Power helper disconnected") } }
        connection.interruptionHandler = connection.invalidationHandler
        connection.resume(); self.connection = connection
        return connection
    }
    func renew(awake: Bool, generation: String) {
        guard status == .enabled else {
            let lost = hadConnection && requestedAwake
            hadConnection = false; requestedAwake = false
            onState?(false, false, "Enable the helper for closed-lid protection", lost, false)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if inFlight {
            if now - sentAt > 6 { failed("Power helper stopped responding") }
            return
        }
        do {
            let connection = try connect()
            inFlight = true; sentAt = now; requestID = UUID(); requestedAwake = awake
            let request = requestID
            let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
                Task { @MainActor in self?.failed("Cannot reach the power helper. Check Login Items & Extensions.") }
            } as? PowerHelperProtocol
            proxy?.renew(awake: awake, generation: generation) { [weak self] ok, external, message in
                Task { @MainActor in
                    guard let self, self.requestID == request else { return }
                    self.inFlight = false
                    if ok { self.hadConnection = true }
                    self.onState?(ok, external, message, !ok && awake, awake)
                }
            }
        } catch { requestedAwake = awake; failed(error.localizedDescription) }
    }
    private func failed(_ text: String) {
        let lost = requestedAwake
        inFlight = false; requestID = UUID()
        let old = connection; connection = nil
        old?.invalidationHandler = nil; old?.interruptionHandler = nil; old?.invalidate()
        hadConnection = false; requestedAwake = false
        onState?(false, false, text, lost, false)
    }
    func release(completion: @escaping (Bool, String) -> Void) {
        requestID = UUID(); inFlight = false; requestedAwake = false
        if connection == nil && status != .enabled {
            completion(true, "No enabled helper connection.")
            return
        }
        do {
            let connection = try connect()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                DispatchQueue.main.async { completion(false, error.localizedDescription) }
            } as? PowerHelperProtocol
            guard let proxy else { completion(false, "Helper unavailable; leave it installed for lease recovery."); return }
            proxy.release { ok, text in DispatchQueue.main.async { completion(ok, text) } }
        } catch { completion(false, error.localizedDescription) }
    }
}
