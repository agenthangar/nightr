import AppKit
import SwiftUI
import NightrCore

// Run the decision engine against a sample. Its effects never leave this process.
private struct PreviewPane: View {
    let session: NSMutableDictionary
    @State private var engine: MonitorEngine
    @State private var generationStarted: Date

    init(session: NSMutableDictionary) {
        self.session = session
        let now = Date()
        let started = now.addingTimeInterval(-42)
        _generationStarted = State(initialValue: started)
        let sample = MachineSample(onBattery: true, batteryPercent: 57, agentActive: true,
                                   agentObservation: .active, activity: Self.activity(at: now, started: started))
        let settings = (session["savedDraft"] as? Data).flatMap { try? JSONDecoder().decode(NightrCore.Settings.self, from: $0) }
        var engine = MonitorEngine(settings: settings ?? .init(), sample: sample)
        if session["baseEnabled"] as? Bool ?? true { _ = engine.handle(.start, now: now) }
        if session["force"] as? Bool ?? true { _ = engine.handle(.beginForce, now: now) }
        Self.finishCheck(&engine)
        _engine = State(initialValue: engine)
    }

    private static func activity(at now: Date, started: Date) -> ActivityObservation {
        let generating = LocalModelObservation(id: "qwen2.5-coder:14b", residency: .loaded, activity: .generating,
                                              contextTokens: 32_768, memoryBytes: 9_600_000_000, startedAt: started,
                                              tokensPerSecond: 24.8, inferenceExpiresAt: now.addingTimeInterval(RuntimeObservation.freshness))
        let idle = LocalModelObservation(id: "deepseek-r1-distill-7b", residency: .loaded, activity: .idle,
                                        contextTokens: 8_192, memoryBytes: 4_700_000_000)
        return ActivityObservation(cpuPercent: 26, gpuPercent: 12, runtimes: [
            .init(runtime: .ollama, version: "0.6.2", observedAt: now, models: [generating]),
            .init(runtime: .lmStudio, version: "0.3.12", observedAt: now, models: [idle])
        ])
    }

    private static func finishCheck(_ engine: inout MonitorEngine) {
        if let token = engine.verificationToken { _ = engine.handle(.internetResult(token, true), now: Date()) }
    }

    private func command(_ command: ControllerCommand) {
        switch command {
        case .beginForce: _ = engine.handle(.beginForce, now: Date())
        case .endForce: _ = engine.handle(.endForce, now: Date())
        case .start: _ = engine.handle(.start, now: Date()); session["baseEnabled"] = true
        case .stop: _ = engine.handle(.stop, now: Date()); session["baseEnabled"] = false
        default: return
        }
        Self.finishCheck(&engine)
        publishState()
    }

    private func publishState() {
        session["force"] = engine.forceMode
        let summary = GUIProtectionSummary(status: .init(engine: engine))
        NotificationCenter.default.post(name: .previewStateChanged, object: nil,
            userInfo: ["image": MoonSparkArtwork.menuImage(for: summary), "label": summary.label])
    }

    var body: some View {
        NightrPopover(status: ControllerStatus(engine: engine), error: nil, helperStatus: .enabled,
                      command: command, settings: { NotificationCenter.default.post(name: .previewOpenSettings, object: nil) },
                      quit: { NSApp.terminate(nil) })
            .onAppear {
                if let enabled = session["force"] as? Bool, engine.forceMode != enabled { command(enabled ? .beginForce : .endForce) }
                else { publishState() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .previewForceChanged, object: session)) { _ in
                if let enabled = session["force"] as? Bool { command(enabled ? .beginForce : .endForce) }
            }
            .task {
                while !Task.isCancelled {
                    engine.replaceActivityObservation(Self.activity(at: Date(), started: generationStarted))
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .previewSettingsSaved)) { _ in
                guard let data = session["savedDraft"] as? Data,
                      let settings = try? JSONDecoder().decode(NightrCore.Settings.self, from: data) else { return }
                _ = engine.handle(.settings(settings), now: Date())
                _ = engine.handle(.tick(engine.sample), now: Date())
                Self.finishCheck(&engine)
                publishState()
            }
    }
}

@MainActor @_cdecl("makeNightrPanePreview")
public func makeNightrPanePreview(_ state: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    let session = Unmanaged<NSMutableDictionary>.fromOpaque(state).takeUnretainedValue()
    let view = NSHostingView(rootView: PreviewPane(session: session).fixedSize())
    return Unmanaged.passRetained(view as NSView).toOpaque()
}
