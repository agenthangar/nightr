import Foundation
#if os(macOS)
@objc public protocol NightrPowerXPC {
    func acquire(_ threshold: Int, reply: @escaping (String?, String?) -> Void)
    func renew(_ generation: String, threshold: Int, reply: @escaping (String?) -> Void)
    func release(_ generation: String, reply: @escaping (String?) -> Void)
    func status(reply: @escaping (String) -> Void)
}
#endif
public struct PowerReply: Codable {
    public let active: Bool
    public let restorationBlocked: Bool
    public let lease: String?
    public init(active: Bool, restorationBlocked: Bool, lease: String? = nil) {
        self.active = active; self.restorationBlocked = restorationBlocked; self.lease = lease
    }
}
