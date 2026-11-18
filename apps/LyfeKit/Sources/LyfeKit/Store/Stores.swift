import Foundation
import Security

/// Where the device token lives between launches.
public protocol TokenStore: Sendable {
    func load() -> String?
    func save(_ token: String)
    func clear()
}

/// Keeps the token in the Keychain, on this device only, readable after
/// the first unlock so later background refreshes can use it.
public struct KeychainTokenStore: TokenStore {
    private let service: String
    private let account = "device-token"

    public init(service: String = "lyfe.backend") {
        self.service = service
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ token: String) {
        clear()
        var attributes = query
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Token storage that forgets on exit; for tests and previews.
public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    public init(token: String? = nil) {
        self.token = token
    }

    public func load() -> String? {
        lock.withLock { token }
    }

    public func save(_ token: String) {
        lock.withLock { self.token = token }
    }

    public func clear() {
        lock.withLock { token = nil }
    }
}

/// The last Home state the backend sent, kept so the app can show it with
/// its age when the backend cannot be reached.
public struct CachedHome: Codable, Equatable, Sendable {
    public var snapshot: HomeSnapshot
    public var fetchedAt: Date

    public init(snapshot: HomeSnapshot, fetchedAt: Date) {
        self.snapshot = snapshot
        self.fetchedAt = fetchedAt
    }
}

public struct HomeCache: Sendable {
    private let file: URL

    public init(directory: URL) {
        file = directory.appending(path: "home.json")
    }

    /// The app's own Application Support folder.
    public static func standard() -> HomeCache {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return HomeCache(directory: base.appending(path: "lyfe"))
    }

    public func load() -> CachedHome? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder.lyfe.decode(CachedHome.self, from: data)
    }

    public func save(_ cached: CachedHome) {
        guard let data = try? JSONEncoder.lyfe.encode(cached) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func clear() {
        try? FileManager.default.removeItem(at: file)
    }
}

/// Remembers the backend address between launches. Not a secret.
public protocol ServerAddressStore: Sendable {
    func load() -> String?
    func save(_ address: String)
}

public struct DefaultsServerAddressStore: ServerAddressStore {
    private let key = "lyfe.serverAddress"

    public init() {}

    public func load() -> String? {
        UserDefaults.standard.string(forKey: key)
    }

    public func save(_ address: String) {
        UserDefaults.standard.set(address, forKey: key)
    }
}

public final class MemoryServerAddressStore: ServerAddressStore, @unchecked Sendable {
    private let lock = NSLock()
    private var address: String?

    public init(address: String? = nil) {
        self.address = address
    }

    public func load() -> String? {
        lock.withLock { address }
    }

    public func save(_ address: String) {
        lock.withLock { self.address = address }
    }
}
