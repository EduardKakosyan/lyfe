import Foundation

@testable import LyfeKit

/// A stand-in backend: answers each request from a table of routes and
/// remembers what was asked.
final class StubBackend: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: String

        static func ok(_ body: String) -> Reply { Reply(status: 200, body: body) }
    }

    private let lock = NSLock()
    private var routes: [String: [Reply]] = [:]
    private var log: [URLRequest] = []
    private var down: URLError.Code?

    /// Queues replies for "METHOD /path". The last one repeats.
    func on(_ route: String, _ replies: Reply...) {
        lock.withLock { routes[route] = replies }
    }

    /// Makes every request fail as if the server were unreachable.
    func goDown(_ isDown: Bool = true, as code: URLError.Code = .cannotConnectToHost) {
        lock.withLock { down = isDown ? code : nil }
    }

    var requests: [String] {
        lock.withLock { log.map { "\($0.httpMethod ?? "GET") \($0.url!.path)" } }
    }

    func lastRequest(_ route: String) -> URLRequest? {
        lock.withLock { log.last { "\($0.httpMethod ?? "GET") \($0.url!.path)" == route } }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply? = lock.withLock {
            log.append(request)
            if down != nil { return nil }
            let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
            guard var queue = routes[key], !queue.isEmpty else { return Reply(status: 404, body: "{}") }
            let next = queue.count > 1 ? queue.removeFirst() : queue[0]
            routes[key] = queue
            return next
        }
        guard let reply else { throw URLError(lock.withLock { down } ?? .cannotConnectToHost) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        return (Data(reply.body.utf8), response)
    }
}

enum Fixture {
    static func sources(state: String = "ok", syncedAt: String? = "2026-11-17T14:58:00Z", message: String? = nil)
        -> String
    {
        let synced = syncedAt.map { "\"\($0)\"" } ?? "null"
        let text = message.map { "\"\($0)\"" } ?? "null"
        return """
            {"garmin": {"state": "\(state)", "last_success_at": \(synced), "last_attempt_at": \(synced), "message": \(text)}}
            """
    }

    /// A Home answer in exactly the shape the backend sends.
    static func home(done: Int = 1, sources: String = Fixture.sources()) -> String {
        let all = [
            """
            {"date": "2026-11-16", "activity_id": 501, "activity_type": "strength_training", "name": "Strength", "duration_min": 58}
            """,
            """
            {"date": "2026-11-17", "activity_id": 502, "activity_type": "lap_swimming", "name": null, "duration_min": 41}
            """,
        ]
        return """
            {
              "generated_at": "2026-11-17T15:00:00Z",
              "today": "2026-11-17",
              "week": {"iso_year": 2026, "iso_week": 47, "starts_on": "2026-11-16", "ends_on": "2026-11-22"},
              "gym": {"target": 4, "done": \(done), "remaining": \(4 - done), "days_left": 6,
                      "sessions": [\(all.prefix(done).joined(separator: ","))]},
              "sources": \(sources)
            }
            """
    }

    static func snapshot(done: Int = 1) -> HomeSnapshot {
        try! JSONDecoder.lyfe.decode(HomeSnapshot.self, from: Data(home(done: done).utf8))
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "lyfe-tests-\(UUID().uuidString)")
    }
}

@MainActor
struct World {
    let backend = StubBackend()
    let tokens: MemoryTokenStore
    let addresses: MemoryServerAddressStore
    let cache = HomeCache(directory: Fixture.temporaryDirectory())
    let clock = Date(timeIntervalSince1970: 1_795_000_000)

    init(token: String? = nil, address: String? = nil) {
        tokens = MemoryTokenStore(token: token)
        addresses = MemoryServerAddressStore(address: address)
    }

    /// A signed-in world with nothing cached.
    static func signedIn() -> World {
        World(token: "device-token", address: "lyfe.example.ts.net:8444")
    }

    func launch(transport: (any HTTPTransport)? = nil) -> AppModel {
        let clock = clock
        return AppModel(
            tokens: tokens, addresses: addresses, cache: cache, transport: transport ?? backend,
            deviceName: "Test iPhone", now: { clock })
    }
}
