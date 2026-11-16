#if os(macOS)
import AppKit
import SwiftUI
import NightrCore

extension Color {
    static let nightrAmber = Color(nsColor: .nightrAccent)
    static let nightrButtonAmber = Color(red: 242/255, green: 169/255, blue: 59/255)
}
private extension NSColor {
    static let nightrAccent = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(calibratedRed: 227/255, green: 173/255, blue: 77/255, alpha: 1)
        }
        return NSColor(calibratedRed: 117/255, green: 82/255, blue: 30/255, alpha: 1)
    }
}

struct SettingsHost: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    var body: some View {
        SettingsView(section: $model.presentation.section, status: model.status, store: model.store,
                     apply: { try await model.applySettingsForSave($0) }, close: close)
    }
}

/// Native buttons preserve normal Tab/Space behavior. Arrow/Home/End moves both
/// selection and focus within this one toolbar, without intercepting field keys.
struct SettingsToolbar: View {
    @Binding var selection: NightrSettingsSection
    var body: some View {
        NativeSettingsToolbar(selection: $selection)
            .frame(width: 390, height: 64)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }
}
private struct NativeSettingsToolbar: NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    @Binding var selection: NightrSettingsSection
    func makeNSView(context: Context) -> NSStackView {
        let stack = NSStackView(); stack.orientation = .horizontal; stack.spacing = 6
        stack.alignment = .centerY; stack.distribution = .fillEqually
        for (index, section) in NightrSettingsSection.allCases.enumerated() {
            let button = SectionButton(title: section.rawValue, target: context.coordinator, action: #selector(Coordinator.select(_:)))
            button.tag = index; button.imagePosition = .imageAbove; button.isBordered = false
            button.font = .systemFont(ofSize: 13); button.imageScaling = .scaleProportionallyDown
            let symbol: String
            switch section { case .general: symbol = "gearshape"; case .protection: symbol = "moon"; case .connectivity: symbol = "wifi"; case .advanced: symbol = "slider.horizontal.3" }
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 24, weight: .regular))
            button.setAccessibilityLabel(section.rawValue + " settings")
            button.setAccessibilityRole(.radioButton)
            button.widthAnchor.constraint(equalToConstant: 93).isActive = true
            button.heightAnchor.constraint(equalToConstant: 58).isActive = true
            button.navigate = { [weak stack] target in
                guard let buttons = stack?.arrangedSubviews as? [SectionButton] else { return }
                let next = (target + buttons.count) % buttons.count
                buttons.forEach { $0.selectedSection = $0.tag == next }
                context.coordinator.choose(next)
                buttons[next].window?.makeFirstResponder(buttons[next])
            }
            stack.addArrangedSubview(button)
        }
        return stack
    }
    func updateNSView(_ stack: NSStackView, context: Context) {
        context.coordinator.parent = self
        for case let button as SectionButton in stack.arrangedSubviews {
            button.isEnabled = enabled
            button.selectedSection = NightrSettingsSection.allCases[button.tag] == selection
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject {
        var parent: NativeSettingsToolbar
        init(_ parent: NativeSettingsToolbar) { self.parent = parent }
        @objc func select(_ sender: NSButton) { choose(sender.tag) }
        func choose(_ index: Int) { parent.selection = NightrSettingsSection.allCases[index] }
    }
}
private final class SectionButton: NSButton {
    var navigate: ((Int) -> Void)?
    var selectedSection = false { didSet {
        contentTintColor = selectedSection ? NSColor.nightrAccent : .labelColor
        needsDisplay = true; setAccessibilityValue(selectedSection ? 1 : 0)
    } }
    override var acceptsFirstResponder: Bool { selectedSection && isEnabled }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 126: navigate?(tag - 1)
        case 124, 125: navigate?(tag + 1)
        case 115: navigate?(0)
        case 119: navigate?(NightrSettingsSection.allCases.count - 1)
        default: super.keyDown(with: event)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        if selectedSection {
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
            NSColor(calibratedRed: 0.80, green: 0.51, blue: 0.12, alpha: 0.08).setFill(); shape.fill()
            NSColor(calibratedRed: 0.80, green: 0.51, blue: 0.12, alpha: 0.25).setStroke(); shape.stroke()
        }
        super.draw(dirtyRect)
    }
}
#endif
