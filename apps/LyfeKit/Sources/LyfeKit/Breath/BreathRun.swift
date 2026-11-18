import Foundation

/// One breath session on this phone, from the tap on START until it ends.
///
/// The rounds are fixed, so everything follows from the clock: round N
/// begins at `firstRoundAt` plus N-1 round lengths, whether or not the
/// screen is on or the app is running. The only thing the owner adds is
/// the tap that ends each hold. Where the session stands is always worked
/// out from the time, never counted up tick by tick, so a locked phone or
/// a relaunch cannot make it drift.
///
/// It captures and nothing more. What a session counts for, and the table
/// that follows it, are the backend's to decide.
public struct BreathRun: Codable, Equatable, Sendable, Identifiable {
    /// Made here, once. The backend stores a session by this id, so
    /// sending it again after a dropped connection cannot count it twice.
    public let id: UUID
    /// The table lyfe set, as last seen from the backend.
    public let table: BreathTable
    /// When the owner tapped START.
    public let startedAt: Date
    /// When the first round, and its hold, begins.
    public let firstRoundAt: Date
    /// One entry per round: the hold in milliseconds, nil while it has
    /// none. A round the owner never tapped in stays nil.
    public private(set) var holdsMs: [Int?]
    /// When the session ended: the tap in the last round, the end of the
    /// last round, or the owner stopping early. Nil while it runs.
    public private(set) var endedAt: Date?

    /// Seconds between START and the first hold.
    public static let leadIn: TimeInterval = 10
    /// A tap this soon after a round begins is taken for a slip of the
    /// finger and ignored.
    public static let earliestTap: TimeInterval = 1

    public init(id: UUID = UUID(), table: BreathTable, startedAt: Date) {
        self.id = id
        self.table = table
        self.startedAt = startedAt
        firstRoundAt = startedAt.addingTimeInterval(Self.leadIn)
        holdsMs = Array(repeating: nil, count: max(table.rounds, 0))
    }

    public enum Phase: Equatable, Sendable {
        /// Counting down to the first round.
        case leadIn(until: Date)
        /// Holding. `round` counts from 1.
        case hold(round: Int, since: Date, roundEnds: Date)
        /// The hold is over; breathing until the next round begins.
        case recover(round: Int, holdMs: Int, nextAt: Date)
        case finished
    }

    private var roundLength: TimeInterval { TimeInterval(table.roundS) }

    /// When the last round runs out.
    public var scheduleEnds: Date {
        firstRoundAt.addingTimeInterval(roundLength * Double(table.rounds))
    }

    /// When round `round` (counted from 1) begins.
    public func roundStart(_ round: Int) -> Date {
        firstRoundAt.addingTimeInterval(roundLength * Double(round - 1))
    }

    public func phase(at now: Date) -> Phase {
        if endedAt != nil || table.rounds <= 0 || table.roundS <= 0 { return .finished }
        let elapsed = now.timeIntervalSince(firstRoundAt)
        if elapsed < 0 { return .leadIn(until: firstRoundAt) }
        let index = Int(elapsed / roundLength)
        if index >= table.rounds { return .finished }
        let round = index + 1
        let roundEnds = roundStart(round + 1)
        if let holdMs = holdsMs[index] {
            return .recover(round: round, holdMs: holdMs, nextAt: roundEnds)
        }
        return .hold(round: round, since: roundStart(round), roundEnds: roundEnds)
    }

    /// The owner tapped: the hold in progress ends here. Returns whether a
    /// hold was recorded; a tap at any other moment does nothing.
    @discardableResult
    public mutating func tap(at now: Date) -> Bool {
        guard case .hold(let round, let since, _) = phase(at: now) else { return false }
        let held = now.timeIntervalSince(since)
        guard held >= Self.earliestTap else { return false }
        holdsMs[round - 1] = Int((held * 1000).rounded())
        if round == table.rounds {
            // Nothing follows the last hold, so the session is over.
            endedAt = now
        }
        return true
    }

