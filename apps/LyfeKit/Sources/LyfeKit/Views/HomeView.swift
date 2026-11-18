import SwiftUI

/// Home: the week, one band per routine, and the black bar with the next
/// thing to do. The gym fills itself in from the watch; the breath band
/// opens the next session.
public struct HomeView: View {
    let model: AppModel
    @State private var confirmingSignOut = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let home = model.home {
                ScrollView {
                    VStack(spacing: 0) {
                        header(home)
                        PosterRule()
                        TimelineView(.periodic(from: .now, by: 30)) { timeline in
                            SourceStrip(model: model, home: home, now: timeline.date)
                        }
                        PosterRule()
                        ForEach(notices, id: \.self) { notice in
                            NoticeRow(text: notice)
                            PosterRule()
                        }
                        GymBand(home: home)
                        PosterRule()
                        if let streak = home.gym.streak, !streak.recent.isEmpty || streak.previousBest > 0 {
                            StreakWeeks(streak: streak)
                            PosterRule()
                        }
                        if let breath = home.breath {
                            Button {
                                model.openBreathSession()
                            } label: {
                                VStack(spacing: 0) {
                                    BreathBand(home: home, breath: breath)
                                    PosterRule()
                                    BreathTableStrip(breath: breath)
                                    PosterRule()
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens the next breath session")
                            if !breath.streak.recent.isEmpty || breath.streak.previousBest > 0 {
                                StreakWeeks(streak: breath.streak)
                                PosterRule()
                            }
                        }
                        SessionRows(home: home)
                        signOutButton
                    }
                }
                .refreshable { await model.refresh() }
                NextBar(home: home) { model.openBreathSession() }
            } else {
                waiting
            }
        }
        .foregroundStyle(Poster.ink)
        .background(Poster.paper.ignoresSafeArea())
        .confirmationDialog("Sign out of lyfe on this device?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task { await model.signOut() }
            }
        }
    }

    /// Things the owner should know that are not about a routine's week.
    private var notices: [String] {
        var notices: [String] = []
        if let problem = model.notificationsProblem {
            notices.append(problem)
        }
        if let problem = model.breathProblem {
            notices.append(problem)
        } else if !model.unsentBreath.isEmpty {
            notices.append(HomeText.unsentBreath(model.unsentBreath.count))
        }
        return notices
    }

    private func header(_ home: HomeSnapshot) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: -8) {
                Text("WEEK")
                Text("\(home.week.isoWeek)").contentTransition(.numericText())
            }
            .font(.system(size: 38, weight: .heavy))
            .tracking(-1.6)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(home.today.posterLabel)
                Text("\(home.gym.daysLeft) \(home.gym.daysLeft == 1 ? "DAY" : "DAYS") LEFT")
            }
            .font(.system(size: 11, weight: .bold))
            .tracking(0.9)
        }
        .padding(.horizontal, Poster.margin)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var signOutButton: some View {
        Button {
            confirmingSignOut = true
        } label: {
            Text("Sign out").posterLabel().opacity(0.55)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 28)
    }

    /// Signed in, but nothing fetched or cached yet.
    private var waiting: some View {
        let stuck = model.isOffline || model.refreshProblem != nil
        return VStack(alignment: .leading, spacing: 10) {
            Spacer()
            Text(model.isOffline ? "NO\nSIGNAL" : "LYFE")
                .font(.system(size: 72, weight: .heavy))
                .tracking(-3)
            Text(waitingLine).posterLabel()
            Spacer()
            HStack {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Text("Try again").posterLabel()
                }
                .opacity(stuck && !model.isRefreshing ? 1 : 0)
                Spacer()
                Button {
                    confirmingSignOut = true
                } label: {
                    Text("Sign out").posterLabel().opacity(0.55)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(Poster.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var waitingLine: String {
        if model.isRefreshing { return "Fetching your week" }
        if model.isOffline { return "Can't reach the server: \(model.offlineReason ?? "the connection failed")." }
        return model.refreshProblem ?? "Fetching your week"
    }
}

/// Where the data comes from and how old it is.
struct SourceStrip: View {
    let model: AppModel
    let home: HomeSnapshot
    let now: Date

    var body: some View {
        let status = describe()
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                PosterSquare(state: status.mark, size: 10)
                Text(status.left).posterLabel()
                Spacer()
                Text(status.right).posterLabel()
            }
            if let detail = status.detail {
                Text(detail)
                    .posterLabel()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 7)
    }

    private func describe() -> (mark: MarkState, left: String, right: String, detail: String?) {
        let seen = model.homeFetchedAt.map { "LAST SEEN \(agoLabel(from: $0, to: now))" } ?? "NOT SEEN YET"
        if model.isOffline {
            return (.outline, "OFFLINE", seen, nil)
        }
        if let problem = model.refreshProblem {
            return (.striped, "SERVER", seen, problem)
        }
        let garmin = home.sources.garmin
        let synced = garmin.lastSuccessAt.map { "SYNCED \(agoLabel(from: $0, to: now))" }
        switch garmin.state {
        case .ok:
            return (.solid, "GARMIN", model.isRefreshing ? "CHECKING" : (synced ?? "SYNCED"), nil)
        case .failing:
            return (.striped, "GARMIN", synced ?? "NEVER SYNCED", garmin.message)
        case .neverSynced:
            return (.outline, "GARMIN", model.isRefreshing ? "CHECKING" : "NOT SYNCED YET", nil)
        case .notConfigured:
            return (.outline, "GARMIN", "NOT CONNECTED", "The server has no Garmin key file.")
        }
    }
}

/// Something the owner should know that is not about a routine.
struct NoticeRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            PosterSquare(state: .outline, size: 10).padding(.top, 1)
            Text(text).posterLabel()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 7)
    }
}

