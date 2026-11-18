import Foundation

/// What the backend says the Home screen should show. The backend decides
/// what counts; the app only displays this.
public struct HomeSnapshot: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var today: CalendarDay
    public var week: Week
    public var gym: GymWeek
    public var sources: Sources

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
