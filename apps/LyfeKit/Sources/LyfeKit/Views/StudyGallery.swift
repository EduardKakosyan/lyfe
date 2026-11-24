#if DEBUG
    import SwiftUI

    /// The study screens with made-up sessions, for looking at each state
    /// without timing one. A debug build shows it when launched with
    /// LYFE_DEBUG_STUDY set to `ready`, `first`, `build`, `running`,
    /// `counted`, `paused`, `after`, `explain`, `short` or `stopped`.
    public struct StudyGallery: View {
        var screen: String
        @State private var run: StudyRun?

        public init(screen: String) {
            self.screen = screen
            _run = State(initialValue: Self.run(for: screen))
        }

        static let week = StudyWeek(
            target: 4, done: 2, remaining: 2, doneToday: false, minutes: 184, builds: 1, sessions: [],
            streak: HomeSnapshot.WeekStreak(
                weeks: 5, state: .onTrack, previousBest: 3, remaining: 2, openDays: 5, reachable: true, recent: []),
            subjects: [
                StudySubject(
                    id: UUID(), name: "System design", minutes: 2850, sessions: 31,
                    last: CalendarDay(year: 2026, month: 11, day: 23)),
                StudySubject(
                    id: UUID(), name: "Local models", minutes: 1210, sessions: 14,
                    last: CalendarDay(year: 2026, month: 11, day: 21)),
                StudySubject(
                    id: UUID(), name: "Cloud certification", minutes: 2850, sessions: 30,
                    last: CalendarDay(year: 2026, month: 11, day: 19)),
            ],
            rules: StudyRules())

        public var body: some View {
            Group {
                if let run, run.isEnded {
                    StudyAfterView(
                        run: run, rules: StudyRules(), week: Self.week, onChange: { change in
                            if var changed = self.run {
                                change(&changed)
                                self.run = changed
                            }
                        }, onDone: {}, onDiscard: {})
                } else if let run {
                    StudyTimerView(
                        run: run, rules: StudyRules(), onPause: {}, onResume: {}, onEarlier: { _ in }, onEnd: {},
                        onSettle: {}, onDiscard: {}, onClose: {})
                } else {
                    StudyReadyView(
                        subjects: screen == "first" ? [] : Self.week.subjects.map(\.name), rules: StudyRules(),
                        week: screen == "first" ? nil : Self.week, onStart: { _, _ in }, onClose: {},
                        startingKind: screen == "build" ? .build : .questions)
                }
            }
            .foregroundStyle(Poster.ink)
            .preferredColorScheme(.light)
        }

        static func run(for screen: String) -> StudyRun? {
            let now = Date()
            func running(_ minutes: Double, kind: StudyKind = .questions) -> StudyRun {
                StudyRun(subject: "System design", kind: kind, startedAt: now.addingTimeInterval(-minutes * 60))
            }
            switch screen {
            case "running":
                return running(12.5)
            case "counted":
                return running(52.25)
            case "paused":
                var run = running(30)
                run.pause(at: now.addingTimeInterval(-60))
                return run
            case "after":
                var run = running(92)
                run.stop(at: now)
                run.answered = 12
                run.rightFirst = 8
                return run
            case "explain":
                var run = running(75, kind: .build)
                run.stop(at: now)
                return run
            case "short":
                var run = running(31, kind: .reading)
                run.stop(at: now)
                return run
            case "stopped":
                var run = running(300)
                run.settle(at: now, stopAfter: 3 * 3600)
                run.stoppedEarlier(by: 60 * 60)
                return run
            default:
                return nil
            }
        }
    }
#endif
