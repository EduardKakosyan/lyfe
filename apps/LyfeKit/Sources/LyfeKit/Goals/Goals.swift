import Foundation

/// Every goal, as the backend worked them out: active ones by date, then
/// parked ones, then ended ones, the most recent first.
public struct GoalsView: Codable, Equatable, Sendable {
    /// Goals that can be active at once.
    public var limit: Int
    public var goals: [Goal]

    public var active: [Goal] { goals.filter { $0.status == .active } }
    public var parked: [Goal] { goals.filter { $0.status == .parked } }
    public var ended: [Goal] { goals.filter { $0.status == .reached || $0.status == .dropped } }
}

/// What a goal reads. Its figures are in the reading's own unit: seconds,
/// grams, percent or minutes.
public enum GoalReading: String, Codable, Sendable, CaseIterable {
    case breathHold = "breath_hold"
    case weight
    case bodyFat = "body_fat"
    case studyMinutes = "study_minutes"
    /// An exam: its practice scores, and in the end its result.
    case exam
}

public enum GoalStatus: String, Codable, Sendable {
    case active, parked, reached, dropped
}

/// Where the owner means to get by a date, on a figure lyfe reads.
public struct Goal: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    /// `reach` (a figure, up or down), `total` (built up from nothing) or
    /// `result` (an exam).
    public var shape: String
    public var reading: GoalReading
    public var subjectId: UUID?
    public var subject: String?
    public var startOn: CalendarDay
    public var startValue: Double
    public var targetValue: Double
    public var dueOn: CalendarDay
    public var status: GoalStatus
    public var endedOn: CalendarDay?
    public var note: String?
    /// Days from today to the date; below zero once past it.
    public var daysLeft: Int
    /// The routine that moves it: `study`, `breath` or `gym_and_food`.
    public var movedBy: String
    /// Missing while lyfe has no reading for it, and for an exam.
    public var standing: Standing?
    public var changes: [Change]
    /// For an exam. Missing in answers cached before exams existed.
    public var exam: ExamView?

    public struct Standing: Codable, Equatable, Sendable {
        public var current: Double
        /// The share of the way from start to figure, 0 to 1.
        public var progress: Double
        /// Where the straight line from start to figure stands today.
        public var paceValue: Double
        /// How far ahead of the line; below zero is behind.
        public var aheadBy: Double
        /// What would now be needed each week to get there by the date.
        public var neededPerWeek: Double?
        /// What the line asks for each week.
        public var pacePerWeek: Double
        public var reached: Bool
    }

    public struct Change: Codable, Equatable, Sendable {
        public var on: CalendarDay
        /// `target`, `due`, `title` or `status`.
        public var what: String
        public var was: String
        public var now: String
    }
}

/// An exam as the backend worked it out: its own figures, the owner's rule
/// for being ready, practice, and how the last sitting went.
public struct ExamView: Codable, Equatable, Sendable {
    public var name: String
    public var scaleMax: Int
    public var passMark: Int
    /// The practice score that counts toward being ready.
    public var readyAt: Int
    public var readyRuns: Int
    public var validMonths: Int?
    public var result: Sitting?
    /// When a pass stops being valid, once passed.
    public var expiresOn: CalendarDay?
    /// The latest practice tests, oldest first.
    public var practice: [Practice]
    /// The latest tests in a row at the ready score.
    public var inARow: Int
    public var ready: Bool
    public var domains: [Domain]
    /// The part with the lowest latest figure.
    public var weakest: String?
    /// Minutes of study on its subject since it was set.
    public var minutes: Int

    public struct Sitting: Codable, Equatable, Sendable {
        /// `passed` or `failed`.
        public var outcome: String
        public var on: CalendarDay
        public var score: Int?
    }

    public struct Practice: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var takenOn: CalendarDay
        public var score: Int
        public var overReady: Bool
    }

    public struct Domain: Codable, Equatable, Sendable {
        public var name: String
        public var weightPct: Int
        public var latestPct: Int?
    }
}

/// A goal as the owner sets or changes it, in the reading's own unit.
public struct GoalRequest: Encodable, Equatable, Sendable {
    public var title: String?
    /// For a new goal only.
    public var reading: GoalReading?
    /// For a study or exam goal: the subject, or nil for all study.
    public var subject: String?
    /// Nil for an exam, whose figure is its pass mark.
    public var targetValue: Double?
    /// For an exam, the day it is sat.
    public var dueOn: CalendarDay
    public var exam: ExamRequest?

    public init(
        title: String?, reading: GoalReading?, subject: String?, targetValue: Double?, dueOn: CalendarDay,
        exam: ExamRequest? = nil
    ) {
        self.title = title
        self.reading = reading
        self.subject = subject
        self.targetValue = targetValue
        self.dueOn = dueOn
        self.exam = exam
    }
}