/// A routine's band: the streak as a giant numeral, this week's sessions
/// as squares, and stripes while the streak is in recovery.
struct RoutineBand: View {
    var name: String
    var colour: Color
    /// The darker stripe while in recovery.
    var shade: Color
    /// The colour of everything drawn on the band.
    var ink: Color
    var numeral: Int
    var recovering: Bool
    var lines: (headline: String, detail: String?)
    var target: Int
    var done: Int
    var spoken: String

    private static let height: CGFloat = 150

    var body: some View {
        // The numeral is far taller than the band and is cut off by it on
        // purpose, so it is laid over the band and never sizes it.
        colour
            .frame(height: Self.height)
            .overlay {
                if recovering {
                    Hatch(colour: shade)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text(Poster.tight("\(numeral)", by: numeral > 9 ? -8 : -10))
                    .font(.system(size: numeral > 9 ? 150 : 190, weight: .heavy))
                    .contentTransition(.numericText())
                    .fixedSize()
                    .padding(.trailing, 12)
                    .offset(y: numeral > 9 ? 36 : 46)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).posterHeading()
                    Text(lines.headline).posterLabel()
                    if let detail = lines.detail {
                        Text(detail).posterLabel()
                    }
                    HStack(spacing: 4) {
                        ForEach(0..<max(target, done), id: \.self) { index in
                            PosterSquare(state: index < done ? .solid : .outline)
                        }
                    }
                    .padding(.top, 6)
                }
                // Leaves the right of the band to the numeral.
                .frame(maxWidth: 190, alignment: .leading)
                .padding(.horizontal, Poster.margin)
                .padding(.top, 10)
            }
            .clipped()
            .foregroundStyle(ink)
            .animation(.snappy, value: done)
            .animation(.snappy, value: numeral)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
    }
}

/// The gym band, in red.
struct GymBand: View {
    let home: HomeSnapshot

    var body: some View {
        let gym = home.gym
        RoutineBand(
            name: "Gym", colour: Poster.red, shade: Poster.redShade, ink: Poster.ink,
            // The streak once the backend sends one; this week's count before that.
            numeral: gym.streak?.weeks ?? gym.done,
            recovering: gym.streak?.state == .recovering,
            lines: HomeText.gymLines(for: home), target: gym.target, done: gym.done,
            spoken: HomeText.gymSpoken(for: home))
    }
}

/// The breath band, in blue.
struct BreathBand: View {
    let home: HomeSnapshot
    let breath: HomeSnapshot.BreathWeek

    var body: some View {
        RoutineBand(
            name: "Breath", colour: Poster.blue, shade: Poster.blueShade, ink: Poster.paper,
            numeral: breath.streak.weeks, recovering: breath.streak.state == .recovering,
            lines: HomeText.weekLines(for: breath.streak, home: home), target: breath.target, done: breath.done,
            spoken: HomeText.spoken("Breath", streak: breath.streak, done: breath.done, target: breath.target))
    }
}

/// Under the breath band: the table for the next session, and the way in.
struct BreathTableStrip: View {
    let breath: HomeSnapshot.BreathWeek

