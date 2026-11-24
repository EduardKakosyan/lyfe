import Foundation

#if canImport(LocalAuthentication)
    import LocalAuthentication
#endif

/// Asks the device to confirm that the person holding it is its owner:
/// Face ID, with the passcode behind it. lyfe asks whenever it is opened.
public protocol OwnerCheck: Sendable {
    /// Whether this device can check at all. One with no passcode cannot,
    /// and lyfe then opens without asking rather than never opening.
    var isAvailable: Bool { get }
    func confirm(reason: String) async -> Bool
}

/// No check: lyfe opens without asking. For tests, previews, and a
/// development build told to run by itself.
public struct NoOwnerCheck: OwnerCheck {
    public init() {}
    public var isAvailable: Bool { false }
    public func confirm(reason: String) async -> Bool { true }
}

#if canImport(LocalAuthentication)
    /// Face ID or Touch ID, falling back to the device passcode.
    public struct DeviceOwnerCheck: OwnerCheck {
        public init() {}

        public var isAvailable: Bool {
            LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        }

        public func confirm(reason: String) async -> Bool {
            (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        }
    }
#endif
