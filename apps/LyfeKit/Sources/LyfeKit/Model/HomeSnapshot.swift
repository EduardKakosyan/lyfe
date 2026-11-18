import Foundation

/// What the backend says the Home screen should show. The backend decides
/// what counts; the app only displays this.
public struct HomeSnapshot: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var today: CalendarDay
    public var week: Week
    public var gym: GymWeek
    /// Missing in answers cached before breath sessions existed.
    public var breath: BreathWeek?
    /// Missing in answers cached before weigh-ins existed.
    public var weight: WeightTrend?
    public var sources: Sources
    /// Missing in answers cached before notifications existed.
    public var notifications: Notifications?

    public struct Notifications: Codable, Equatable, Sendable {
        /// False when the server has no Apple key and so cannot send any.
        public var serverReady: Bool
    }

    public struct Week: Codable, Equatable, Sendable {
        public var isoYear: Int
        public var isoWeek: Int
        public var startsOn: CalendarDay
        public var endsOn: CalendarDay
    }

    public struct GymWeek: Codable, Equatable, Sendable {
        /// Sessions a week needs to count.
        public var target: Int
        /// Days this week with a session; can exceed the target.
        public var done: Int
        public var remaining: Int
        /// Days left in the week, today included.
        public var daysLeft: Int
        public var sessions: [GymSession]
        /// Missing in answers cached before streaks existed.
        public var streak: GymStreak?
    }

    public typealias GymStreak = WeekStreak

    /// Breath training this week, the streak, and the table for the next
    /// session, as the backend decided them.
    public struct BreathWeek: Codable, Equatable, Sendable {
        /// Sessions a week needs to count.
        public var target: Int
        /// Days this week with a session that counts.
        public var done: Int
        public var remaining: Int
        /// Whether today already has a session that counts.
        public var doneToday: Bool
        /// Every session started this week, counted or not, oldest first.
        public var sessions: [BreathSession]
        public var streak: WeekStreak
        public var table: BreathTable
        /// The longest hold ever recorded.
        public var bestMs: Int?
    }

    /// A recorded breath session.
    public struct BreathSession: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var date: CalendarDay
        public var roundS: Int
        public var rounds: Int
        /// One entry per round; nil where no hold was recorded.
        public var holdsMs: [Int?]
        public var bestMs: Int?
        public var meanMs: Int?
        public var tightestRecoveryMs: Int?
        /// Whether it counts toward the week.
        public var counts: Bool
    }

    /// A weekly routine's streak as the backend counts it.
    public struct WeekStreak: Codable, Equatable, Sendable {
        /// Weeks in a row with the target met, counting this week once it is.
        public var weeks: Int
        public var state: State
        /// The longest streak that has ended; zero when none has.
        public var previousBest: Int
        /// Sessions this week still needs.
        public var remaining: Int
        /// Days from today to Sunday without a session yet.
        public var openDays: Int
        /// False once this week can no longer reach the target.
        public var reachable: Bool
        /// The most recent finished weeks, oldest first.
        public var recent: [PastWeek]

        public enum State: String, Codable, Sendable {
            /// No streak is alive; keeping this week starts one.
            case notStarted = "not_started"
            case onTrack = "on_track"
            /// Last week was missed; keeping this week recovers it.
            case recovering
            /// This week is already kept.
            case kept
        }

        public enum Mark: String, Codable, Sendable {
            case kept
            /// Missed, with this week still to decide whether it is recovered.
            case awaitingRecovery = "awaiting_recovery"
            case recovered
            case missed
        }

        public struct PastWeek: Codable, Equatable, Sendable, Identifiable {
            public var isoYear: Int
            public var isoWeek: Int
            public var startsOn: CalendarDay
            public var done: Int
            public var mark: Mark

            public var id: CalendarDay { startsOn }
        }
    }

    public struct GymSession: Codable, Equatable, Sendable, Identifiable {
        public var date: CalendarDay
        public var activityId: Int64
        public var activityType: String
        public var name: String?
        public var durationMin: Int

        public var id: Int64 { activityId }
    }
}

