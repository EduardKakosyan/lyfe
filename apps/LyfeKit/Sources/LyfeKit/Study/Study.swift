import Foundation

/// What a study session was spent on.
public enum StudyKind: String, Codable, Sendable, CaseIterable {
    /// Answering questions or problems, from memory.
    case questions
    case reading
    /// Building something; counts only with an explain-back.
    case build

    public var label: String {
        switch self {
        case .questions: "Questions"
        case .reading: "Reading"
        case .build: "Build"
        }
    }
}

/// Study this week, the streak, and the subjects, as the backend decided
/// them.
public struct StudyWeek: Codable, Equatable, Sendable {
    /// Days of study a week needs to count.
    public var target: Int
    /// Days this week with a session that counts.
    public var done: Int
    public var remaining: Int
    /// Whether today already has a session that counts.
    public var doneToday: Bool
    /// Minutes on the timer this week, counted or not.
    public var minutes: Int
    /// Build sessions that counted this week.
    public var builds: Int
    /// Every session started this week, oldest first.
    public var sessions: [StudySession]
    public var streak: HomeSnapshot.WeekStreak
    /// Most recently studied first.
    public var subjects: [StudySubject]
    public var rules: StudyRules
}

/// What the timer is held to.
public struct StudyRules: Codable, Equatable, Sendable {
    /// A session counts once its timer passes this.
    public var minMinutes: Int
    /// What a session aims at; shown, never required.
    public var targetMinutes: Int
    /// Build sessions that can count in a week.
    public var buildsPerWeek: Int
    /// A timer left running ends itself after this long.
    public var stopAfterMinutes: Int

    public init(minMinutes: Int = 45, targetMinutes: Int = 90, buildsPerWeek: Int = 2, stopAfterMinutes: Int = 180) {
        self.minMinutes = minMinutes
        self.targetMinutes = targetMinutes
        self.buildsPerWeek = buildsPerWeek
        self.stopAfterMinutes = stopAfterMinutes
    }
}

/// A recorded study session.
public struct StudySession: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var date: CalendarDay
    public var minutes: Int
    public var subject: String
    public var kind: StudyKind
    public var answered: Int?
    public var rightFirst: Int?
    /// Whether it counts toward the week.
    public var counts: Bool
    /// Why not, when it does not: `short`, `not_explained` or `builds_used`.
    public var notCounted: String?
}

/// A subject and the time given to it.
public struct StudySubject: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Every minute on the timer for it.
    public var minutes: Int
    public var sessions: Int
    /// The day it was last studied.
    public var last: CalendarDay
}

/// One study session on this phone, from START until the owner says what
/// it was.
///
/// Like a breath session, it is worked out from the clock and never counted
/// up tick by tick: the time on it is the time since START less any pause,
/// so a locked phone, another app or a relaunch cannot stop it or make it
/// drift. It captures and nothing more; whether it counts is the backend's
/// to decide.
public struct StudyRun: Codable, Equatable, Sendable, Identifiable {
    /// Made here, once. The backend stores a session by this id, so
    /// sending it again after a dropped connection cannot count it twice.
    public let id: UUID
    public var subject: String
    public var kind: StudyKind
    /// When the timer started, moved back if the owner says they started
    /// earlier.
    public private(set) var startedAt: Date
    /// How far the start has been moved back.
    public private(set) var movedBackS: TimeInterval
    /// When the pause in progress began; nil while the timer runs.
    public private(set) var pausedAt: Date?
    /// Seconds spent in pauses that are over.
    public private(set) var pausedS: TimeInterval
    /// Nil while the timer runs or is paused.
    public private(set) var endedAt: Date?
    /// True when the timer ended itself, having been left running.
    public private(set) var endedItself: Bool
    /// When it ended before being moved back: the latest the end can be.
    public private(set) var latestEnd: Date?
    public var answered: Int?
    public var rightFirst: Int?
    /// What was built and why, for a build session.
    public var explainBack: String

    /// The furthest back the start can be moved: a timer forgotten for
    /// longer than this is a different session.
    public static let longestMoveBack: TimeInterval = 2 * 3600

    public init(id: UUID = UUID(), subject: String, kind: StudyKind, startedAt: Date) {
        self.id = id
        self.subject = subject
        self.kind = kind
        self.startedAt = startedAt
        movedBackS = 0
        pausedS = 0
        endedItself = false
        explainBack = ""
    }

    public var isEnded: Bool { endedAt != nil }
    public var isPaused: Bool { pausedAt != nil && endedAt == nil }

    /// Seconds on the timer at `now`: from the start to the end, or to now
    /// while it runs, less every pause.
    public func activeSeconds(at now: Date) -> TimeInterval {
        let end = endedAt ?? now
        let pausing = pausedAt.map { max(0, end.timeIntervalSince($0)) } ?? 0
        return max(0, end.timeIntervalSince(startedAt) - pausedS - pausing)
    }

