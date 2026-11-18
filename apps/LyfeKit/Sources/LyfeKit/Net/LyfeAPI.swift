import Foundation

/// The network seam: one request in, one response out. Tests replace it.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

public enum LyfeAPIError: Error, Equatable, Sendable {
    /// The device token is missing, revoked or unknown.
    case unauthorized
    case wrongPassword
    case tooManyAttempts(retryAfterSeconds: Int)
    /// The backend has no password yet (`lyfe-server set-password`).
    case noPasswordSet
    /// The backend did not answer: Tailscale off, Spark down, no network.
    /// `why` says which, in words that finish "Can't reach the server: …".
    case unreachable(why: String)
    case server(status: Int)
    case unreadableResponse
}

/// The backend's HTTP API, one method per endpoint.
public struct LyfeAPI: Sendable {
    public let baseURL: URL
    private let transport: any HTTPTransport

    public init(baseURL: URL, transport: any HTTPTransport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// Tells the backend where Apple delivers notifications for this device.
    public func setPushToken(token: String, apnsToken: String) async throws {
        struct Body: Encodable {
            var apnsToken: String
        }
        let body = try JSONEncoder.lyfe.encode(Body(apnsToken: apnsToken))
        _ = try await perform("POST", "v1/push-token", token: token, body: body, timeout: 15)
    }

    /// Whether the backend answers at all, without signing in.
    public func isReachable() async throws {
        _ = try await perform("GET", "healthz", token: nil, body: nil, timeout: 15)
    }

    public func signIn(password: String, deviceName: String) async throws -> String {
        struct Body: Encodable {
            var password: String
            var deviceName: String
        }
        struct Reply: Decodable {
            var token: String
        }
        let body = try JSONEncoder.lyfe.encode(Body(password: password, deviceName: deviceName))
        let reply: Reply = try await call("POST", "v1/auth/sign-in", token: nil, body: body, timeout: 20)
        return reply.token
    }

    public func signOut(token: String) async throws {
        _ = try await perform("POST", "v1/auth/sign-out", token: token, body: nil, timeout: 15)
    }

    public func home(token: String) async throws -> HomeSnapshot {
        try await call("GET", "v1/home", token: token, body: nil, timeout: 15)
    }

    /// Hands the backend a finished breath session. It answers with Home as
    /// it now stands. Sending the same session again changes nothing.
    public func recordBreathSession(token: String, run: BreathRun) async throws -> HomeSnapshot {
        let body = try JSONEncoder.lyfe.encode(BreathSessionUpload(run))
        return try await call("POST", "v1/breath/sessions", token: token, body: body, timeout: 20)
    }

    /// Asks the backend to check Garmin now. Can take as long as Garmin does.
    public func sync(token: String) async throws -> Sources {
        try await call("POST", "v1/sync", token: token, body: nil, timeout: 45)
    }

    /// Which part of the path failed, with the system's error number so it
    /// can be looked up.
    static func explain(_ error: URLError) -> String {
        let what =
            switch error.code {
            case .cannotFindHost, .dnsLookupFailed:
                "its name was not found; in the Tailscale app, check it is connected and using Tailscale DNS"
            case .timedOut:
                "it did not answer in time"
            case .cannotConnectToHost:
                "it was found but refused the connection; check the port in the address"
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                "this device has no network connection"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
                .clientCertificateRequired:
                "the secure connection could not be set up"
            case .appTransportSecurityRequiresSecureConnection:
                "the address must be https"
            default:
                "the connection failed"
            }
        return "\(what) (\(error.code.rawValue))"
    }

    private func call<Reply: Decodable>(
        _ method: String, _ path: String, token: String?, body: Data?, timeout: TimeInterval
    ) async throws -> Reply {
        let data = try await perform(method, path, token: token, body: body, timeout: timeout)
        do {
            return try JSONDecoder.lyfe.decode(Reply.self, from: data)
        } catch {
            throw LyfeAPIError.unreadableResponse
        }
    }

    private func perform(
        _ method: String, _ path: String, token: String?, body: Data?, timeout: TimeInterval
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as LyfeAPIError {
            // A transport that already knows why it could not get through.
            throw error
        } catch let error as URLError {
            throw LyfeAPIError.unreachable(why: Self.explain(error))
        } catch {
            throw LyfeAPIError.unreachable(why: "the connection failed")
        }

        if (200..<300).contains(response.statusCode) {
            return data
        }
        struct Failure: Decodable {
            var error: String?
            var retryAfterS: Int?
        }
        let failure = try? JSONDecoder.lyfe.decode(Failure.self, from: data)
        switch (response.statusCode, failure?.error) {
        case (401, "wrong_password"): throw LyfeAPIError.wrongPassword
        case (401, _): throw LyfeAPIError.unauthorized
        case (429, _): throw LyfeAPIError.tooManyAttempts(retryAfterSeconds: failure?.retryAfterS ?? 60)
        case (503, "no_password_set"): throw LyfeAPIError.noPasswordSet
        case (502, _), (503, _), (504, _):
            // A proxy in front of a stopped backend answers like this.
            throw LyfeAPIError.unreachable(
                why: "the Spark answered but lyfe is not running on it (\(response.statusCode))")
        default: throw LyfeAPIError.server(status: response.statusCode)
        }
    }
}

/// Turns what the owner typed into the backend's address. A bare host gets
/// `https://`, since the backend is published over HTTPS on the tailnet.
public func serverURL(from text: String) -> URL? {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if !trimmed.contains("://") {
        trimmed = "https://" + trimmed
    }
    while trimmed.hasSuffix("/") {
        trimmed.removeLast()
    }
    guard let components = URLComponents(string: trimmed),
        let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
        let host = components.host, !host.isEmpty,
        components.query == nil, components.fragment == nil
    else { return nil }
    return components.url
}