/// What an exam is held to, as its owner publishes it, and the owner's
/// rule for being ready to sit it.
public struct ExamRequest: Codable, Equatable, Sendable {
    public var name: String
    public var scaleMax: Int
    public var passMark: Int
    public var readyMargin: Int
    public var readyRuns: Int
    public var validMonths: Int?
    public var domains: [Part]

    public struct Part: Codable, Equatable, Sendable {
        public var name: String
        public var weightPct: Int

        public init(name: String, weightPct: Int) {
            self.name = name
            self.weightPct = weightPct
        }
    }

    public init(
        name: String, scaleMax: Int, passMark: Int, readyMargin: Int = 0, readyRuns: Int = 3, validMonths: Int? = nil,
        domains: [Part] = []
    ) {
        self.name = name
        self.scaleMax = scaleMax
        self.passMark = passMark
        self.readyMargin = readyMargin
        self.readyRuns = readyRuns
        self.validMonths = validMonths
        self.domains = domains
    }

    /// The figures an exam already set was given.
    public init(_ exam: ExamView) {
        self.init(
            name: exam.name, scaleMax: exam.scaleMax, passMark: exam.passMark, readyMargin: exam.readyAt - exam.passMark,
            readyRuns: exam.readyRuns, validMonths: exam.validMonths,
            domains: exam.domains.map { Part(name: $0.name, weightPct: $0.weightPct) })
    }

    /// Why the figures do not hang together, or nil when they do.
    public var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Name the exam." }
        if scaleMax < 1 || passMark < 1 || passMark > scaleMax { return "The pass mark is out of the score it is marked out of." }
        if passMark + readyMargin > scaleMax { return "The ready score is past what the exam is marked out of." }
        if !(1...10).contains(readyRuns) { return "Ready takes 1 to 10 tests in a row." }
        if domains.contains(where: { $0.name.trimmingCharacters(in: .whitespaces).isEmpty || !(1...100).contains($0.weightPct) }) {
            return "Each part needs a name and a share of 1 to 100%."
        }
        return nil
    }
}

/// A practice test as the owner types it.
public struct PracticeEntry: Encodable, Equatable, Sendable {
    public var id: UUID
    public var takenOn: CalendarDay
    public var score: Int
    public var domains: [Part]

    public struct Part: Encodable, Equatable, Sendable {
        public var name: String
        public var pct: Int
    }

    public init(id: UUID = UUID(), takenOn: CalendarDay, score: Int, domains: [Part] = []) {
        self.id = id
        self.takenOn = takenOn
        self.score = score
        self.domains = domains
    }
}

/// Words and figures for the goal screens, kept apart so they can be
/// tested without drawing anything. A goal's figures are stored in the
/// reading's own unit; these show them, and read what the owner types, in
/// the units the owner uses.
public enum GoalText {
    /// What a reading is called.
    public static func name(_ reading: GoalReading) -> String {
        switch reading {
        case .breathHold: "Breath hold"
        case .weight: "Weight"
        case .bodyFat: "Body fat"
        case .studyMinutes: "Study hours"
        case .exam: "Exam"
        }
    }

    /// The unit a figure is typed in.
    public static func unit(_ reading: GoalReading, weightUnit: String) -> String {
        switch reading {
        case .breathHold: "m:ss"
        case .weight: weightUnit
        case .bodyFat: "%"
        case .studyMinutes: "hours"
        case .exam: "points"
        }
    }

    static func grams(per unit: String) -> Double { unit == "kg" ? 1000 : 453.592_37 }

    /// A figure as shown: "3:00", "78.0 kg", "17.0%", "47.5 h".
    public static func figure(_ value: Double, _ reading: GoalReading, weightUnit: String) -> String {
        switch reading {
        case .breathHold:
            return StudyText.clock(value.rounded())
        case .weight:
            return String(format: "%.1f %@", value / grams(per: weightUnit), weightUnit)
        case .bodyFat:
            return String(format: "%.1f%%", value)
        case .studyMinutes:
            let hours = value / 60
            return hours >= 100 ? "\(Int(hours.rounded())) h" : String(format: "%.1f h", hours)
        case .exam:
            return "\(Int(value.rounded()))"
        }
    }

    /// The same, without the unit, for the giant figure.
    public static func bare(_ value: Double, _ reading: GoalReading, weightUnit: String) -> String {
        switch reading {
        case .breathHold: StudyText.clock(value.rounded())
        case .weight: String(format: "%.1f", value / grams(per: weightUnit))
        case .bodyFat: String(format: "%.1f", value)
        case .studyMinutes: String(format: "%.1f", value / 60)
        case .exam: "\(Int(value.rounded()))"
        }
    }