    /// Ends the session once the last round has run out. Safe to call at
    /// any time.
    public mutating func settle(at now: Date) {
        if endedAt == nil, now >= scheduleEnds {
            endedAt = scheduleEnds
        }
    }

    /// The owner ended the session early. A hold in progress is dropped.
    public mutating func stop(at now: Date) {
        settle(at: now)
        if endedAt == nil {
            endedAt = max(now, startedAt)
        }
    }

    public var isFinished: Bool { endedAt != nil }

    /// The next moment something changes without a tap: a round begins,
    /// the hold passes last session's, or the session runs out.
    public func nextEvent(after now: Date) -> Date? {
        switch phase(at: now) {
        case .leadIn(let until):
            return until
        case .hold(let round, _, let roundEnds):
            if let beat = beatMoment(round: round), beat > now, beat < roundEnds { return beat }
            return roundEnds
        case .recover(_, _, let nextAt):
            return nextAt
        case .finished:
            return nil
        }
    }

    // MARK: What was recorded

    /// The last session's hold in a round (counted from 1), if it had one.
    public func holdToBeat(round: Int) -> Int? {
        guard table.lastHoldsMs.indices.contains(round - 1) else { return nil }
        return table.lastHoldsMs[round - 1]
    }

    /// When the hold of `round` passes the last session's hold in that round.
    public func beatMoment(round: Int) -> Date? {
        holdToBeat(round: round).map { roundStart(round).addingTimeInterval(Double($0) / 1000) }
    }

    /// Whether the hold recorded in `round` was longer than last session's.
    public func beat(round: Int) -> Bool {
        guard holdsMs.indices.contains(round - 1), let held = holdsMs[round - 1],
            let last = holdToBeat(round: round)
        else { return false }
        return held > last
    }

    /// The recorded holds, in round order.
    public var recorded: [(round: Int, holdMs: Int)] {
        holdsMs.enumerated().compactMap { index, hold in hold.map { (index + 1, $0) } }
    }

    public var roundsDone: Int { recorded.count }

    public var bestMs: Int? { recorded.map(\.holdMs).max() }

    public var meanMs: Int? {
        let holds = recorded.map(\.holdMs)
        guard !holds.isEmpty else { return nil }
        return Int((Double(holds.reduce(0, +)) / Double(holds.count)).rounded())
    }

    /// The least that was left of a round after its hold.
    public var tightestRecoveryMs: Int? {
        bestMs.map { max(0, table.roundS * 1000 - $0) }
    }

    /// The best hold of the session this table was set from.
    public var lastBestMs: Int? {
        table.lastHoldsMs.compactMap { $0 }.max()
    }

    /// Minutes from START to the end of the last round, rounded up.
    public static func minutes(for table: BreathTable) -> Int {
        Int(((leadIn + Double(table.roundS * table.rounds)) / 60).rounded(.up))
    }
}

/// A finished session in the shape the backend takes it.
struct BreathSessionUpload: Encodable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var roundS: Int
    var rounds: Int
    var holds: [Hold]

    struct Hold: Encodable {
        var round: Int
        var holdMs: Int
    }

    init(_ run: BreathRun) {
        id = run.id
        startedAt = run.startedAt
        endedAt = run.endedAt ?? run.scheduleEnds
        roundS = run.table.roundS
        rounds = run.table.rounds
        holds = run.recorded.map { Hold(round: $0.round, holdMs: min($0.holdMs, run.table.roundS * 1000)) }
    }
}

/// "2:12" for a duration in milliseconds, cut to whole seconds.
public func clockLabel(ms: Int) -> String {
    clockLabel(seconds: max(0, ms) / 1000)
}

/// "4:00" for a duration in seconds.
public func clockLabel(seconds: Int) -> String {
    let seconds = max(0, seconds)
    return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
}