    var body: some View {
        HStack {
            Text(HomeText.tableLabel(breath.table)).posterLabel()
            Spacer()
            Text(breath.doneToday ? "Again →" : "Start →").posterLabel()
        }
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

/// The finished weeks behind the streak: solid for kept, stripes for a
/// missed week that was or can still be recovered, outline for missed.
struct StreakWeeks: View {
    let streak: HomeSnapshot.WeekStreak

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(streak.recent) { week in
                    PosterSquare(state: HomeText.mark(for: week.mark), size: 12)
                }
            }
            if !streak.recent.isEmpty {
                Text(streak.recent.count == 1 ? "Last week" : "Last \(streak.recent.count) weeks").posterLabel()
            }
            Spacer(minLength: 0)
            if streak.previousBest > 0 {
                Text("Best \(streak.previousBest)").posterLabel()
            }
        }
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HomeText.weeksSpoken(for: streak))
    }
}

/// One line per session this week: gym sessions as the watch recorded
/// them, breath sessions with their best hold.
struct SessionRows: View {
    let home: HomeSnapshot

    var body: some View {
        let rows = HomeText.sessionRows(for: home)
        VStack(spacing: 0) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.day)
                        .font(.system(size: 15, weight: .heavy))
                        .frame(width: 44, alignment: .leading)
                    Text(row.label).posterLabel()
                    Spacer()
                    Text(row.value)
                        .font(.system(size: 15, weight: .heavy))
                        .monospacedDigit()
                }
                .padding(.horizontal, Poster.margin)
                .padding(.vertical, 9)
                .opacity(row.counts ? 1 : 0.45)
                PosterRule(thickness: 1.5)
            }
            if rows.isEmpty {
                Text("No sessions yet this week. Record one on your watch and it appears here.")
                    .posterLabel()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Poster.margin)
                    .padding(.vertical, 12)
            }
        }
    }
}

/// The black bar: the single next thing to do. When that is a breath
/// session, tapping the bar opens it.
struct NextBar: View {
    let home: HomeSnapshot
    var openBreath: () -> Void = {}

    var body: some View {
        let next = HomeText.next(for: home)
        Button {
            if next.opensBreath { openBreath() }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(next.small).posterLabel()
                    Text(next.big)
                        .font(.system(size: 22, weight: .heavy))
                        .tracking(-0.6)
                }
                Spacer()
                if next.opensBreath {
                    Text("→").font(.system(size: 32, weight: .heavy))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Poster.margin)
            .padding(.top, 15)
            .padding(.bottom, 10)
            .foregroundStyle(Poster.paper)
            .background(Poster.ink.ignoresSafeArea(edges: .bottom))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(next.opensBreath)
    }
}

/// The words on the Home screen that depend on the week's state. Plain
/// functions, so they can be checked without a screen.
enum HomeText {
    /// "strength_training" becomes "STRENGTH TRAINING".
    static func typeLabel(_ typeKey: String) -> String {
        typeKey.replacingOccurrences(of: "_", with: " ").uppercased()
    }

    static func weeksInARow(_ weeks: Int) -> String {
        weeks == 1 ? "WEEK IN A ROW" : "WEEKS IN A ROW"
    }

    /// "BY SUNDAY", or "TODAY" when today is the Sunday.
    static func deadline(for home: HomeSnapshot) -> String {
        home.today == home.week.endsOn ? "TODAY" : "BY SUNDAY"
    }

    /// "Yet" only until a first streak has existed.
    private static func noStreak(_ streak: HomeSnapshot.WeekStreak) -> String {
        streak.previousBest > 0 ? "STARTING AGAIN" : "NO STREAK YET"
    }

    /// The two lines under "GYM" in the band.
    static func gymLines(for home: HomeSnapshot) -> (headline: String, detail: String?) {
        guard let streak = home.gym.streak else { return ("SESSIONS THIS WEEK", nil) }
        return weekLines(for: streak, home: home)
    }

    /// The two lines under a routine's name in its band.
    static func weekLines(for streak: HomeSnapshot.WeekStreak, home: HomeSnapshot) -> (headline: String, detail: String?) {
        let more = "\(streak.remaining) MORE \(deadline(for: home))"
        switch (streak.state, streak.reachable) {
        case (.kept, _):
            return (weeksInARow(streak.weeks), "THIS WEEK DONE")
        case (.onTrack, true):
            return (weeksInARow(streak.weeks), more)
        case (.onTrack, false):
            return (weeksInARow(streak.weeks), "THIS WEEK IS OUT OF REACH")
        case (.recovering, true):
            return ("RECOVERING", more)
        case (.recovering, false):
            return ("RECOVERING", "THE STREAK ENDS SUNDAY")
        case (.notStarted, true):
            return (noStreak(streak), "\(more) STARTS ONE")
        case (.notStarted, false):
            return (noStreak(streak), "NEXT WEEK CAN START ONE")
        }
    }

