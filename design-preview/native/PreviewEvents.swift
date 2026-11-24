import Foundation

extension Notification.Name {
    static let previewOpenSettings = Self("NightrPreview.OpenSettings")
    static let previewCloseSettings = Self("NightrPreview.CloseSettings")
    static let previewForceChanged = Self("NightrPreview.ForceChanged")
    static let previewStateChanged = Self("NightrPreview.StateChanged")
    static let previewSettingsSaved = Self("NightrPreview.SettingsSaved")
}
