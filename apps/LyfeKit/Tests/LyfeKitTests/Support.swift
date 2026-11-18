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

    /// The bodies sent to a route, oldest first.
    func bodies(_ route: String) -> [Data] {
        lock.withLock {
            log.filter { "\($0.httpMethod ?? "GET") \($0.url!.path)" == route }.compactMap(\.httpBody)
        }
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

    /// A streak in exactly the shape the backend sends. `recent` is one
    /// letter per finished week, ending with week 46: K kept, R recovered,
    /// A awaiting recovery, M missed.
    static func streak(
        weeks: Int = 6, state: String = "on_track", previousBest: Int = 0, remaining: Int = 3, openDays: Int = 6,
        recent: String = "KKKKKK"
    ) -> String {
        let marks: [Character: String] = ["K": "kept", "R": "recovered", "A": "awaiting_recovery", "M": "missed"]
        // Mondays of ISO weeks 35 to 46 of 2026.
        let mondays = [
            "2026-08-24", "2026-08-31", "2026-09-07", "2026-09-14", "2026-09-21", "2026-09-28",
            "2026-10-05", "2026-10-12", "2026-10-19", "2026-10-26", "2026-11-02", "2026-11-09",
        ]
        let first = mondays.count - recent.count
        let weeksJSON = recent.enumerated().map { index, letter in
            let mark = marks[letter]!
            let done = mark == "kept" ? 4 : 2
            return """
                {"iso_year": 2026, "iso_week": \(35 + first + index), "starts_on": "\(mondays[first + index])", "done": \(done), "mark": "\(mark)"}
                """
        }
        return """
            {"weeks": \(weeks), "state": "\(state)", "previous_best": \(previousBest), "remaining": \(remaining),
             "open_days": \(openDays), "reachable": \(remaining <= openDays), "recent": [\(weeksJSON.joined(separator: ","))]}
            """
    }

    /// A Home answer in exactly the shape the backend sends. Without
    /// `streak` it is the answer from before streaks existed.
    static func home(
        done: Int = 1, sources: String = Fixture.sources(), streak: String? = nil, today: String = "2026-11-17",
        serverReady: Bool? = nil
    ) -> String {
        let streakJSON = streak.map { ", \"streak\": \($0)" } ?? ""
        let notifications = serverReady.map { ", \"notifications\": {\"server_ready\": \($0)}" } ?? ""
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
              "today": "\(today)",
              "week": {"iso_year": 2026, "iso_week": 47, "starts_on": "2026-11-16", "ends_on": "2026-11-22"},
              "gym": {"target": 4, "done": \(done), "remaining": \(max(0, 4 - done)), "days_left": 6,
                      "sessions": [\(all.prefix(done).joined(separator: ","))]\(streakJSON)},
              "sources": \(sources)\(notifications)
            }
            """
    }

    static func snapshot(done: Int = 1, streak: String? = nil, today: String = "2026-11-17") -> HomeSnapshot {
        try! JSONDecoder.lyfe.decode(
            HomeSnapshot.self, from: Data(home(done: done, streak: streak, today: today).utf8))
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