    /// The band read aloud.
    static func gymSpoken(for home: HomeSnapshot) -> String {
        let gym = home.gym
        guard let streak = gym.streak else { return "Gym: \(gym.done) of \(gym.target) sessions this week" }
        return spoken("Gym", streak: streak, done: gym.done, target: gym.target)
    }

    static func spoken(_ name: String, streak: HomeSnapshot.WeekStreak, done: Int, target: Int) -> String {
        let week = "\(done) of \(target) sessions this week"
        let weeks = "\(streak.weeks) \(streak.weeks == 1 ? "week" : "weeks") in a row"
        switch streak.state {
        case .notStarted: return "\(name): no streak yet. \(week)."
        case .recovering: return "\(name): \(weeks), recovering. \(week)."
        case .onTrack, .kept: return "\(name): \(weeks). \(week)."
        }
    }

    static func mark(for mark: HomeSnapshot.WeekStreak.Mark) -> MarkState {
        switch mark {
        case .kept: .solid
        case .recovered, .awaitingRecovery: .striped
        case .missed: .outline
        }
    }

    static func weeksSpoken(for streak: HomeSnapshot.WeekStreak) -> String {
        let kept = streak.recent.filter { $0.mark == .kept }.count
        let recovered = streak.recent.filter { $0.mark == .recovered || $0.mark == .awaitingRecovery }.count
        let missed = streak.recent.filter { $0.mark == .missed }.count
        var parts = ["Last \(streak.recent.count) weeks: \(kept) kept, \(recovered) recovered, \(missed) missed"]
        if streak.previousBest > 0 {
            parts.append("Previous best \(streak.previousBest) weeks")
        }
        return parts.joined(separator: ". ")
    }

    /// "6 ROUNDS OF 4:00 · 25 MIN"
    static func tableLabel(_ table: BreathTable) -> String {
        "\(table.rounds) ROUNDS OF \(clockLabel(seconds: table.roundS)) · \(BreathRun.minutes(for: table)) MIN"
    }

    static func unsentBreath(_ count: Int) -> String {
        count == 1
            ? "1 breath session is saved on this phone. It is sent when the server can be reached."
            : "\(count) breath sessions are saved on this phone. They are sent when the server can be reached."
    }

    // MARK: This week's sessions

    struct SessionRow: Identifiable, Equatable {
        var id: String
        var date: CalendarDay
        var day: String
        var label: String
        var value: String
        /// False for a breath session too short to count; shown dimmed.
        var counts: Bool
    }