    public mutating func pause(at now: Date) {
        guard endedAt == nil, pausedAt == nil else { return }
        pausedAt = max(now, startedAt)
    }

    public mutating func resume(at now: Date) {
        guard endedAt == nil, let since = pausedAt else { return }
        pausedS += max(0, now.timeIntervalSince(since))
        pausedAt = nil
    }

    /// The owner started before tapping START. Moves the start back by
    /// `seconds`, no further than `longestMoveBack` in all.
    public mutating func startEarlier(by seconds: TimeInterval) {
        guard endedAt == nil else { return }
        let moved = min(max(0, seconds), Self.longestMoveBack - movedBackS)
        startedAt = startedAt.addingTimeInterval(-moved)
        movedBackS += moved
    }

    /// Ends the timer once it has been left past `stopAfter` seconds on it,
    /// or paused for that long, at the moment it got there. Safe to call at
    /// any time.
    public mutating func settle(at now: Date, stopAfter: TimeInterval) {
        guard endedAt == nil else { return }
        if let since = pausedAt {
            if now.timeIntervalSince(since) >= stopAfter {
                end(at: since, itself: true)
            }
            return
        }
        let over = activeSeconds(at: now) - stopAfter
        if over >= 0 {
            end(at: now.addingTimeInterval(-over), itself: true)
        }
    }

    /// The owner ended the session.
    public mutating func stop(at now: Date) {
        guard endedAt == nil else { return }
        end(at: max(now, startedAt), itself: false)
    }

    private mutating func end(at moment: Date, itself: Bool) {
        if let since = pausedAt {
            pausedS += max(0, moment.timeIntervalSince(since))
            pausedAt = nil
        }
        endedAt = moment
        latestEnd = moment
        endedItself = itself
    }

    /// The owner says they stopped `seconds` before the timer did, for one
    /// left running. Never before the start or after where it ended.
    public mutating func stoppedEarlier(by seconds: TimeInterval) {
        guard let latest = latestEnd else { return }
        let earliest = startedAt.addingTimeInterval(pausedS)
        endedAt = max(earliest, latest.addingTimeInterval(-max(0, seconds)))
    }

    /// How much earlier than the timer the owner said they stopped.
    public var stoppedEarlierBy: TimeInterval {
        guard let latest = latestEnd, let endedAt else { return 0 }
        return latest.timeIntervalSince(endedAt)
    }

