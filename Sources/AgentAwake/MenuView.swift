import SwiftUI
import AwakeCore

struct MenuView: View {
    @ObservedObject var model: AwakeModel
    @State private var custom = false
    @State private var minutes = "90"
    private var customMinutes: Double? {
        guard let value = Double(minutes), value.isFinite, value >= 1, value <= 10080 else { return nil }
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(model.accent.opacity(0.12)).frame(width: 48, height: 48)
                    Image(systemName: model.symbol).font(.system(size: 23, weight: .medium)).foregroundStyle(model.accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.title).font(.system(size: 18, weight: .semibold))
                    Text(model.decision.reason).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let seconds = model.decision.graceRemaining {
                    Text("\(seconds)s").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                }
            }.padding(20)
            if model.decision.preventSleep {
                Label(model.helperReady ? "Display can sleep · lid protected" : "Lid protection unavailable", systemImage: model.helperReady ? "laptopcomputer" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(model.helperReady ? Color.secondary : .orange)
                    .padding(.horizontal, 20).padding(.bottom, 16)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    sectionLabel("AUTOMATIC")
                    Spacer()
                    if model.paused {
                        Button("Resume") { model.resume() }.buttonStyle(.bordered).controlSize(.small)
                    } else {
                        Toggle("Automatic agent mode", isOn: $model.automatic).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
                Text(model.automaticDescription).font(.caption).foregroundStyle(.secondary)
                if model.sessions.isEmpty {
                    HStack(spacing: 9) {
                        Image(systemName: "terminal").foregroundStyle(.tertiary)
                        Text(model.installedProviders.isEmpty ? "Connect your agents in Settings" : "Ready for the next agent session")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(.vertical, 7)
                } else {
                    ScrollView {
                        VStack(spacing: 7) {
                            ForEach(model.sessions) { session in AgentRow(session: session) }
                        }
                    }.frame(maxHeight: 185)
                }
                if !model.untracked.isEmpty {
                    Text("\(model.untracked.count) agent process\(model.untracked.count == 1 ? "" : "es") awaiting hooks · activity unknown")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    sectionLabel("KEEP AWAKE")
                    Spacer()
                    if model.hasManual { Button("End session") { model.endManual() }.font(.caption).buttonStyle(.plain).foregroundStyle(.orange) }
                }
                HStack(spacing: 7) {
                    ForEach([15, 30, 60, 120], id: \.self) { duration in
                        Button(duration < 60 ? "\(duration)m" : "\(duration / 60)h") { model.startManual(minutes: Double(duration)) }
                            .buttonStyle(DurationButtonStyle())
                    }
                    Button { custom.toggle() } label: { Image(systemName: "ellipsis") }.buttonStyle(DurationButtonStyle())
                        .help("Custom duration")
                }
                if custom {
                    HStack {
                        TextField("Minutes", text: $minutes).textFieldStyle(.roundedBorder).frame(width: 75)
                            .onSubmit { if let value = customMinutes { model.startManual(minutes: value); custom = false } }
                        Text("minutes").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Start") { if let value = customMinutes { model.startManual(minutes: value); custom = false } }
                            .disabled(customMinutes == nil)
                    }
                    Text("1 minute to 7 days").font(.caption2).foregroundStyle(.tertiary)
                }
                Button { model.startManual(minutes: nil) } label: {
                    HStack {
                        Image(systemName: "infinity").font(.system(size: 16, weight: .medium))
                        Text("Stay awake indefinitely").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Image(systemName: "arrow.right").font(.caption)
                    }.padding(11).background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain)
                if let label = model.manualLabel {
                    Label(label, systemImage: "clock").font(.caption).foregroundStyle(.orange).monospacedDigit()
                } else {
                    Text("Keep your Mac reachable, even between agent tasks.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
            Divider()
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.orange).lineLimit(3).padding(.horizontal, 20).padding(.top, 12)
            }
            HStack {
                Button("Allow sleep now") { model.allowSleep() }.buttonStyle(.bordered)
                    .help("End manual sessions and pause automatic mode until you resume")
                Spacer()
                Button { model.showSettings() } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Settings & setup")
                Button { model.quit() } label: { Image(systemName: "power") }.buttonStyle(.plain).padding(.leading, 10).help("Quit Agent Awake")
            }.padding(16)
        }
        .frame(width: 370)
    }
    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).tracking(1.3).foregroundStyle(.secondary)
    }
}
struct AgentRow: View {
    let session: AgentSession
    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(session.isWorking ? Color.orange : session.activity == .waiting ? .blue : .gray.opacity(0.45)).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(session.provider.title).font(.system(size: 12, weight: .medium))
                    if session.agentID != nil { Text("subagent").font(.system(size: 9)).foregroundStyle(.secondary) }
                }
                Text(session.shortID + " · PID \(session.process.pid)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(session.backgroundIDs.isEmpty ? session.activity.title : "Background work")
                .font(.system(size: 11)).foregroundStyle(session.isWorking ? Color.orange : .secondary)
        }.padding(10).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
        .help("Last lifecycle event: \(session.lastEvent) at \(session.updatedAt.formatted())")
    }
}
struct DurationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).frame(height: 30)
            .background(.primary.opacity(configuration.isPressed ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 7))
    }
}