    /// Both routines' sessions this week, by day.
    static func sessionRows(for home: HomeSnapshot) -> [SessionRow] {
        var rows = home.gym.sessions.map { session in
            SessionRow(
                id: "gym-\(session.activityId)", date: session.date, day: session.date.weekdayLabel,
                label: typeLabel(session.activityType), value: "\(session.durationMin) MIN", counts: true)
        }
        rows += (home.breath?.sessions ?? []).map { session in
            SessionRow(
                id: "breath-\(session.id)", date: session.date, day: session.date.weekdayLabel,
                label: session.counts ? "BREATH" : "BREATH · TOO SHORT TO COUNT",
                value: session.bestMs.map { "BEST \(clockLabel(ms: $0))" } ?? "NO HOLD", counts: session.counts)
        }
        // Stable: a day's gym session stays above its breath session.
        return rows.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }.map(\.element)
    }

    // MARK: The black bar

    struct Next: Equatable {
        var small: String
        var big: String
        /// Tapping the bar opens the breath session.
        var opensBreath = false
    }

    /// How pressing a routine's next step is; the bar shows the most
    /// pressing one.
    private enum Urgency: Int {
        /// A session today would move the week on.
        case session
        /// The week cannot reach its target any more.
        case outOfReach
        /// Today's session is done and the week still needs more.
        case doneToday
        case weekDone
    }

    private struct Status {
        var name: String
        var urgency: Urgency
        /// Days to spare: open days beyond the sessions still needed.
        var slack: Int
        var remaining: Int
        var next: Next
    }

    /// What the black bar says with only the gym in view.
    static func nextAction(for home: HomeSnapshot) -> (small: String, big: String) {
        let next = next(for: home)
        return (next.small, next.big)
    }

    /// What the black bar says. With both routines it is whichever needs
    /// a session today most; the gym goes first when they need it equally,
    /// and gives way to breath once today's gym session is recorded.
    static func next(for home: HomeSnapshot) -> Next {
        let gym = gymStatus(for: home)
        guard let breath = home.breath else { return gym.next }
        let other = breathStatus(breath, home: home)
        let first = (other.urgency.rawValue, other.slack) < (gym.urgency.rawValue, gym.slack) ? other : gym
        switch first.urgency {
        case .session:
            return first.next
        case .outOfReach:
            return Next(small: "\(first.name) · \(first.next.small)", big: first.next.big)
        case .doneToday:
            let open = [gym, other].filter { $0.remaining > 0 }.map { "\($0.name) \($0.remaining) MORE" }
            return Next(small: "\(open.joined(separator: " · ")) \(deadline(for: home))", big: "DONE FOR TODAY")
        case .weekDone:
            return Next(small: "GYM \(home.gym.done) · BREATH \(breath.done) SESSIONS", big: "WEEK DONE")
        }
    }

    private static func gymStatus(for home: HomeSnapshot) -> Status {
        let gym = home.gym
        let slack = (gym.streak?.openDays ?? gym.daysLeft) - gym.remaining
        func status(_ urgency: Urgency, _ small: String, _ big: String) -> Status {
            Status(name: "GYM", urgency: urgency, slack: slack, remaining: gym.remaining, next: Next(small: small, big: big))
        }
        if gym.remaining == 0 {
            if let streak = gym.streak {
                return status(.weekDone, "\(streak.weeks) \(weeksInARow(streak.weeks)) · \(gym.done) SESSIONS", "GYM WEEK DONE")
            }
            return status(.weekDone, "WEEK \(home.week.isoWeek) · \(gym.done) SESSIONS", "GYM WEEK DONE")
        }
        if let streak = gym.streak, !streak.reachable {
            let lost = outOfReach(streak)
            return status(.outOfReach, lost.small, lost.big)
        }
        let trainedToday = gym.sessions.contains { $0.date == home.today }
        let small = "\(gym.remaining) MORE \(deadline(for: home))"
        if trainedToday {
            return status(.doneToday, small, "DONE FOR TODAY")
        }
        return status(.session, lead(gym.streak) + small, "GYM SESSION")
    }

    private static func breathStatus(_ breath: HomeSnapshot.BreathWeek, home: HomeSnapshot) -> Status {
        let streak = breath.streak
        func status(_ urgency: Urgency, _ next: Next) -> Status {
            Status(
                name: "BREATH", urgency: urgency, slack: streak.openDays - streak.remaining,
                remaining: breath.remaining, next: next)
        }
        if breath.remaining == 0 {
            return status(
                .weekDone,
                Next(small: "\(streak.weeks) \(weeksInARow(streak.weeks)) · \(breath.done) SESSIONS", big: "BREATH WEEK DONE"))
        }
        if !streak.reachable {
            let lost = outOfReach(streak)
            return status(.outOfReach, Next(small: lost.small, big: lost.big))
        }
        let small = "\(breath.remaining) MORE \(deadline(for: home))"
        if breath.doneToday {
            return status(.doneToday, Next(small: small, big: "DONE FOR TODAY"))
        }
        return status(
            .session,
            Next(
                small: "\(lead(streak))\(small) · \(BreathRun.minutes(for: breath.table)) MIN",
                big: "BREATH SESSION", opensBreath: true))
    }

    /// How a session that is still open is introduced.
    private static func lead(_ streak: HomeSnapshot.WeekStreak?) -> String {
        if let streak, streak.remaining == streak.openDays {
            // Every day left is needed, starting with this one.
            return "NEEDED TODAY · "
        }
        return streak?.state == .recovering ? "RECOVERY · " : "NEXT · "
    }

    private static func outOfReach(_ streak: HomeSnapshot.WeekStreak) -> (small: String, big: String) {
        switch streak.state {
        case .onTrack:
            ("THIS WEEK IS OUT OF REACH", "NEXT WEEK RECOVERS IT")
        case .recovering:
            ("THE STREAK ENDS SUNDAY", "START AGAIN MONDAY")
        case .notStarted, .kept:
            ("THIS WEEK IS OUT OF REACH", "START AGAIN MONDAY")
        }
    }
}
