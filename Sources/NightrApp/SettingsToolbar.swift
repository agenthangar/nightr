#if os(macOS)
import AppKit
import SwiftUI
import NightrCore

extension Color {
    static let nightrAmber = Color(nsColor: .nightrAccent)
    static let nightrButtonAmber = Color(red: 242/255, green: 169/255, blue: 59/255)
    static let nightrStatusGreen = Color(nsColor: .nightrStatusGreen)
    static let nightrSurface = Color(nsColor: .nightrSurface)
    static let nightrInk = Color(nsColor: .nightrInk)
    static let nightrMuted = Color(nsColor: .nightrMuted)
    static let nightrLine = Color(nsColor: .nightrLine)
}
extension NSColor {
    // Approved native preview tokens. Opaque surfaces give the same contrast
    // regardless of the wallpaper beneath a Settings window or popover.
    static let nightrSurface = adaptive(light: 0xf6f5f2, dark: 0x27292e)
    static let nightrInk = adaptive(light: 0x202228, dark: 0xf3f3f5)
    static let nightrMuted = adaptive(light: 0x666b75, dark: 0xaaaeb7)
    static let nightrLine = adaptive(light: 0x000000, dark: 0xffffff, lightAlpha: 0.086, darkAlpha: 0.09)
    static let nightrSelectedFill = adaptive(light: 0xe7e4de, dark: 0x808080, darkAlpha: 0.098)
    static let nightrSelectedBorder = adaptive(light: 0xd5d1c8, dark: 0x808080, darkAlpha: 0.145)
    private static func adaptive(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        }
    }
    static let nightrAccent = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 219/255, green: 168/255, blue: 77/255, alpha: 1)
        }
        return NSColor(srgbRed: 117/255, green: 82/255, blue: 30/255, alpha: 1)
    }
    static let nightrStatusGreen = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 149/255, green: 206/255, blue: 166/255, alpha: 1)
        }
        return NSColor(srgbRed: 40/255, green: 116/255, blue: 66/255, alpha: 1)
    }
}

enum SettingsLayout {
    static let contentInset: CGFloat = 20
    static let labelWidth: CGFloat = 160
    static let width: CGFloat = 600
    static let bodyHeight: CGFloat = 590
}

struct SettingsHost: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    var body: some View {
        SettingsView(section: $model.presentation.section, status: model.status, store: model.store,
                     apply: { try await model.applySettingsForSave($0) }, close: close)
    }
}

/// Keep the approved fills and contrast when Settings is inactive as well as
/// active; SwiftUI's standard macOS prominent style becomes gray when inactive.
struct SettingsActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: primary ? .semibold : .regular))
            .foregroundStyle(primary && enabled ? Color(red: 40/255, green: 28/255, blue: 13/255) : enabled ? Color.nightrInk : Color.nightrMuted)
            .padding(.horizontal, 15).frame(height: 30)
            .background(enabled && primary ? Color(red: 227/255, green: 173/255, blue: 77/255) : scheme == .light ? Color.white : Color.nightrSurface,
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(primary && enabled ? Color(red: 203/255, green: 150/255, blue: 60/255) : scheme == .light ? Color(red: 191/255, green: 192/255, blue: 196/255) : Color.nightrLine))
            .opacity(configuration.isPressed ? 0.75 : enabled ? 1 : 0.65)
    }
}

/// AppKit text field keeps the native title typography while centering it
/// independently of the close button and selected Settings section.
struct SettingsWindowTitle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSTextField {
        let title = NSTextField(labelWithString: "Nightr Settings")
        title.alignment = .center
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .nightrInk
        title.setAccessibilityRole(.staticText)
        title.setAccessibilityIdentifier("settings-window-title")
        return title
    }
    func updateNSView(_ title: NSTextField, context: Context) {}
}

/// Native buttons preserve normal Tab/Space behavior. Arrow/Home/End moves both
/// selection and focus within this one toolbar, without intercepting field keys.
struct SettingsToolbar: View {
    @Binding var selection: NightrSettingsSection
    var body: some View {
        NativeSettingsToolbar(selection: $selection)
            .frame(height: 56.5)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, SettingsLayout.contentInset)
            .padding(.top, 16)
            .padding(.bottom, 11)
            .background(Color.nightrSurface)
    }
}
private struct NativeSettingsToolbar: NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    @Binding var selection: NightrSettingsSection
    func makeNSView(context: Context) -> NSStackView {
        let stack = NSStackView(); stack.orientation = .horizontal; stack.spacing = 2
        stack.alignment = .centerY; stack.distribution = .fillEqually
        for (index, section) in NightrSettingsSection.allCases.enumerated() {
            let button = SectionButton(title: section.rawValue, target: context.coordinator, action: #selector(Coordinator.select(_:)))
            button.tag = index; button.imagePosition = .imageAbove; button.isBordered = false
            button.font = .systemFont(ofSize: 11); button.imageScaling = .scaleProportionallyDown
            let symbol: String
            switch section { case .general: symbol = "gearshape"; case .protection: symbol = "moon"; case .connectivity: symbol = "wifi"; case .advanced: symbol = "slider.horizontal.3" }
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 21, weight: .regular))
            button.setAccessibilityLabel(section.rawValue + " settings")
            button.setAccessibilityRole(.radioButton)
            button.heightAnchor.constraint(equalToConstant: 56.5).isActive = true
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
        contentTintColor = selectedSection ? NSColor.nightrAccent : .nightrMuted
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
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            NSColor.nightrSelectedFill.setFill(); shape.fill()
            NSColor.nightrSelectedBorder.setStroke(); shape.stroke()
        }
        super.draw(dirtyRect)
    }
}
#endif
