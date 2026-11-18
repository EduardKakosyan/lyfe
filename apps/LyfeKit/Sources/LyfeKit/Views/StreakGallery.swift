#if DEBUG
    import SwiftUI

    /// Every state the routine bands can be in, stacked, with made-up numbers.
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
                        if let food = sample.home.food {
                            FuelBand(food: food)
                            PosterRule()
                            StripRow(left: FoodText.homeLine(food), right: "Log →")
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
                breath: breath(for: state, openDays: openDays),
                food: FoodGallery.food(for: state),
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

    /// Progress and the weight entry with made-up numbers: a debug build
    /// shows one when launched with LYFE_DEBUG_PROGRESS set to `full`
    /// (eight weeks, some mornings missed), `new` (two weigh-ins), `empty`,
    /// `entry` or `kg`.
    public struct ProgressGallery: View {
        var screen: String

        public init(screen: String) {
            self.screen = screen
        }

        static let today = CalendarDay(year: 2026, month: 11, day: 18)

        public var body: some View {
            Group {
                if screen == "entry" {
                    WeighInView(
                        unit: "lb", latest: .init(date: CalendarDay(year: 2026, month: 11, day: 17), value: 181.2),
                        today: Self.today, onSave: { _ in .sent }, onClose: {})
                } else {
                    ProgressScreen(
                        weight: Self.weight(for: screen), today: Self.today, unsent: screen == "new" ? 1 : 0,
                        onBack: {}, onWeighIn: {})
                }
            }
            .preferredColorScheme(.light)
        }

        static func weight(for screen: String) -> WeightTrend? {
            switch screen {
            case "empty":
                return WeightTrend(
                    unit: "lb", promptAt: "06:30", latest: nil, average: nil, daysWeighed: 0, change: nil,
                    changePct: nil, days: [])
            case "new":
                return trend(from: [(1, 182.2), (0, 181.6)], unit: "lb")
            case "kg":
                return trend(from: eightWeeks(), unit: "kg")
            default:
                return trend(from: eightWeeks().map { ($0.0, $0.1 * 2.204_62) }, unit: "lb")
            }
        }

        /// Eight weeks drifting down about 0.4 kg a week, with the day to
        /// day noise of water and food, and a few mornings missed.
        static func eightWeeks() -> [(daysAgo: Int, value: Double)] {
            let noise = [0.3, -0.2, 0.5, 0.1, -0.4, 0.2, -0.1, 0.6, -0.3, 0.0, 0.4, -0.5, 0.2, 0.1]
            let missed: Set<Int> = [3, 9, 10, 17, 24, 25, 26, 33, 41, 48, 52]
            return (0..<56).reversed().compactMap { back in
                missed.contains(back) ? nil : (back, 82.2 + Double(back) * 0.057 + noise[back % noise.count])
            }
        }

        /// What the backend would send for these weights, worked out the
        /// same way: the average needs three of the last seven days.
        static func trend(from weights: [(daysAgo: Int, value: Double)], unit: String) -> WeightTrend {
            let byDay = Dictionary(uniqueKeysWithValues: weights.map { ($0.daysAgo, ($0.value * 10).rounded() / 10) })
            func average(_ back: Int) -> Double? {
                let window = (back..<(back + 7)).compactMap { byDay[$0] }
                return window.count >= 3 ? window.reduce(0, +) / Double(window.count) : nil
            }
            func day(_ back: Int) -> CalendarDay {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                let date = calendar.date(byAdding: .day, value: -back, to: calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 12))!)!
                let parts = calendar.dateComponents([.year, .month, .day], from: date)
                return CalendarDay(year: parts.year!, month: parts.month!, day: parts.day!)
            }
            let days = (0..<56).reversed().compactMap { back -> WeightTrend.Day? in
                let value = byDay[back]
                let mean = average(back)
                return value == nil && mean == nil ? nil : WeightTrend.Day(date: day(back), value: value, average: mean)
            }
            let latest = byDay.keys.min().map { WeightTrend.Reading(date: day($0), value: byDay[$0]!) }
            let now = average(0)
            let then = average(7)
            return WeightTrend(
                unit: unit, promptAt: "06:30", latest: latest, average: now,
                daysWeighed: (0..<7).filter { byDay[$0] != nil }.count,
                change: now.flatMap { now in then.map { now - $0 } },
                changePct: now.flatMap { now in then.map { (now - $0) / $0 * 100 } }, days: days)
        }
    }

    /// The food screens with made-up numbers: a debug build shows one when
    /// launched with LYFE_DEBUG_FOOD set to `day` (breakfast and lunch
    /// logged), `morning`, `done`, `over`, `recovering`, `offline`, `empty`
    /// (nothing set up yet), `editor`, `new` or `targets`.
    public struct FoodGallery: View {
        var screen: String

        public init(screen: String) {
            self.screen = screen
        }

        static let today = CalendarDay(year: 2026, month: 11, day: 17)
        static let target = FoodDay.Target(since: CalendarDay(year: 2026, month: 11, day: 2), kcal: 2500, proteinG: 170)

        static let breakfast = SavedMeal(
            id: UUID(uuidString: "00000000-0000-4000-9000-000000000001")!, name: "Usual breakfast", slot: .breakfast,
            portions: 1, kcal: 542, proteinG: 43.1,
            ingredients: [
                Ingredient(name: "Oats", grams: 80, kcalPer100g: 379, proteinPer100g: 13.2),
                Ingredient(name: "Milk 2%", grams: 250, kcalPer100g: 50.4, proteinPer100g: 3.4),
                Ingredient(name: "Whey", grams: 30, kcalPer100g: 377, proteinPer100g: 80),
            ])
        static let lunch = SavedMeal(
            id: UUID(uuidString: "00000000-0000-4000-9000-000000000002")!, name: "Batch lunch", slot: .lunch,
            portions: 5, kcal: 561, proteinG: 49,
            ingredients: [
                Ingredient(name: "Chicken thigh", grams: 900, kcalPer100g: 177, proteinPer100g: 24),
                Ingredient(name: "Rice, dry", grams: 300, kcalPer100g: 360, proteinPer100g: 7),
                Ingredient(name: "Olive oil", grams: 15, kcalPer100g: 884, proteinPer100g: 0),
                Ingredient(name: "Frozen vegetables", grams: 400, kcalPer100g: 0, proteinPer100g: 2),
            ])
        static let dinner = SavedMeal(
            id: UUID(uuidString: "00000000-0000-4000-9000-000000000003")!, name: "Salmon, potatoes, greens",
            slot: .dinner, portions: 2, kcal: 690, proteinG: 46.5,
            ingredients: [
                Ingredient(name: "Salmon", grams: 360, kcalPer100g: 208, proteinPer100g: 20),
                Ingredient(name: "Potatoes", grams: 700, kcalPer100g: 77, proteinPer100g: 2),
                Ingredient(name: "Butter", grams: 12, kcalPer100g: 717, proteinPer100g: 0.9),
            ])

        public var body: some View {
            Group {
                switch screen {
                case "editor":
                    MealEditorView(start: MealDraft(editing: Self.lunch), onSave: { _ in nil }, onRemove: { _ in nil }, onClose: {})
                case "new":
                    MealEditorView(start: MealDraft(), onSave: { _ in nil }, onRemove: { _ in nil }, onClose: {})
                case "targets":
                    FoodTargetsView(current: Self.target, today: Self.today, onSave: { _ in nil }, onClose: {})
                default:
                    FoodScreen(
                        food: Self.food(screen),
                        unsent: screen == "offline" ? [MealTap(eatenAt: Date(), meal: Self.lunch)] : [],
                        onBack: {}, onLog: { _, _ in }, onTakeBack: { _ in nil }, onEditMeal: { _ in }, onTargets: {})
                }
            }
            .preferredColorScheme(.light)
        }

        /// A fuel band to go with each gym sample on the streak gallery.
        static func food(for gym: HomeSnapshot.WeekStreak.State) -> FoodDay {
            switch gym {
            case .onTrack: food("day")
            case .recovering: food("recovering")
            case .kept: food("done")
            case .notStarted: food("empty")
            }
        }

        static func food(_ screen: String) -> FoodDay {
            typealias State = FoodDay.DayState
            func streak(
                _ days: Int, _ state: HomeSnapshot.WeekStreak.State, _ marks: [State], best: Int = 0
            ) -> FoodDay.DayStreak {
                .init(
                    days: days, state: state, previousBest: best, loggedToday: state == .kept,
                    lastDays: marks.enumerated().map { index, mark in
                        .init(date: CalendarDay(year: 2026, month: 11, day: 11 + index), state: mark)
                    })
            }
            func day(
                _ logged: [(SavedMeal, Double)], meals: [SavedMeal] = [breakfast, lunch, dinner],
                target: FoodDay.Target? = target, streak: FoodDay.DayStreak
            ) -> FoodDay {
                let entries = logged.enumerated().map { index, pair in
                    FoodDay.Entry(
                        id: UUID(uuidString: "00000000-0000-4000-9000-00000000010\(index)")!, slot: pair.0.slot,
                        name: pair.0.name, mealId: pair.0.id, servings: pair.1,
                        kcal: Int((Double(pair.0.kcal) * pair.1).rounded()),
                        proteinG: (pair.0.proteinG * pair.1 * 10).rounded() / 10)
                }
                let kcal = entries.reduce(0) { $0 + $1.kcal }
                let protein = (entries.reduce(0) { $0 + $1.proteinG } * 10).rounded() / 10
                return FoodDay(
                    day: today, target: target, kcal: kcal, proteinG: protein,
                    kcalLeft: target.map { $0.kcal - kcal },
                    proteinLeftG: target.map { ((Double($0.proteinG) - protein) * 10).rounded() / 10 },
                    openSlots: [.breakfast, .lunch, .dinner].filter { slot in !entries.contains { $0.slot == slot } },
                    entries: entries, meals: meals, streak: streak)
            }
            let week: [State] = Array(repeating: .kept, count: 6)
            switch screen {
            case "empty":
                return day(
                    [], meals: [], target: nil,
                    streak: streak(0, .notStarted, Array(repeating: .before, count: 6) + [.open]))
            case "morning":
                return day([], streak: streak(12, .onTrack, week + [.open]))
            case "done":
                return day([(breakfast, 1), (lunch, 1), (dinner, 1)], streak: streak(13, .kept, week + [.kept], best: 9))
            case "over":
                return day([(breakfast, 1), (lunch, 2), (dinner, 1.5)], streak: streak(13, .kept, week + [.kept]))
            case "recovering":
                return day(
                    [], streak: streak(12, .recovering, [.kept, .kept, .recovered, .kept, .kept, .awaitingRecovery, .open], best: 9))
            case "offline":
                return day([(breakfast, 1)], streak: streak(13, .kept, week + [.kept]))
            default:
                return day([(breakfast, 1), (lunch, 1)], streak: streak(13, .kept, week + [.kept]))
            }
        }
    }
#endif
