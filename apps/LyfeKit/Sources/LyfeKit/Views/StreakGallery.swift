#if DEBUG
    import SwiftUI

    /// Every state the gym band can be in, stacked, with made-up numbers.
    /// For looking at the states real data has not reached yet; a debug
    /// build shows it when launched with LYFE_DEBUG_GALLERY set.
    public struct StreakGallery: View {
        /// Leaves out this many samples from the top, to see the ones below.
        var skipping: Int

        public init(skipping: Int = 0) {
            self.skipping = skipping
        }

        public var body: some View {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Self.samples.dropFirst(skipping), id: \.title) { sample in
                        Text(sample.title).posterLabel()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Poster.margin)
                            .padding(.vertical, 6)
                        PosterRule()
                        GymBand(home: sample.home)
                        PosterRule()
                        if let streak = sample.home.gym.streak, !streak.recent.isEmpty || streak.previousBest > 0 {
                            StreakWeeks(streak: streak)
                            PosterRule()
                        }
                        if let breath = sample.home.breath {
                            BreathBand(home: sample.home, breath: breath)
                            PosterRule()
                            BreathTableStrip(breath: breath)
                            PosterRule()
                            if !breath.streak.recent.isEmpty || breath.streak.previousBest > 0 {
                                StreakWeeks(streak: breath.streak)
                                PosterRule()
                            }
                        }
                        NextBar(home: sample.home)
                    }
                }
            }
            .foregroundStyle(Poster.ink)
            .background(Poster.paper.ignoresSafeArea())
            .preferredColorScheme(.light)
        }

        typealias Streak = HomeSnapshot.GymStreak

        static let samples: [(title: String, home: HomeSnapshot)] = [
            ("On track", home(done: 1, weeks: 6, state: .onTrack, openDays: 6, recent: "KKKKKK")),
            ("Recovering", home(done: 1, weeks: 5, state: .recovering, openDays: 6, recent: "KKKRKKA", best: 9)),
            ("Week kept, two digits", home(done: 4, weeks: 12, state: .kept, openDays: 3, recent: "KKKKKRKKKKKK")),
            ("No streak yet", home(done: 1, weeks: 0, state: .notStarted, openDays: 5, recent: "")),
            ("Ended, starting again", home(done: 2, weeks: 0, state: .notStarted, openDays: 4, recent: "KKKKMM", best: 4)),
            ("Out of reach", home(done: 1, weeks: 6, state: .onTrack, openDays: 2, recent: "KKKKKK")),
        ]

        static func home(done: Int, weeks: Int, state: Streak.State, openDays: Int, recent: String, best: Int = 0)
            -> HomeSnapshot
        {
            let monday = CalendarDay(year: 2026, month: 11, day: 16)
            let marks: [Character: Streak.Mark] = ["K": .kept, "R": .recovered, "A": .awaitingRecovery, "M": .missed]
            let past = recent.enumerated().map { index, letter in
                Streak.PastWeek(
                    isoYear: 2026, isoWeek: 47 - recent.count + index,
                    // Only used to tell the squares apart.
                    startsOn: CalendarDay(year: 2026, month: 1, day: index + 1),
                    done: letter == "K" ? 4 : 2, mark: marks[letter] ?? .missed)
            }
            let remaining = max(0, 4 - done)
            return HomeSnapshot(
                generatedAt: Date(),
                today: CalendarDay(year: 2026, month: 11, day: 23 - max(openDays, 1)),
                week: .init(isoYear: 2026, isoWeek: 47, startsOn: monday, endsOn: CalendarDay(year: 2026, month: 11, day: 22)),
                gym: .init(
                    target: 4, done: done, remaining: remaining, daysLeft: openDays, sessions: [],
                    streak: Streak(
                        weeks: weeks, state: state, previousBest: best, remaining: remaining, openDays: openDays,
                        reachable: remaining <= openDays, recent: past)),
                breath: breath(for: state, openDays: openDays),
                sources: Sources(garmin: SourceStatus(state: .ok, lastSuccessAt: Date(), lastAttemptAt: Date(), message: nil)),
                notifications: .init(serverReady: true))
        }

        /// A breath week to go with each gym sample, so both bands are seen
        /// together in more than one state.
        static func breath(for gym: Streak.State, openDays: Int) -> HomeSnapshot.BreathWeek {
            let (state, weeks, done, recent): (Streak.State, Int, Int, [Streak.Mark]) =
                switch gym {
                case .onTrack: (.recovering, 5, 1, [.kept, .kept, .kept, .kept, .kept, .awaitingRecovery])
                case .recovering: (.onTrack, 3, 2, [.kept, .recovered, .kept, .kept])
                case .kept: (.kept, 11, 3, Array(repeating: .kept, count: 10))
                case .notStarted: (.notStarted, 0, 0, [])
                }
            let past = recent.enumerated().map { index, mark in
                Streak.PastWeek(
                    isoYear: 2026, isoWeek: 47 - recent.count + index,
                    startsOn: CalendarDay(year: 2026, month: 2, day: index + 1), done: mark == .kept ? 3 : 2, mark: mark)
            }
            let remaining = max(0, 3 - done)
            return .init(
                target: 3, done: done, remaining: remaining, doneToday: false, sessions: [],
                streak: Streak(
                    weeks: weeks, state: state, previousBest: 0, remaining: remaining, openDays: openDays,
                    reachable: remaining <= openDays, recent: past),
                table: BreathGallery.table, bestMs: 132_000)
        }
    }

    /// The breath screens with made-up numbers, one at a time: a debug build
    /// shows one when launched with LYFE_DEBUG_BREATH set to `ready`,
    /// `leadin`, `hold`, `beaten`, `recover`, `done` or `offline`.
    public struct BreathGallery: View {
        var screen: String
        @State private var session: BreathSessionModel

        static let table = BreathTable(
            roundS: 240, rounds: 6, advanceUnderS: 45, stepS: 15,
            lastHoldsMs: [125_000, 125_000, 120_000, 118_000, 121_000, 119_000])

        public init(screen: String) {
            self.screen = screen
            _session = State(initialValue: Self.session(for: screen))
        }

        public var body: some View {
            Group {
                if let run = session.run {
                    if session.isFinished {
                        BreathDoneView(
                            run: run, breath: screen == "offline" ? nil : Self.answer(for: run),
                            unsent: screen == "offline", today: CalendarDay(year: 2026, month: 11, day: 17),
                            weekEnds: CalendarDay(year: 2026, month: 11, day: 22), onDone: {})
                    } else {
                        BreathTimerView(session: session, run: run, onEnd: {})
                    }
                } else {
                    BreathReadyView(session: session, onClose: {})
                }
            }
            .preferredColorScheme(.light)
            .onAppear { session.drive() }
        }

        /// A session placed in time so that right now it is where `screen` says.
        static func session(for screen: String) -> BreathSessionModel {
            let now = Date()
            func model(_ run: BreathRun?) -> BreathSessionModel {
                BreathSessionModel(table: table, resuming: run, cues: SilentCues(), onChange: { _ in }, onFinish: { _ in })
            }
            /// A run whose round 3 began `seconds` ago, with two holds recorded.
            func inRoundThree(_ seconds: TimeInterval) -> BreathRun {
                var run = BreathRun(table: table, startedAt: now.addingTimeInterval(-(10 + 480 + seconds)))
                run.tap(at: run.roundStart(1).addingTimeInterval(125))
                run.tap(at: run.roundStart(2).addingTimeInterval(132))
                return run
            }
            switch screen {
            case "leadin":
                return model(BreathRun(table: table, startedAt: now.addingTimeInterval(-3)))
            case "hold":
                return model(inRoundThree(74))
            case "beaten":
                return model(inRoundThree(123))
            case "recover":
                var run = inRoundThree(141)
                run.tap(at: run.roundStart(3).addingTimeInterval(128))
                return model(run)
            case "done", "offline":
                var run = BreathRun(table: table, startedAt: now.addingTimeInterval(-1500))
                for (index, seconds) in [125.0, 132, 120, 118, 121, 119].enumerated() {
                    run.tap(at: run.roundStart(index + 1).addingTimeInterval(seconds))
                }
                return model(run)
            default:
                return model(nil)
            }
        }

        /// What the backend would answer after `run`.
        static func answer(for run: BreathRun) -> HomeSnapshot.BreathWeek {
            let day = CalendarDay(year: 2026, month: 11, day: 17)
            return .init(
                target: 3, done: 2, remaining: 1, doneToday: true,
                sessions: [
                    .init(
                        id: run.id, date: day, roundS: 240, rounds: 6, holdsMs: run.holdsMs, bestMs: run.bestMs,
                        meanMs: run.meanMs, tightestRecoveryMs: run.tightestRecoveryMs, counts: true)
                ],
                streak: .init(
                    weeks: 5, state: .onTrack, previousBest: 0, remaining: 1, openDays: 5, reachable: true, recent: []),
                table: BreathTable(roundS: 240, rounds: 6, advanceUnderS: 45, stepS: 15, lastHoldsMs: run.holdsMs),
                bestMs: 132_000)
        }
    }
#endif
