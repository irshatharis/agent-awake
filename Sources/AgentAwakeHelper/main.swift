import Foundation
import AwakeCore
import Darwin
import MachO
import os

// Only fixed power-management operations are exposed. No client-supplied paths or commands.
final class SystemPowerBackend: PowerBackend {
    private let directory = URL(fileURLWithPath: "/var/db/com.irshatharis.AgentAwake", isDirectory: true)
    private var journal: URL { directory.appendingPathComponent("restore-sleep") }
    var disabled: Bool? { PowerSystem.sleepDisabled }
    var hasJournal: Bool { FileManager.default.fileExists(atPath: journal.path) }
    var closedLidWouldSleep: Bool { PowerSystem.closedLidWouldSleep }
    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var st = stat()
        guard lstat(directory.path, &st) == 0, st.st_uid == 0, st.st_mode & S_IFMT == S_IFDIR,
              st.st_mode & 0o077 == 0 else { throw AwakeError.unsafePath }
    }
    func setDisabled(_ value: Bool) throws {
        try runPMSet(["-a", "disablesleep", value ? "1" : "0"])
        guard PowerSystem.sleepDisabled == value else { throw AwakeError.helper("macOS rejected the power setting.") }
    }
    func sleepDisplays() throws {
        // Recheck immediately before launching: the user may have reopened the lid or connected a display.
        guard PowerSystem.closedLidWouldSleep else { return }
        try runPMSet(["displaysleepnow"])
        Logger(subsystem: HelperConstants.service, category: "display").notice("Requested display sleep for closed lid")
    }
    private func runPMSet(_ arguments: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = arguments
        let errors = Pipe()
        task.standardOutput = FileHandle.nullDevice; task.standardError = errors
        try task.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while task.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        if task.isRunning { kill(task.processIdentifier, SIGKILL); throw AwakeError.helper("Power management timed out; recovery will retry.") }
        // pmset can report display errors on stderr while returning success.
        guard task.terminationStatus == 0,
              errors.fileHandleForReading.readDataToEndOfFile().isEmpty else {
            throw AwakeError.helper("macOS rejected the power request.")
        }
    }
    func recordJournal() throws {
        let fd = open(journal.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AwakeError.unsafePath }
        defer { close(fd) }
        let data = Array("restore SleepDisabled=0\n".utf8)
        guard Darwin.write(fd, data, data.count) == data.count, fsync(fd) == 0 else { throw AwakeError.helper("Could not save power recovery journal.") }
        syncDirectory()
    }
    func clearJournal() throws {
        if unlink(journal.path) != 0 && errno != ENOENT { throw AwakeError.helper("Could not clear recovery journal.") }
        syncDirectory()
    }
    private func syncDirectory() {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd >= 0 { fsync(fd); close(fd) }
    }
    func sleepIfLidClosed() { PowerSystem.requestLidSleep() }
}

final class ConnectionHandler: NSObject, PowerHelperProtocol {
    let controller: PowerLeaseController
    let queue: DispatchQueue
    init(_ controller: PowerLeaseController, queue: DispatchQueue) { self.controller = controller; self.queue = queue }
    func renew(awake: Bool, generation: String, withReply reply: @escaping (Bool, Bool, String) -> Void) {
        guard generation.utf8.count <= 64 else { reply(false, false, "Invalid lease"); return }
        queue.async { let result = self.controller.renew(awake: awake, generation: generation); reply(result.0, result.1, result.2) }
    }
    func release(withReply reply: @escaping (Bool, String) -> Void) {
        queue.async {
            do { reply(try self.controller.release(), "Sleep restored") }
            catch { reply(false, error.localizedDescription) }
        }
    }
}
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let controller: PowerLeaseController
    let queue: DispatchQueue
    private var active: NSXPCConnection?
    init(_ controller: PowerLeaseController, queue: DispatchQueue) { self.controller = controller; self.queue = queue }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // One app controls the machine-wide power setting. Signed peers are checked by NSXPC itself.
        guard connection.effectiveUserIdentifier != 0 else { return false }
        let handler = ConnectionHandler(controller, queue: queue)
        connection.exportedInterface = NSXPCInterface(with: PowerHelperProtocol.self)
        connection.exportedObject = handler
        queue.sync {
            active?.invalidate()
            active = connection
        }
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self else { return }
            self.queue.async {
                guard self.active === connection else { return }
                _ = try? self.controller.release()
                self.active = nil
            }
        }
        connection.interruptionHandler = connection.invalidationHandler
        connection.resume()
        return true
    }
}

umask(0o077)
let log = Logger(subsystem: HelperConstants.service, category: "lifecycle")
var executableSize: UInt32 = 4096
var executableBuffer = [CChar](repeating: 0, count: Int(executableSize))
guard _NSGetExecutablePath(&executableBuffer, &executableSize) == 0 else {
    log.error("Cannot locate helper executable")
    exit(1)
}
let executable = URL(fileURLWithPath: String(cString: executableBuffer)).resolvingSymlinksInPath()
let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
if CommandLine.arguments.contains("--check-bundle") {
    do { _ = try CodeIdentity.requirement(at: app); print("Bundled app signature verified"); exit(0) }
    catch { fputs("Bundle signature verification failed.\n", stderr); exit(1) }
}
guard geteuid() == 0 else { fputs("Agent Awake helper must be started by launchd.\n", stderr); exit(1) }
let backend: SystemPowerBackend
do { backend = try SystemPowerBackend() }
catch { log.error("Unsafe recovery directory"); exit(1) }
let controller = PowerLeaseController(backend: backend)
let queue = DispatchQueue(label: "com.irshatharis.AgentAwake.power")
let requirement: String
do { requirement = try CodeIdentity.requirement(at: app) }
catch { log.error("Bundle authentication failed: \(error.localizedDescription, privacy: .public)"); exit(1) }
let listener = NSXPCListener(machServiceName: HelperConstants.service)
listener.setConnectionCodeSigningRequirement(requirement)
let delegate = ListenerDelegate(controller, queue: queue)
listener.delegate = delegate
var launchedExecutable = stat()
let watchesExecutable = stat(executable.path, &launchedExecutable) == 0
func executableReplaced() -> Bool {
    var current = stat()
    guard watchesExecutable else { return false }
    return stat(executable.path, &current) != 0 || current.st_ino != launchedExecutable.st_ino
        || current.st_dev != launchedExecutable.st_dev || current.st_mtimespec.tv_sec != launchedExecutable.st_mtimespec.tv_sec
        || current.st_mtimespec.tv_nsec != launchedExecutable.st_mtimespec.tv_nsec
}
let timer = DispatchSource.makeTimerSource(queue: queue)
timer.schedule(deadline: .now(), repeating: 1)
timer.setEventHandler {
    controller.tick()
    // An updated app has a new signature this process would reject. Exit once sleep is
    // restored so launchd starts the new helper with the new requirement.
    if executableReplaced(), (try? controller.release()) == true {
        log.notice("Helper executable replaced; restarting")
        exit(0)
    }
}
timer.resume()
for sig in [SIGTERM, SIGINT] { signal(sig, SIG_IGN) }
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
termination.setEventHandler { _ = try? controller.release(); exit(0) }
termination.resume()
listener.resume()
log.notice("Power helper listening")
dispatchMain()
