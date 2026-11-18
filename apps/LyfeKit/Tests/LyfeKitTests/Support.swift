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
    /// Breath training in exactly the shape the backend sends. `holds` is
    /// one session per entry, on Monday, Tuesday and so on of week 47, each
    /// a list of holds in seconds from round 1 on.
    static func breath(
        holds: [[Int]] = [], streak: String = Fixture.streak(weeks: 0, state: "not_started", recent: ""),
        doneToday: Bool = false, roundS: Int = 240, changedFromS: Int? = nil, lastHolds: [Int?]? = nil,
        ids: [String]? = nil
    ) -> String {
        func list(_ values: [Int?]) -> String {
            "[" + values.map { $0.map { String($0 * 1000) } ?? "null" }.joined(separator: ",") + "]"
        }
        let sessions = holds.enumerated().map { index, held in
            let padded: [Int?] = held.map { Optional($0) } + Array(repeating: nil, count: max(0, 6 - held.count))
            let best = held.max().map { String($0 * 1000) } ?? "null"
            let mean = held.isEmpty ? "null" : String(held.reduce(0, +) * 1000 / held.count)
            let recovery = held.max().map { String((240 - $0) * 1000) } ?? "null"
            let id = ids?[index] ?? "00000000-0000-4000-8000-00000000000\(index + 1)"
            return """
                {"id": "\(id)", "date": "2026-11-\(16 + index)", "round_s": 240, "rounds": 6,
                 "holds_ms": \(list(padded)), "best_ms": \(best), "mean_ms": \(mean),
                 "tightest_recovery_ms": \(recovery), "counts": \(held.count >= 3)}
                """
        }
        let counted = holds.filter { $0.count >= 3 }.count
        let last = lastHolds ?? (holds.last { $0.count >= 3 }.map { held in
            held.map { Optional($0) } + Array(repeating: nil, count: max(0, 6 - held.count))
        } ?? Array(repeating: nil, count: 6))
        let best = holds.flatMap { $0 }.max().map { String($0 * 1000) } ?? "null"
        return """
            {"target": 3, "done": \(counted), "remaining": \(max(0, 3 - counted)), "done_today": \(doneToday),
             "sessions": [\(sessions.joined(separator: ","))], "streak": \(streak),
             "table": {"round_s": \(roundS), "rounds": 6, "changed_from_s": \(changedFromS.map(String.init) ?? "null"),
                       "advance_under_s": 45, "step_s": 15, "last_holds_ms": \(list(last))},
             "best_ms": \(best)}
            """
    }

    /// Weight in exactly the shape the backend sends: `weights` are
    /// (date, value) pairs, oldest first, one a day; like the backend's,
    /// the average needs three of the last seven days.
    static func weight(_ weights: [(String, Double)] = [], unit: String = "kg", promptAt: String? = "06:30") -> String {
        func number(_ value: Double?) -> String { value.map { String($0) } ?? "null" }
        func average(upTo index: Int) -> Double? {
            let window = weights[max(0, index - 6)...index].map(\.1)
            guard window.count >= 3 else { return nil }
            return (window.reduce(0, +) / Double(window.count) * 100).rounded() / 100
        }
        let days = weights.enumerated().map { index, entry in
            #"{"date": "\#(entry.0)", "value": \#(entry.1), "average": \#(number(average(upTo: index)))}"#
        }
        let latest = weights.last.map { #"{"date": "\#($0.0)", "value": \#($0.1)}"# } ?? "null"
        let now = weights.isEmpty ? nil : average(upTo: weights.count - 1)
        let prompt = promptAt.map { "\"\($0)\"" } ?? "null"
        return #"""
            {"unit": "\#(unit)", "prompt_at": \#(prompt), "latest": \#(latest), "average": \#(number(now)),
             "days_weighed": \#(min(weights.count, 7)), "change": null, "change_pct": null,
             "days": [\#(days.joined(separator: ","))]}
            """#
    }

    static let breakfastID = UUID(uuidString: "00000000-0000-4000-9000-000000000001")!
    static let lunchID = UUID(uuidString: "00000000-0000-4000-9000-000000000002")!

    /// Food in exactly the shape the backend sends, on Tuesday 17 November.
    /// `logged` names the saved meals eaten today ("breakfast", "lunch"),
    /// each one portion. `lastDays` is one letter per day shown, today
    /// last: K kept, R recovered, A awaiting recovery, M missed, O open,
    /// B before the first log.
    static func food(
        logged: [String] = [], meals: Bool = true, target: Bool = true, days: Int = 0, state: String = "not_started",
        lastDays: String = "BBBBBBO", previousBest: Int = 0
    ) -> String {
        let recipes: [(key: String, id: UUID, name: String, kcal: Int, protein: Double, json: String)] = [
            (
                "breakfast", breakfastID, "Usual breakfast", 542, 43.1,
                """
                {"id": "00000000-0000-4000-9000-000000000001", "name": "Usual breakfast", "slot": "breakfast",
                 "portions": 1, "kcal": 542, "protein_g": 43.1,
                 "ingredients": [
                   {"name": "Oats", "grams": 80.0, "kcal_per_100g": 379.0, "protein_per_100g": 13.2},
                   {"name": "Milk 2%", "grams": 250.0, "kcal_per_100g": 50.4, "protein_per_100g": 3.4},
                   {"name": "Whey", "grams": 30.0, "kcal_per_100g": 377.0, "protein_per_100g": 80.0}]}
                """
            ),
            (
                "lunch", lunchID, "Batch lunch", 561, 49.0,
                """
                {"id": "00000000-0000-4000-9000-000000000002", "name": "Batch lunch", "slot": "lunch",
                 "portions": 5, "kcal": 561, "protein_g": 49.0,
                 "ingredients": [
                   {"name": "Chicken thigh", "grams": 900.0, "kcal_per_100g": 177.0, "protein_per_100g": 24.0},
                   {"name": "Rice, dry", "grams": 300.0, "kcal_per_100g": 360.0, "protein_per_100g": 7.0}]}
                """
            ),
        ]
        let eaten = recipes.filter { logged.contains($0.key) }
        let entries = eaten.enumerated().map { index, meal in
            """
            {"id": "00000000-0000-4000-8000-00000000010\(index + 1)", "slot": "\(meal.key)", "name": "\(meal.name)",
             "meal_id": "\(meal.id.uuidString.lowercased())", "servings": 1.0, "kcal": \(meal.kcal), "protein_g": \(meal.protein)}
            """
        }
        let kcal = eaten.reduce(0) { $0 + $1.kcal }
        let protein = (eaten.reduce(0) { $0 + $1.protein } * 10).rounded() / 10
        let open = ["breakfast", "lunch", "dinner"].filter { !logged.contains($0) }.map { "\"\($0)\"" }
        let states: [Character: String] = [
            "K": "kept", "R": "recovered", "A": "awaiting_recovery", "M": "missed", "O": "open", "B": "before",
        ]
        let marks = lastDays.enumerated().map { index, letter in
            #"{"date": "2026-11-\#(11 + index)", "state": "\#(states[letter]!)"}"#
        }
        let left = target ? "\(2500 - kcal)" : "null"
        let proteinLeft = target ? "\(((170 - protein) * 10).rounded() / 10)" : "null"
        return """
            {"day": "2026-11-17",
             "target": \(target ? #"{"since": "2026-11-02", "kcal": 2500, "protein_g": 170}"# : "null"),
             "kcal": \(kcal), "protein_g": \(protein), "kcal_left": \(left), "protein_left_g": \(proteinLeft),
             "open_slots": [\(open.joined(separator: ","))],
             "entries": [\(entries.joined(separator: ","))],
             "meals": [\(meals ? recipes.map(\.json).joined(separator: ",") : "")],
             "streak": {"days": \(days), "state": "\(state)", "previous_best": \(previousBest),
                        "logged_today": \(lastDays.last == "K"), "last_days": [\(marks.joined(separator: ","))]}}
            """
    }

    /// The same, read the way the app reads it.
    static func foodDay(
        logged: [String] = [], meals: Bool = true, target: Bool = true, days: Int = 0, state: String = "not_started",
        lastDays: String = "BBBBBBO", previousBest: Int = 0
    ) -> FoodDay {
        let json = food(
            logged: logged, meals: meals, target: target, days: days, state: state, lastDays: lastDays,
            previousBest: previousBest)
        return try! JSONDecoder.lyfe.decode(FoodDay.self, from: Data(json.utf8))
    }

    static func home(
        done: Int = 1, sources: String = Fixture.sources(), streak: String? = nil, today: String = "2026-11-17",
        serverReady: Bool? = nil, breath: String? = nil, weight: String? = nil, food: String? = nil
    ) -> String {
        let breathJSON =
            (breath.map { ", \"breath\": \($0)" } ?? "") + (weight.map { ", \"weight\": \($0)" } ?? "")
            + (food.map { ", \"food\": \($0)" } ?? "")
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
                      "sessions": [\(all.prefix(done).joined(separator: ","))]\(streakJSON)}\(breathJSON),
              "sources": \(sources)\(notifications)
            }
            """
    }

    static func snapshot(
        done: Int = 1, streak: String? = nil, today: String = "2026-11-17", breath: String? = nil
    ) -> HomeSnapshot {
        try! JSONDecoder.lyfe.decode(
            HomeSnapshot.self, from: Data(home(done: done, streak: streak, today: today, breath: breath).utf8))
    }

    /// A table of six 4:00 rounds, with last session's holds in seconds.
    static func table(lastHolds: [Int?] = Array(repeating: nil, count: 6), roundS: Int = 240) -> BreathTable {
        BreathTable(
            roundS: roundS, rounds: 6, advanceUnderS: 45, stepS: 15, lastHoldsMs: lastHolds.map { $0.map { $0 * 1000 } })
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
    let breath = BreathStore(directory: Fixture.temporaryDirectory())
    let weighIns = WeighInStore(directory: Fixture.temporaryDirectory())
    let food = FoodStore(directory: Fixture.temporaryDirectory())
    let captures = CaptureStore(directory: Fixture.temporaryDirectory())
    let clock = Date(timeIntervalSince1970: 1_795_000_000)
    /// The time the app sees; starts at `clock` and can be moved on.
    let time: TestClock

    init(token: String? = nil, address: String? = nil) {
        tokens = MemoryTokenStore(token: token)
        addresses = MemoryServerAddressStore(address: address)
        time = TestClock(clock)
    }

    /// A signed-in world with nothing cached.
    static func signedIn() -> World {
        World(token: "device-token", address: "lyfe.example.ts.net:8444")
    }

    func launch(transport: (any HTTPTransport)? = nil, ownerCheck: any OwnerCheck = NoOwnerCheck()) -> AppModel {
        let time = time
        return AppModel(
            tokens: tokens, addresses: addresses, cache: cache, breath: breath, weighIns: weighIns, food: food,
            captures: captures, transport: transport ?? backend,
            deviceName: "Test iPhone", ownerCheck: ownerCheck, now: { time.now })
    }
}

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) {
        value = start
    }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(seconds) }
    }
}

/// Cues that only remember what they were asked to do.
@MainActor
final class RecordingCues: BreathCues {
    var log: [String] = []
    func begin(_ run: BreathRun, now: Date) { log.append("begin") }
    func holdEnded() { log.append("holdEnded") }
    func beatLast() { log.append("beatLast") }
    func end(completed: Bool) { log.append("end \(completed)") }
}

/// Lets work started in the background finish, up to a limit.
@MainActor
func eventually(_ done: @MainActor () -> Bool) async {
    for _ in 0..<2000 where !done() {
        await Task.yield()
    }
}

/// A stand-in for Face ID: answers as told and counts how often it was asked.
final class StubOwnerCheck: OwnerCheck, @unchecked Sendable {
    private let lock = NSLock()
    private var answer: Bool
    private var available: Bool
    private var count = 0

    init(passes: Bool = true, available: Bool = true) {
        answer = passes
        self.available = available
    }

    var passes: Bool {
        get { lock.withLock { answer } }
        set { lock.withLock { answer = newValue } }
    }

    var asked: Int { lock.withLock { count } }
    var isAvailable: Bool { lock.withLock { available } }

    func confirm(reason: String) async -> Bool {
        lock.withLock {
            count += 1
            return answer
        }
    }
}
