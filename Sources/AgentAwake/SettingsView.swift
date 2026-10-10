import SwiftUI
import ServiceManagement
import AwakeCore

struct SettingsView: View {
    @ObservedObject var model: AwakeModel
    @State private var selection = 0
    @State private var confirmRemoval = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "sun.max.fill").font(.system(size: 30)).foregroundStyle(.orange)
                    .frame(width: 62, height: 62).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 17))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Agent Awake").font(.system(size: 25, weight: .semibold))
                    Text("Let your agents work. Let your Mac rest.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") · Preview").font(.caption).foregroundStyle(.tertiary)
            }.padding(26)
            Picker("Settings", selection: $selection) {
                Text("Setup").tag(0)
                Text("Preferences").tag(1)
                Text("Diagnostics").tag(2)
            }.labelsHidden().pickerStyle(.segmented).padding(.horizontal, 26).padding(.bottom, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selection {
                    case 0: setup
                    case 1: preferences
                    default: diagnostics
                    }
                    if let notice = model.notice {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "info.circle")
                            Text(notice).textSelection(.enabled)
                            Spacer(minLength: 0)
                            Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        }.font(.caption).padding(13).background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(.horizontal, 26).padding(.bottom, 24)
            }
            Divider()
            HStack {
                Label("Local only · no prompt or tool content saved", systemImage: "lock.shield")
                Spacer()
                Link("Source", destination: URL(string: "https://github.com/irshatharis/agent-awake")!)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 26).padding(.vertical, 15)
        }.frame(width: 620, height: 670)
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            card {
                stepHeader("1", "Connect your agents", detail: "Add small lifecycle hooks without replacing your existing hooks.")
                ForEach(Provider.allCases, id: \.self) { provider in
                    HStack {
                        Image(systemName: "terminal").foregroundStyle(.secondary)
                        Text(provider.title).font(.system(size: 13, weight: .medium))
                        Spacer()
                        if model.installedProviders.contains(provider) {
                            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                        }
                        Button(model.installedProviders.contains(provider) ? "Repair hooks" : "Install hooks") { model.installHooks(provider) }
                    }.padding(.top, 7)
                }
                Text("Restart existing CLI sessions. In Codex, open /hooks and review/trust the Agent Awake commands. Installed does not mean trusted.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            card {
                stepHeader("2", "Enable closed-lid protection", detail: "Works on battery and charger. During protection, closing the lid requests display sleep, including connected displays.")
                HStack {
                    Label(helperLabel, systemImage: model.helperStatus == .enabled ? "checkmark.circle.fill" : "lock.circle")
                        .font(.caption).foregroundStyle(model.helperStatus == .enabled ? Color.green : .secondary)
                    Spacer()
                    Button(model.helperStatus == .requiresApproval ? "Open System Settings" : model.helperStatus == .enabled ? "System Settings" : "Enable helper") {
                        if model.helperStatus == .requiresApproval || model.helperStatus == .enabled { SMAppService.openSystemSettingsLoginItems() }
                        else { model.enableHelper() }
                    }
                }.padding(.top, 8)
                Text("macOS may ask for administrator approval under Login Items & Extensions. Keep the app in /Applications before enabling the helper.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            card {
                stepHeader("3", "Verify on your Mac", detail: "Start a two-minute session, close the lid, and check your terminal from your phone. Repeat on battery, then let the session expire.")
                Button("Start two-minute check") { model.startManual(minutes: 2) }.padding(.top, 7)
                Text("Check that the display turns off while the terminal stays reachable. After the timer ends, closing the lid should put the Mac to sleep.").font(.caption).foregroundStyle(.secondary)
            }
            Label {
                Text("Detection limits: Claude has no interruption hook. Both CLIs can leave a gap after you approve a tool. Use an indefinite session when continuous remote access matters.")
            } icon: { Image(systemName: "info.circle") }
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var preferences: some View {
        VStack(alignment: .leading, spacing: 16) {
            card {
                Text("Agent activity").font(.headline)
                Toggle("Automatic agent mode", isOn: $model.automatic)
                HStack {
                    Text("Grace period after work finishes")
                    Spacer()
                    Picker("Grace period", selection: $model.graceSeconds) {
                        Text("5 seconds").tag(5.0); Text("8 seconds").tag(8.0)
                        Text("15 seconds").tag(15.0); Text("30 seconds").tag(30.0)
                    }.labelsHidden().frame(width: 130)
                }
                Text("When work finishes, release sleep prevention after this delay. A new task cancels the countdown.").font(.caption).foregroundStyle(.secondary)
            }
            card {
                Text("Battery").font(.headline)
                Toggle("Allow sleep at a battery cutoff", isOn: $model.cutoffEnabled)
                HStack {
                    Text("Cutoff threshold")
                    Spacer()
                    Stepper("\(model.cutoffPercent)%", value: $model.cutoffPercent, in: 5...90, step: 5).frame(width: 115)
                }.disabled(!model.cutoffEnabled)
                Text("Off by default. When enabled, the cutoff overrides automatic and manual sessions while on battery. Protection resumes above the threshold or on charger.").font(.caption).foregroundStyle(.secondary)
            }
            card {
                Text("Startup").font(.headline)
                Toggle("Launch Agent Awake at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                Text("Manual sessions end when the app quits. “Allow sleep now” stays paused across relaunches until you resume.").font(.caption).foregroundStyle(.secondary)
            }
        }.font(.system(size: 13))
    }
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 16) {
            card {
                Text("Right now").font(.headline)
                diagnostic("Sleep", model.title)
                diagnostic("Reason", model.decision.reason)
                diagnostic("Power", "\(model.onBattery ? "Battery" : "Charger")\(model.batteryPercent.map { " · \($0)%" } ?? "")")
                diagnostic("Lid", model.clamshellMode ? "Closed · clamshell mode, displays stay on" : model.lidClosed ? "Closed" : "Open")
                diagnostic("Helper", model.helperMessage)
                diagnostic("Hooks", "\(model.sessions.count) sessions · \(model.untracked.count) untracked processes")
                if model.externalOverride {
                    Text("Another tool has disabled system sleep. Agent Awake will preserve that setting. To clear it, run sudo pmset -a disablesleep 0.").font(.caption).foregroundStyle(.orange)
                }
            }
            card {
                Text("Privacy & compatibility").font(.headline)
                Text("Stored locally: provider, opaque session and task IDs, process identity, lifecycle state, and timestamps. Prompt text, tool input/output, transcript paths, and working directories are discarded.")
                Text("Hooks cannot observe every transition. Claude interruptions, post-approval execution, detached commands, and hooks that extend a Stop can leave uncertain state. The source includes the exact support matrix and test results.")
                Text("Other keep-awake tools share the same global sleep switch (pmset disablesleep). A setting they made first is preserved, and Agent Awake stops if one of them turns sleep back on. If another tool sets it again while Agent Awake owns it, the change cannot be detected.")
                Link("Read detection limits & test checklist", destination: URL(string: "https://github.com/irshatharis/agent-awake/blob/main/docs/VERIFICATION.md")!)
            }.font(.caption).foregroundStyle(.secondary)
            card {
                Text("Clean removal").font(.headline)
                Text("Restore sleep, remove only Agent Awake’s hooks, unregister the helper, and disable launch at login. Existing hooks and private configuration backups remain.").font(.caption).foregroundStyle(.secondary)
                Button("Remove integrations…", role: .destructive) { confirmRemoval = true }.disabled(model.busy)
                    .confirmationDialog("Remove Agent Awake integrations?", isPresented: $confirmRemoval) {
                        Button("Remove integrations", role: .destructive) { model.removeIntegrations() }
                    } message: { Text("Your existing agent hooks are preserved. You can set up Agent Awake again later.") }
            }
        }
    }
    private var helperLabel: String {
        switch model.helperStatus {
        case .enabled: "Registered with macOS"
        case .requiresApproval: "Waiting for your approval"
        case .notFound: "Not registered with macOS"
        default: "Not enabled"
        }
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content).frame(maxWidth: .infinity, alignment: .leading)
            .padding(17).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
    private func stepHeader(_ number: String, _ title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Text(number).font(.system(size: 11, weight: .semibold)).frame(width: 23, height: 23)
                .background(.orange.opacity(0.13), in: Circle()).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func diagnostic(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key).foregroundStyle(.secondary).frame(width: 65, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }.font(.caption)
    }
}