    /// Reads a figure the owner typed into the reading's own unit: "3:00"
    /// or "180" for a hold, a weight in the owner's unit, a percentage, or
    /// hours of study. Nil when it is not a figure.
    public static func parse(_ text: String, _ reading: GoalReading, weightUnit: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if reading == .breathHold, trimmed.contains(":") {
            let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let minutes = Int(parts[0]), let seconds = Int(parts[1]), (0..<60).contains(seconds)
            else { return nil }
            return Double(minutes * 60 + seconds)
        }
        guard let number = Double(trimmed), number.isFinite, number > 0 else { return nil }
        switch reading {
        case .breathHold: return number
        case .weight: return number * grams(per: weightUnit)
        case .bodyFat: return number
        case .studyMinutes: return number * 60
        case .exam: return number.rounded()
        }
    }

    /// How a goal stands against its pace, in a line.
    public static func pace(_ goal: Goal, weightUnit: String) -> String {
        guard let standing = goal.standing else { return "No reading yet" }
        if standing.reached { return "Reached" }
        let gap = figure(abs(standing.aheadBy), goal.reading, weightUnit: weightUnit)
        if abs(standing.aheadBy) < tolerance(goal.reading) { return "On the line" }
        return standing.aheadBy > 0 ? "\(gap) ahead of pace" : "\(gap) behind pace"
    }

    /// Below this a goal is taken to be on its line rather than off it.
    static func tolerance(_ reading: GoalReading) -> Double {
        switch reading {
        case .breathHold: 1
        case .weight: 50
        case .bodyFat: 0.05
        case .studyMinutes: 1
        case .exam: 1
        }
    }

    /// What would now be needed each week, in a line.
    public static func needed(_ goal: Goal, weightUnit: String) -> String? {
        guard let standing = goal.standing, let needed = standing.neededPerWeek else { return nil }
        let rate = figure(needed, goal.reading, weightUnit: weightUnit)
        let usual = figure(standing.pacePerWeek, goal.reading, weightUnit: weightUnit)
        return "\(rate) a week from now · the line asks \(usual)"
    }

    /// "3:00 by 1 Jun 2027"; for an exam, the day it is sat.
    public static func aim(_ goal: Goal, weightUnit: String) -> String {
        if goal.reading == .exam { return "Sat on \(date(goal.dueOn))" }
        return "\(figure(goal.targetValue, goal.reading, weightUnit: weightUnit)) by \(date(goal.dueOn))"
    }

    /// An exam's giant figure: days to it, or how it went.
    public static func countdown(_ goal: Goal) -> String {
        if let result = goal.exam?.result, result.outcome == "passed" { return "Passed" }
        if goal.daysLeft > 1 { return "\(goal.daysLeft) days" }
        if goal.daysLeft == 1 { return "Tomorrow" }
        if goal.daysLeft == 0 { return "Today" }
        return "Sat"
    }

    /// Where practice stands against the owner's rule for being ready.
    public static func readiness(_ exam: ExamView) -> String {
        if exam.ready { return "Ready · \(exam.readyRuns) in a row over \(exam.readyAt)" }
        let latest = exam.practice.last.map { "Practice \($0.score) · " } ?? "No practice yet · "
        return latest + "\(exam.inARow) of \(exam.readyRuns) over \(exam.readyAt)"
    }

    /// What became of a pass: how long it stays valid.
    public static func validity(_ exam: ExamView) -> String? {
        if let expires = exam.expiresOn { return "Valid until \(date(expires))" }
        return exam.validMonths.map { months in
            months % 12 == 0 ? "Valid \(months / 12) \(months == 12 ? "year" : "years") once passed" : "Valid \(months) months once passed"
        }
    }

    public static func date(_ day: CalendarDay) -> String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(day.day) \(months[max(0, min(11, day.month - 1))]) \(day.year)"
    }

    /// The routine that moves a goal, as the screens say it.
    public static func movedBy(_ goal: Goal, home: HomeSnapshot?) -> String {
        switch goal.movedBy {
        case "study":
            let week = home?.study.map { " · \($0.done) of \($0.target) this week" } ?? ""
            return "Moved by study\(week)"
        case "breath":
            let week = home?.breath.map { " · \($0.done) of \($0.target) this week" } ?? ""
            return "Moved by breath training\(week)"
        default:
            return "Moved by the gym and food"
        }
    }

    /// The left side of the Goals heading: "2 active · 1 parked".
    public static func count(_ goals: GoalsView) -> String {
        "\(goals.active.count) active · \(goals.parked.count) parked"
    }

    /// What a recorded change says.
    public static func change(_ change: Goal.Change, reading: GoalReading, weightUnit: String) -> String {
        func shown(_ text: String) -> String {
            guard let value = Double(text) else { return text }
            return figure(value, reading, weightUnit: weightUnit)
        }
        switch change.what {
        case "target": return "Figure \(shown(change.was)) → \(shown(change.now))"
        case "due": return "Date \(CalendarDay(change.was).map(date) ?? change.was) → \(CalendarDay(change.now).map(date) ?? change.now)"
        case "status": return "\(change.was.capitalized) → \(change.now.capitalized)"
        default: return "Renamed \(change.was) → \(change.now)"
        }
    }
}
