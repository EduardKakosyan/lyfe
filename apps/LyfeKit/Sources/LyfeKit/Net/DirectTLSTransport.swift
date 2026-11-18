import Foundation
import Network
import Security

/// Sends a request to an address chosen by the caller instead of one looked
/// up from the request's host.
public protocol AddressedTransport: Sendable {
    func send(_ request: URLRequest, to address: String) async throws -> (Data, HTTPURLResponse)
}

/// HTTPS to a given address. The request's host is still what the server's
/// certificate must match, so only the name lookup is skipped, not the
/// check of who answered. Failures are reported as `URLError`, like
/// `URLSessionTransport`.
public struct DirectTLSTransport: AddressedTransport {
    /// Answers larger than this are refused.
    static let largestAnswer = 32 * 1024 * 1024

    public init() {}

    public func send(_ request: URLRequest, to address: String) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.scheme?.lowercased() == "https", let host = url.host(),
            let port = NWEndpoint.Port(rawValue: UInt16(clamping: url.port ?? 443)),
            let payload = HTTPMessage.request(request)
        else { throw URLError(.badURL) }

        let queue = DispatchQueue(label: "lyfe.direct-tls")
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, trust, complete in
                let trust = sec_trust_copy_ref(trust).takeRetainedValue()
                SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
                complete(SecTrustEvaluateWithError(trust, nil))
            }, queue)
        let connection = NWConnection(host: NWEndpoint.Host(address), port: port, using: NWParameters(tls: tls))

        let exchange = Exchange(connection: connection, payload: payload, queue: queue)
        let message = try await exchange.run(timeout: request.timeoutInterval).get()
        guard
            let response = HTTPURLResponse(
                url: url, statusCode: message.status, httpVersion: "HTTP/1.1", headerFields: message.headers)
        else { throw URLError(.badServerResponse) }
        return (message.body, response)
    }

    static func urlError(_ error: NWError) -> URLError {
        switch error {
        case .tls:
            return URLError(.secureConnectionFailed)
        case .dns:
            return URLError(.cannotFindHost)
        case .posix(let code):
            switch code {
            case .ETIMEDOUT: return URLError(.timedOut)
            case .ECONNRESET, .ECONNABORTED, .EPIPE, .ENOTCONN: return URLError(.networkConnectionLost)
            case .ECANCELED: return URLError(.cancelled)
            default: return URLError(.cannotConnectToHost)
            }
        default:
            return URLError(.cannotConnectToHost)
        }
    }
}

/// One request and its answer on one connection. Everything after `run`
/// happens on the connection's queue.
private final class Exchange: @unchecked Sendable {
    private let connection: NWConnection
    private let payload: Data
    private let queue: DispatchQueue
    private let outcome = FirstAnswer<Result<HTTPMessage, URLError>>()
    private var received = Data()

    init(connection: NWConnection, payload: Data, queue: DispatchQueue) {
        self.connection = connection
        self.payload = payload
        self.queue = queue
    }

    func run(timeout: TimeInterval) async -> Result<HTTPMessage, URLError> {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                outcome.wait(continuation)
                connection.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready:
                        begin()
                    case .failed(let error), .waiting(let error):
                        // `.waiting` means no route right now; say so
                        // rather than hold the screen until the timeout.
                        finish(.failure(DirectTLSTransport.urlError(error)))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { [self] in
                    finish(.failure(URLError(.timedOut)))
                }
            }
        } onCancel: {
            finish(.failure(URLError(.cancelled)))
        }
    }

    private func finish(_ result: Result<HTTPMessage, URLError>) {
        if outcome.give(result) {
            connection.cancel()
        }
    }

    private func begin() {
        connection.send(
            content: payload,
            completion: .contentProcessed { [self] error in
                if let error {
                    finish(.failure(DirectTLSTransport.urlError(error)))
                }
            })
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data {
                received.append(data)
            }
            guard received.count <= DirectTLSTransport.largestAnswer else {
                finish(.failure(URLError(.dataLengthExceedsMaximum)))
                return
            }
            let atEnd = isComplete || error != nil
            do {
                if let message = try HTTPMessage.response(from: received, atEnd: atEnd) {
                    finish(.success(message))
                } else {
                    receive()
                }
            } catch {
                // Closed before a whole answer arrived, or not HTTP.
                finish(.failure(URLError(received.isEmpty ? .networkConnectionLost : .badServerResponse)))
            }
        }
    }
}