/// Weight as the backend worked it out: the day's weight is the last one
/// typed that day, and the seven-day average is the trend. Every figure is
/// in `unit`.
public struct WeightTrend: Codable, Equatable, Sendable {
    /// "kg" or "lb".
    public var unit: String
    /// When the morning prompt goes out ("06:30"); nil when it is off.
    public var promptAt: String?
    /// The most recent day with a weight.
    public var latest: Reading?
    /// The seven-day average as of today; nil while fewer than three of
    /// the seven days have a weight.
    public var average: Double?
    /// Days of the last seven, today included, with a weight.
    public var daysWeighed: Int
    /// The average now minus the average a week ago.
    public var change: Double?
    /// The same as a percentage of a week ago.
    public var changePct: Double?
    /// The last eight weeks, oldest first: every day with a weight or an
    /// average.
    public var days: [Day]

    public struct Reading: Codable, Equatable, Sendable {
        public var date: CalendarDay
        public var value: Double

        public init(date: CalendarDay, value: Double) {
            self.date = date
            self.value = value
        }
    }

    public struct Day: Codable, Equatable, Sendable, Identifiable {
        public var date: CalendarDay
        /// The weight typed that day.
        public var value: Double?
        /// The seven-day average as of that day.
        public var average: Double?

        public var id: CalendarDay { date }

        public init(date: CalendarDay, value: Double?, average: Double?) {
            self.date = date
            self.value = value
            self.average = average
        }
    }

    public init(
        unit: String, promptAt: String?, latest: Reading?, average: Double?, daysWeighed: Int, change: Double?,
        changePct: Double?, days: [Day]
    ) {
        self.unit = unit
        self.promptAt = promptAt
        self.latest = latest
        self.average = average
        self.daysWeighed = daysWeighed
        self.change = change
        self.changePct = changePct
        self.days = days
    }
}

/// The table lyfe set for a breath session: fixed rounds, each opened by a
/// hold taken as far as it goes.
public struct BreathTable: Codable, Equatable, Sendable {
    public var roundS: Int
    public var rounds: Int
    /// The last session's round length, when this table moved on from it.
    public var changedFromS: Int?
    /// The rounds get longer once a session's tightest recovery is under this.
    public var advanceUnderS: Int
    /// How much longer.
    public var stepS: Int
    /// The last session's hold in each round, to beat; nil where it had none.
    public var lastHoldsMs: [Int?]

    public init(
        roundS: Int, rounds: Int, changedFromS: Int? = nil, advanceUnderS: Int, stepS: Int, lastHoldsMs: [Int?]
    ) {
        self.roundS = roundS
        self.rounds = rounds
        self.changedFromS = changedFromS
        self.advanceUnderS = advanceUnderS
        self.stepS = stepS
        self.lastHoldsMs = lastHoldsMs
    }
}

public struct Sources: Codable, Equatable, Sendable {
    public var garmin: SourceStatus
}

public struct SourceStatus: Codable, Equatable, Sendable {
    public var state: State
    public var lastSuccessAt: Date?
    public var lastAttemptAt: Date?
    /// Why the last attempt failed, worded by the backend.
    public var message: String?

    public enum State: String, Codable, Sendable {
        case ok
        case failing
        case neverSynced = "never_synced"
        case notConfigured = "not_configured"
    }
}

/// A date without a time or zone, as the backend sends it ("2026-11-17").
public struct CalendarDay: Codable, Hashable, Sendable, Comparable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = CalendarDay(text) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected a date like 2026-11-17, got \(text)")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

extension CalendarDay: CustomStringConvertible {
    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static let weekdays = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
    private static let months = [
        "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC",
    ]

    /// "TUE", worked out from the date alone so it never shifts with the
    /// phone's time zone.
    public var weekdayLabel: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        guard let date = calendar.date(from: components) else { return "" }
        return Self.weekdays[calendar.component(.weekday, from: date) - 1]
    }

    /// "TUE 17 NOV"
    public var posterLabel: String {
        "\(weekdayLabel) \(day) \(Self.months[month - 1])"
    }

    /// "17 NOV"
    public var shortLabel: String {
        "\(day) \(Self.months[month - 1])"
    }

    /// Days since 1 January 1970, for placing days on a line.
    public var ordinal: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .distantPast
        return Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }
}

extension JSONDecoder {
    /// Decoder for backend responses: snake_case keys, ISO 8601 timestamps.
    public static var lyfe: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    public static var lyfe: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
