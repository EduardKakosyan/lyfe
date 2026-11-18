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
                sources: Sources(garmin: SourceStatus(state: .ok, lastSuccessAt: Date(), lastAttemptAt: Date(), message: nil)),
                notifications: .init(serverReady: true))
        }
    }
#endif