    /// Whether it will count, as far as this phone can tell: long enough,
    /// and for a build session, explained. How many builds the week has
    /// already counted is the backend's to know.
    public func wouldCount(rules: StudyRules, at now: Date) -> Bool {
        activeSeconds(at: now) >= Double(rules.minMinutes * 60)
            && (kind != .build || !explainBack.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

/// A finished session in the shape the backend takes it.
struct StudySessionUpload: Encodable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var activeS: Int
    var subject: String
    var kind: StudyKind
    var answered: Int?
    var rightFirst: Int?
    var explainBack: String?

    init(_ run: StudyRun) {
        let ended = run.endedAt ?? run.startedAt
        id = run.id
        startedAt = run.startedAt
        endedAt = ended
        activeS = Int(run.activeSeconds(at: ended).rounded(.down))
        subject = run.subject
        kind = run.kind
        answered = run.answered.map { min(max($0, 0), 1000) }
        rightFirst = answered.flatMap { answered in run.rightFirst.map { min(max($0, 0), answered) } }
        let explained = run.explainBack.trimmingCharacters(in: .whitespacesAndNewlines)
        explainBack = explained.isEmpty ? nil : String(explained.prefix(4000))
    }
}

/// Study sessions kept on this phone: the one in progress, and the
/// finished ones the backend has not confirmed yet.
///
/// The session is written here when it starts and whenever it changes, so
/// closing the app or losing the connection never loses the time on it. A
/// finished session stays in the outbox until the backend has answered for
/// it.
public struct StudyStore: Sendable {
    private let activeFile: URL
    private let outboxFile: URL

    public init(directory: URL) {
        activeFile = directory.appending(path: "study-active.json")
        outboxFile = directory.appending(path: "study-outbox.json")
    }

    /// The app's own Application Support folder.
    public static func standard() -> StudyStore {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return StudyStore(directory: base.appending(path: "lyfe"))
    }

    public func loadActive() -> StudyRun? {
        read(StudyRun.self, from: activeFile)
    }

    public func saveActive(_ run: StudyRun) {
        write(run, to: activeFile)
    }

    public func clearActive() {
        try? FileManager.default.removeItem(at: activeFile)
    }

    /// Oldest first.
    public func outbox() -> [StudyRun] {
        read([StudyRun].self, from: outboxFile) ?? []
    }

    public func enqueue(_ run: StudyRun) {
        var runs = outbox()
        guard !runs.contains(where: { $0.id == run.id }) else { return }
        runs.append(run)
        write(runs, to: outboxFile)
    }

    /// Called once the backend has confirmed a session.
    public func remove(_ id: UUID) {
        let runs = outbox().filter { $0.id != id }
        if runs.isEmpty {
            try? FileManager.default.removeItem(at: outboxFile)
        } else {
            write(runs, to: outboxFile)
        }
    }

    private func read<Value: Decodable>(_ type: Value.Type, from file: URL) -> Value? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(type, from: data)
    }

    private func write<Value: Encodable>(_ value: Value, to file: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Words and figures for the study screens, kept apart so they can be
/// tested without drawing anything.
public enum StudyText {
    /// "52:14" under an hour, "1:32:10" from an hour on.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let (hours, minutes, rest) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0
            ? "\(hours):" + String(format: "%02d:%02d", minutes, rest)
            : "\(minutes):" + String(format: "%02d", rest)
    }

    /// "1:32" for a length in minutes: hours and minutes.
    public static func hoursMinutes(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds.rounded(.down)) / 60)
        return "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }

    /// What the line over the running timer says.
    public static func counting(_ active: TimeInterval, rules: StudyRules) -> String {
        let minimum = Double(rules.minMinutes * 60)
        return active >= minimum
            ? "Counted · \(clock(minimum)) passed"
            : "Counts at \(clock(minimum)) · \(clock(minimum - active)) to go"
    }

    /// The small line in the black bar while the timer runs.
    public static func toTarget(_ active: TimeInterval, rules: StudyRules) -> String {
        let target = Double(rules.targetMinutes * 60)
        return active >= target ? "Target passed · end when you like" : "\(clock(target - active)) to the target"
    }

    /// Why a recorded session did not count.
    public static func notCounted(_ reason: String?, rules: StudyRules) -> String? {
        switch reason {
        case nil: nil
        case "short": "Under \(rules.minMinutes) min"
        case "not_explained": "Build, not explained"
        case "builds_used": "\(rules.buildsPerWeek) builds already counted"
        default: "Not counted"
        }
    }

    /// Home's caption for the study row.
    public static func homeCaption(_ week: StudyWeek?, running: StudyRun?, now: Date) -> String {
        if let running, running.isEnded {
            return "Session ended · say what it was"
        }
        if let running {
            let time = clock(running.activeSeconds(at: now))
            return running.isPaused ? "Paused · \(time)" : "Running · \(time)"
        }
        guard let week else { return "Start a session" }
        return week.doneToday ? "This week · done today" : "This week · start session"
    }

    /// Home's figure for the study row: the time on a running timer,
    /// otherwise the week's days against its target.
    public static func homeFigure(_ week: StudyWeek?, running: StudyRun?, now: Date) -> String {
        if let running, !running.isEnded {
            return clock(running.activeSeconds(at: now))
        }
        guard let week else { return "—" }
        return "\(week.done)/\(week.target)"
    }

    /// What the study screen says about build sessions.
    public static func buildNote(rules: StudyRules, week: StudyWeek?) -> String {
        let used = week?.builds ?? 0
        return "A build counts once you say what you built and why, from memory. \(used) of \(rules.buildsPerWeek) counted this week."
    }

    /// How far back the start can still be moved, in minutes.
    public static func earlierChoices(movedBack: TimeInterval) -> [Int] {
        let left = Int((StudyRun.longestMoveBack - movedBack) / 60)
        return [10, 15, 30, 45, 60, 90, 120].filter { $0 <= left }
    }

    /// The line over an ended session's figure: whether it will count, as
    /// far as this phone can tell.
    public static func verdict(_ run: StudyRun, rules: StudyRules) -> String {
        let ended = run.endedAt ?? run.startedAt
        if run.activeSeconds(at: ended) < Double(rules.minMinutes * 60) {
            return "Under \(rules.minMinutes) min · kept, not counted"
        }
        return run.wouldCount(rules: rules, at: ended) ? "Study · counts" : "Study · counts once explained"
    }

    /// The small line over DONE.
    public static func barNote(_ run: StudyRun, rules: StudyRules) -> String {
        switch run.kind {
        case .build:
            run.wouldCount(rules: rules, at: run.endedAt ?? run.startedAt)
                ? "Kept and sent" : "Say what you built, or keep it uncounted"
        case .questions: "The figures can be left blank"
        case .reading: "Kept and sent"
        }
    }

    public static func unsent(_ count: Int) -> String {
        count == 1
            ? "1 study session is saved on this phone. It is sent when the server can be reached."
            : "\(count) study sessions are saved on this phone. They are sent when the server can be reached."
    }
}
