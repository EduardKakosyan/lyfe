#if DEBUG
    import SwiftUI

    /// The goal screens with made-up goals, for looking at each state. A
    /// debug build shows it when launched with LYFE_DEBUG_GOALS set to
    /// `list`, `empty`, `detail`, `behind`, `parked`, `exam`, `ready`,
    /// `passed`, `change`, `examchange` or `new`.
    public struct GoalsGallery: View {
        var screen: String

        public init(screen: String) {
            self.screen = screen
        }

        static let today = CalendarDay(year: 2026, month: 11, day: 24)

        static func goal(
            _ n: Int, _ title: String, _ reading: GoalReading, start: Double, target: Double, current: Double?,
            pace: Double, status: GoalStatus = .active, movedBy: String, due: CalendarDay, subject: String? = nil
        ) -> Goal {
            let span = target - start
            let direction: Double = span < 0 ? -1 : 1
            return Goal(
                id: UUID(uuidString: "00000000-0000-4000-c000-00000000000\(n)")!, title: title,
                shape: reading == .studyMinutes ? "total" : "reach", reading: reading, subjectId: nil, subject: subject,
                startOn: CalendarDay(year: 2026, month: 10, day: 5), startValue: start, targetValue: target, dueOn: due,
                status: status, endedOn: status == .reached ? CalendarDay(year: 2026, month: 10, day: 30) : nil,
                note: nil, daysLeft: due.ordinal - today.ordinal, movedBy: movedBy,
                standing: current.map { current in
                    Goal.Standing(
                        current: current, progress: max(0, min(1, (current - start) / span)), paceValue: pace,
                        aheadBy: (current - pace) * direction, neededPerWeek: abs(target - current) / 30,
                        pacePerWeek: abs(span) / 40, reached: (current - target) * direction >= 0)
                },
                changes: n == 2 ? [Goal.Change(on: CalendarDay(year: 2026, month: 11, day: 3), what: "due", was: "2027-04-01", now: "2027-06-01")] : [])
        }

        static func exam(scores: [Int], passed: Bool = false) -> Goal {
            var exam = goal(
                6, "Solutions architect", .exam, start: 0, target: 720, current: nil, pace: 0,
                status: passed ? .reached : .active, movedBy: "study", due: CalendarDay(year: 2027, month: 1, day: 4),
                subject: "Cloud certification")
            exam.shape = "result"
            exam.exam = ExamView(
                name: "Solutions architect", scaleMax: 1000, passMark: 720, readyAt: 750, readyRuns: 3, validMonths: 36,
                result: passed ? .init(outcome: "passed", on: CalendarDay(year: 2027, month: 1, day: 4), score: 801) : nil,
                expiresOn: passed ? CalendarDay(year: 2030, month: 1, day: 4) : nil,
                practice: scores.enumerated().map { index, score in
                    .init(
                        id: UUID(), takenOn: CalendarDay(year: 2026, month: 11, day: 10 + index * 3), score: score,
                        overReady: score >= 750)
                },
                inARow: scores.reversed().prefix { $0 >= 750 }.count,
                ready: scores.count >= 3 && scores.suffix(3).allSatisfy { $0 >= 750 },
                domains: [
                    .init(name: "Secure", weightPct: 30, latestPct: 78),
                    .init(name: "Resilient", weightPct: 26, latestPct: 71),
                    .init(name: "High-performing", weightPct: 24, latestPct: 64),
                    .init(name: "Cost-optimized", weightPct: 20, latestPct: 80),
                ],
                weakest: "High-performing", minutes: 2850)
            return exam
        }

        static let goals = GoalsView(
            limit: 3,
            goals: [
                exam(scores: [640, 705, 745]),
                goal(
                    1, "Cloud certification hours", .studyMinutes, start: 0, target: 4800, current: 2850, pace: 2700,
                    movedBy: "study", due: CalendarDay(year: 2027, month: 1, day: 4), subject: "Cloud certification"),
                goal(
                    2, "Three-minute hold", .breathHold, start: 125, target: 180, current: 140, pace: 144,
                    movedBy: "breath", due: CalendarDay(year: 2027, month: 6, day: 1)),
                goal(
                    3, "Lighter by spring", .weight, start: 84_000, target: 78_000, current: 81_400, pace: 82_100,
                    status: .parked, movedBy: "gym_and_food", due: CalendarDay(year: 2027, month: 4, day: 1)),
                goal(
                    4, "Body fat", .bodyFat, start: 21, target: 17, current: 20.4, pace: 20.6, status: .parked,
                    movedBy: "gym_and_food", due: CalendarDay(year: 2027, month: 9, day: 1)),
                goal(
                    5, "Two-minute hold", .breathHold, start: 95, target: 120, current: 132, pace: 120, status: .reached,
                    movedBy: "breath", due: CalendarDay(year: 2026, month: 11, day: 1)),
            ])

        public var body: some View {
            Group {
                switch screen {
                case "empty":
                    GoalsScreen(goals: GoalsView(limit: 3, goals: []), home: nil, weightUnit: "kg", onOpen: { _ in }, onNew: {})
                case "exam", "ready", "passed":
                    GoalDetailView(
                        goal: screen == "exam"
                            ? Self.exam(scores: [640, 705, 745])
                            : Self.exam(scores: [640, 760, 755, 790], passed: screen == "passed"),
                        goals: Self.goals, home: nil, weightUnit: "kg", today: Self.today, onChange: {},
                        onStatus: { _, _ in nil }, onBack: {})
                case "examchange":
                    GoalEditorView(
                        existing: Self.exam(scores: [640]), home: nil, weightUnit: "kg",
                        subjects: ["System design", "Cloud certification"], today: Self.today, onSave: { _ in nil },
                        onClose: {})
                case "detail", "behind", "parked":
                    let goal = Self.goals.goals[screen == "detail" ? 1 : screen == "behind" ? 2 : 4]
                    GoalDetailView(
                        goal: goal, goals: Self.goals, home: nil, weightUnit: "kg", today: Self.today, onChange: {},
                        onStatus: { _, _ in nil },
                        onBack: {})
                case "change", "new":
                    GoalEditorView(
                        existing: screen == "change" ? Self.goals.goals[2] : nil, home: nil, weightUnit: "kg",
                        subjects: ["System design", "Cloud certification"], today: Self.today, onSave: { _ in nil },
                        onClose: {})
                default:
                    GoalsScreen(goals: Self.goals, home: nil, weightUnit: "kg", onOpen: { _ in }, onNew: {})
                }
            }
            .preferredColorScheme(.light)
        }
    }
#endif
