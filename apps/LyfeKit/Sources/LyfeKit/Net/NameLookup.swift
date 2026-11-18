import Foundation

/// How this device turns a server's name into addresses. Used only to say
/// why the server could not be reached: a tailnet name looked up outside
/// Tailscale gets public addresses where the backend is not published.
public struct NameLookup: Sendable {
    public var addresses: @Sendable (_ host: String) async -> [String]

    public init(addresses: @escaping @Sendable (_ host: String) async -> [String]) {
        self.addresses = addresses
    }

    /// Asks the system resolver, the same one the connection itself uses.
    public static let system = NameLookup { host in await systemAddresses(for: host) }

    /// Looks nothing up. For tests and previews.
    public static let none = NameLookup { _ in [] }
}

/// True for addresses Tailscale gives to devices: 100.64.0.0/10 and
/// fd7a:115c:a1e0::/48.
public func isTailnetAddress(_ address: String) -> Bool {
    let lowered = address.lowercased()
    if lowered.hasPrefix("fd7a:115c:a1e0:") {
        return true
    }
    let parts = lowered.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4, let first = Int(parts[0]), let second = Int(parts[1]) else { return false }
    return first == 100 && (64...127).contains(second)
}

/// True when the host is written as an address, so no lookup is involved.
func isAddressLiteral(_ host: String) -> Bool {
    var v4 = in_addr()
    var v6 = in6_addr()
    let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    return inet_pton(AF_INET, bare, &v4) == 1 || inet_pton(AF_INET6, bare, &v6) == 1
}

/// The system's answer for a name, or nothing if it has none within the
/// time allowed. The lookup itself cannot be cancelled, so it is left to
/// finish on its own when the time runs out.
func systemAddresses(for host: String, within seconds: Double = 4) async -> [String] {
    let answer = FirstAnswer<[String]>()
    return await withCheckedContinuation { continuation in
        answer.wait(continuation)
        DispatchQueue.global(qos: .userInitiated).async {
            answer.give(resolve(host))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            answer.give([])
        }
    }
}

/// Hands the first of several competing results to one waiting caller and
/// drops the rest. A result that arrives before the caller waits is kept.
final class FirstAnswer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var early: Value?
    private var isDone = false

    func wait(_ continuation: CheckedContinuation<Value, Never>) {
        let ready: Value? = lock.withLock {
            if let early {
                self.early = nil
                return early
            }
            self.continuation = continuation
            return nil
        }
        if let ready {
            continuation.resume(returning: ready)
        }
    }

    /// Returns true if this was the result that got used.
    @discardableResult
    func give(_ value: Value) -> Bool {
        let (wasFirst, waiting): (Bool, CheckedContinuation<Value, Never>?) = lock.withLock {
            guard !isDone else { return (false, nil) }
            isDone = true
            guard let continuation else {
                early = value
                return (true, nil)
            }
            self.continuation = nil
            return (true, continuation)
        }
        waiting?.resume(returning: value)
        return wasFirst
    }
}

private func resolve(_ host: String) -> [String] {
    var hints = addrinfo()
    hints.ai_socktype = SOCK_STREAM
    var list: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
    defer { freeaddrinfo(first) }

    var found: [String] = []
    var next: UnsafeMutablePointer<addrinfo>? = first
    while let entry = next {
        var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(
            entry.pointee.ai_addr, entry.pointee.ai_addrlen, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0
        {
            let bytes = text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let address = String(decoding: bytes, as: UTF8.self)
            if !found.contains(address) {
                found.append(address)
            }
        }
        next = entry.pointee.ai_next
    }
    return found
}
