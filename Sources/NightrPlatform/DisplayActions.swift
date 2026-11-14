#if os(macOS)
import Foundation
import CoreGraphics
import Darwin

// These fixed system symbols preserve the extracted utility's lock/dim behavior.
// They are optional macOS compatibility facilities, not a claim of public API
// support. A missing symbol fails visibly; Nightr never unlocks the session.
final class DisplayActions {
    private var original: (CGDirectDisplayID, Float)?
    private let display = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private let login = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY)
    deinit { restore(); if let display { dlclose(display) }; if let login { dlclose(login) } }
    func lock() throws {
        guard let login, let symbol = dlsym(login, "SACLockScreenImmediate") else { throw ProtectionFailure.setup }
        typealias Lock = @convention(c) () -> Void
        unsafeBitCast(symbol, to: Lock.self)()
    }
    func dim() throws {
        guard let display, let get = dlsym(display, "DisplayServicesGetBrightness"), let set = dlsym(display, "DisplayServicesSetBrightness") else { throw ProtectionFailure.setup }
        typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
        typealias Set = @convention(c) (UInt32, Float) -> Int32
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success,
              let builtin = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else { throw ProtectionFailure.setup }
        var brightness: Float = 0
        guard unsafeBitCast(get, to: Get.self)(builtin, &brightness) == 0,
              unsafeBitCast(set, to: Set.self)(builtin, 0) == 0 else { throw ProtectionFailure.setup }
        if original == nil { original = (builtin, brightness) }
    }
    @discardableResult func restore() -> Bool {
        guard let original else { return true }
        guard let display, let symbol = dlsym(display, "DisplayServicesSetBrightness") else { return false }
        typealias Set = @convention(c) (UInt32, Float) -> Int32
        guard unsafeBitCast(symbol, to: Set.self)(original.0, original.1) == 0 else { return false }
        self.original = nil; return true
    }
}
#endif
