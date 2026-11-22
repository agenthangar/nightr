#if os(macOS)
import Foundation
import SwiftUI
import NightrCore

/// Pure presentation data: no runtime discovery, system calls or power ownership.
struct ActivityModelRow: Identifiable, Equatable {
    let id: String
    let name: String
    let runtime: String
    let version: String?
    let state: String
    let inference: Bool
    let fresh: Bool
    let memoryLabel: String
    let memoryBytes: Int64?
    let contextTokens: Int?
    let elapsedSeconds: Int?
    let tokensPerSecond: Double?

    var secondaryActivity: String? {
        if let tokensPerSecond, tokensPerSecond.isFinite, tokensPerSecond >= 0 {
            return tokensPerSecond.formatted(.number.precision(.fractionLength(0...1))) + " tok/s"
        }
        return elapsedSeconds.map { "\($0)s elapsed" }
    }
    var priority: Int { inference ? 0 : fresh && state.hasPrefix("Loaded,") ? 1 : fresh ? 2 : 3 }
    var unverified: Self { Self(id: id, name: name, runtime: runtime, version: version, state: "Activity and loaded state unknown", inference: false, fresh: false, memoryLabel: memoryLabel, memoryBytes: nil, contextTokens: nil, elapsedSeconds: nil, tokensPerSecond: nil) }
    static func rows(_ observation: ActivityObservation?, now: Date) -> [Self] {
        var result: [Self] = [], seen: Set<String> = []
        for runtime in observation?.runtimes ?? [] {
            let fresh = runtime.isFresh(at: now)
            if runtime.models.isEmpty {
                let id = runtime.runtime.rawValue + ":empty"
                if seen.insert(id).inserted {
                    result.append(Self(id: id, name: runtime.runtime.displayName, runtime: runtime.runtime.displayName,
                                       version: runtime.version, state: fresh ? "No models reported" : "Activity unknown", inference: false,
                                       fresh: fresh, memoryLabel: "Memory", memoryBytes: nil, contextTokens: nil, elapsedSeconds: nil, tokensPerSecond: nil))
                }
            }
            for model in runtime.models {
                let id = runtime.runtime.rawValue + ":" + model.id
                guard seen.insert(id).inserted else { continue }
                let bounded = model.inferenceExpiresAt.map { $0.timeIntervalSince(runtime.observedAt) <= RuntimeObservation.freshness } ?? false
                let activity = fresh && bounded ? model.observedActivity(at: now) : (fresh && !model.activity.isInference ? model.activity : .unknown)
                let inference = activity.isInference
                let state: String
                if !fresh { state = "Activity unknown" }
                else if inference { state = activity == .processing ? "Processing" : "Generating" }
                else if model.residency == .available { state = "Inventory only" }
                else if model.residency == .unknown { state = "Loaded state unknown" }
                else { state = activity == .idle ? "Loaded, idle" : "Loaded, activity unknown" }
                let elapsed = inference ? model.startedAt.flatMap { start in now >= start ? Int(now.timeIntervalSince(start)) : nil } : nil
                result.append(Self(id: id, name: model.displayName, runtime: runtime.runtime.displayName, version: runtime.version,
                                   state: state, inference: inference, fresh: fresh,
                                   memoryLabel: runtime.runtime == .ollama ? "GPU memory" : "Memory", memoryBytes: fresh ? model.memoryBytes : nil, contextTokens: fresh ? model.contextTokens : nil,
                                   elapsedSeconds: elapsed, tokensPerSecond: inference ? model.tokensPerSecond : nil))
            }
        }
        return result.enumerated().sorted {
            if $0.element.priority != $1.element.priority { return $0.element.priority < $1.element.priority }
            return $0.offset < $1.offset
        }.map(\.element)
    }
}

struct LocalModelsView: View {
    let observation: ActivityObservation?
    @State private var expanded = false
    @State private var selected: ActivityModelRow?
    private var rows: [ActivityModelRow] { ActivityModelRow.rows(observation, now: Date()) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Local models").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if rows.count > 2 {
                    Button(expanded ? "Show less" : "All \(rows.count)…") { expanded.toggle() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                        .accessibilityLabel(expanded ? "Show fewer local models" : "Show all \(rows.count) local models")
                }
            }
            if rows.isEmpty {
                Text("No runtime observations").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 5)
            } else {
                let visible = expanded ? rows : Array(rows.prefix(2))
                if expanded {
                    ScrollView { modelRows(visible) }.frame(maxHeight: 260)
                } else { modelRows(visible) }
            }
        }.padding(.top, 16)
        .sheet(item: $selected) { row in
            // Re-evaluate against the latest observation while status updates arrive.
            LocalModelDetails(row: rows.first(where: { $0.id == row.id }) ?? row.unverified)
        }
    }
    private func modelRows(_ rows: [ActivityModelRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                Button { selected = row } label: {
                    HStack(alignment: .center, spacing: 7) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                            Text(row.runtime).font(.system(size: 11)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(row.state).foregroundStyle(row.inference ? Color.nightrStatusGreen : Color.secondary)
                            if let detail = row.secondaryActivity {
                                Text(detail).foregroundStyle(.secondary)
                            }
                        }.font(.system(size: 10)).multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 90, alignment: .trailing)
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
                    }.padding(.vertical, 7).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(
                    [row.name, row.runtime, row.state, row.secondaryActivity, "details"].compactMap { $0 }.joined(separator: ", ")
                )
            }
        }
    }
}

struct LocalModelDetails: View {
    let row: ActivityModelRow
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(row.name).font(.system(size: 16, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text([row.runtime, row.version].compactMap { $0 }.joined(separator: " ")).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(row.state).font(.system(size: 12)).foregroundStyle(row.inference ? Color.nightrStatusGreen : Color.secondary)
            if let bytes = row.memoryBytes, bytes >= 0 { detail(row.memoryLabel, ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)) }
            if let context = row.contextTokens, context > 0 { detail("Context window", "\(context.formatted()) tokens") }
            if let elapsed = row.elapsedSeconds { detail(row.state == "Processing" ? "Time processing" : "Time generating", "\(elapsed) seconds") }
            if let rate = row.tokensPerSecond, rate.isFinite, rate >= 0 { detail("Tokens per second", rate.formatted(.number.precision(.fractionLength(0...1)))) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 360, alignment: .leading)
    }
    private func detail(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 12))
    }
}

struct HardwareMeters: View {
    let observation: ActivityObservation?
    var body: some View {
        HStack(spacing: 14) {
            meter("CPU", observation?.cpuPercent, tint: .teal)
            meter("GPU", observation?.gpuPercent, tint: .nightrAmber)
        }.accessibilityElement(children: .combine)
    }
    private func meter(_ label: String, _ percent: Int?, tint: Color) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(percent.map { "\(max(0, min(100, $0)))%" } ?? "Unavailable")
                    .monospacedDigit().foregroundStyle(percent == nil ? Color.secondary : tint)
            }
            GeometryReader { geometry in
                Capsule().fill(Color.secondary.opacity(0.15))
                    .overlay(alignment: .leading) {
                        if let percent { Capsule().fill(tint.opacity(0.75)).frame(width: geometry.size.width * Double(max(0, min(100, percent))) / 100) }
                    }
            }.frame(height: 3).accessibilityHidden(true)
        }.font(.system(size: 11)).help("System utilization is informational and does not establish activity.")
    }
}
#endif
