import Foundation

/// Reaches a backend on the tailnet even when this device looks names up
/// outside Tailscale.
///
/// A tailnet name can have two answers: Tailscale's own, and a public one
/// that exists when the same machine publishes other things to the internet.
/// A device whose DNS is not Tailscale's gets the public one, where the
/// backend is not published, and every request times out. So for a
/// `.ts.net` name this checks the system's answer first. If it is not a
/// tailnet address, it asks Tailscale's resolver directly and connects to
/// that address, still requiring the server's certificate to match the name.
public struct TailnetTransport: HTTPTransport {
    private let system: any HTTPTransport
    private let direct: any AddressedTransport
    private let lookup: NameLookup
    private let tailscale: NameLookup

    public init(
        system: any HTTPTransport, direct: any AddressedTransport, lookup: NameLookup, tailscale: NameLookup
    ) {
        self.system = system
        self.direct = direct
        self.lookup = lookup
        self.tailscale = tailscale
    }

    /// Wired to URLSession, the system resolver and Tailscale's resolver.
    public static func live() -> TailnetTransport {
        TailnetTransport(
            system: URLSessionTransport(), direct: DirectTLSTransport(), lookup: .system, tailscale: .tailscale)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.scheme?.lowercased() == "https", let host = url.host(),
            host.lowercased().hasSuffix(".ts.net")
        else { return try await system.send(request) }

        let seen = await lookup.addresses(host)
        if let inside = seen.first(where: isTailnetAddress) {
            return try await explaining(at: inside) { try await system.send(request) }
        }
        if let inside = await tailscale.addresses(host).first(where: isTailnetAddress) {
            return try await explaining(at: inside) { try await direct.send(request, to: inside) }
        }
        // Tailscale has no answer either: it is off, or the name is wrong.
        do {
            return try await system.send(request)
        } catch let error as URLError where Self.pointsAtLookup.contains(error.code) {
            guard let outside = seen.first else { throw error }
            throw LyfeAPIError.unreachable(
                why: "Tailscale did not answer for its name, and without it the name leads to \(outside), "
                    + "where lyfe is not published; open the Tailscale app and check it is connected "
                    + "(\(error.code.rawValue))")
        }
    }

    /// The failures a name that led to the wrong place can cause.
    private static let pointsAtLookup: Set<URLError.Code> = [
        .timedOut, .cannotConnectToHost, .secureConnectionFailed, .networkConnectionLost,
    ]

    /// Runs an attempt and, if the server could not be reached, adds the
    /// address that was tried to the reason.
    private func explaining(
        at address: String, _ attempt: () async throws -> (Data, HTTPURLResponse)
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await attempt()
        } catch let error as URLError where Self.pointsAtLookup.contains(error.code) {
            throw LyfeAPIError.unreachable(why: "\(LyfeAPI.explain(error)), at \(address)")
        }
    }
}
