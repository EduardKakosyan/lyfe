import SwiftUI

/// Home: the week, one band per routine, and the black bar with the next
/// thing to do. In this first step there is one routine, the gym.
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
                        if let problem = model.notificationsProblem {
                            NoticeRow(text: problem)
                            PosterRule()
                        }
                        GymBand(home: home)
                        PosterRule()
                        if let streak = home.gym.streak, !streak.recent.isEmpty || streak.previousBest > 0 {
                            StreakWeeks(streak: streak)
                            PosterRule()
                        }
                        SessionRows(gym: home.gym)
                        signOutButton
                    }
                }
                .refreshable { await model.refresh() }
                NextBar(home: home)
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

/// The gym band: the streak as the screen's one giant numeral, this
/// week's sessions as squares, and stripes while the streak is in recovery.
struct GymBand: View {
    let home: HomeSnapshot

    private static let height: CGFloat = 150

    private var gym: HomeSnapshot.GymWeek { home.gym }
    /// The streak once the backend sends one; this week's count before that.
    private var numeral: Int { gym.streak?.weeks ?? gym.done }
    private var recovering: Bool { gym.streak?.state == .recovering }

    var body: some View {
        let lines = HomeText.gymLines(for: home)
        // The numeral is far taller than the band and is cut off by it on
        // purpose, so it is laid over the band and never sizes it.
        Poster.red
            .frame(height: Self.height)
            .overlay {
                if recovering {
                    Hatch(colour: Poster.redShade)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text("\(numeral)")
                    .font(.system(size: numeral > 9 ? 150 : 190, weight: .heavy))
                    .kerning(numeral > 9 ? -8 : -10)
                    .contentTransition(.numericText())
                    .fixedSize()
                    .padding(.trailing, numeral > 9 ? 14 : 22)
                    .offset(y: numeral > 9 ? 36 : 46)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Gym").posterHeading()
                    Text(lines.headline).posterLabel()
                    if let detail = lines.detail {
                        Text(detail).posterLabel()
                    }
                    HStack(spacing: 4) {
                        ForEach(0..<max(gym.target, gym.done), id: \.self) { index in
                            PosterSquare(state: index < gym.done ? .solid : .outline)
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
            .animation(.snappy, value: gym.done)
            .animation(.snappy, value: numeral)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(HomeText.gymSpoken(for: home))
    }
}

/// The finished weeks behind the streak: solid for kept, stripes for a
/// missed week that was or can still be recovered, outline for missed.
struct StreakWeeks: View {
    let streak: HomeSnapshot.GymStreak

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

/// One line per session this week, as recorded by the watch.
struct SessionRows: View {
    let gym: HomeSnapshot.GymWeek

    var body: some View {
        VStack(spacing: 0) {
            ForEach(gym.sessions) { session in
                HStack(alignment: .firstTextBaseline) {
                    Text(session.date.weekdayLabel)
                        .font(.system(size: 15, weight: .heavy))
                        .frame(width: 44, alignment: .leading)
                    Text(HomeText.typeLabel(session.activityType)).posterLabel()
                    Spacer()
                    Text("\(session.durationMin) MIN")
                        .font(.system(size: 15, weight: .heavy))
                        .monospacedDigit()
                }
                .padding(.horizontal, Poster.margin)
                .padding(.vertical, 9)
                PosterRule(thickness: 1.5)
            }
            if gym.sessions.isEmpty {
                Text("No sessions yet this week. Record one on your watch and it appears here.")
                    .posterLabel()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Poster.margin)
                    .padding(.vertical, 12)
            }
        }
    }
}

/// The black bar: the single next thing to do.
struct NextBar: View {
    let home: HomeSnapshot

    var body: some View {
        let next = HomeText.nextAction(for: home)
        VStack(alignment: .leading, spacing: 3) {
            Text(next.small).posterLabel()
            Text(next.big)
                .font(.system(size: 22, weight: .heavy))
                .tracking(-0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Poster.margin)
        .padding(.top, 15)
        .padding(.bottom, 10)
        .foregroundStyle(Poster.paper)
        .background(Poster.ink.ignoresSafeArea(edges: .bottom))
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
    private static func noStreak(_ streak: HomeSnapshot.GymStreak) -> String {
        streak.previousBest > 0 ? "STARTING AGAIN" : "NO STREAK YET"
    }

    /// The two lines under "GYM" in the band.
    static func gymLines(for home: HomeSnapshot) -> (headline: String, detail: String?) {
        guard let streak = home.gym.streak else { return ("SESSIONS THIS WEEK", nil) }
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
        let week = "\(gym.done) of \(gym.target) sessions this week"
        guard let streak = gym.streak else { return "Gym: \(week)" }
        let weeks = "\(streak.weeks) \(streak.weeks == 1 ? "week" : "weeks") in a row"
        switch streak.state {
        case .notStarted: return "Gym: no streak yet. \(week)."
        case .recovering: return "Gym: \(weeks), recovering. \(week)."
        case .onTrack, .kept: return "Gym: \(weeks). \(week)."
        }
    }

    static func mark(for mark: HomeSnapshot.GymStreak.Mark) -> MarkState {
        switch mark {
        case .kept: .solid
        case .recovered, .awaitingRecovery: .striped
        case .missed: .outline
        }
    }

    static func weeksSpoken(for streak: HomeSnapshot.GymStreak) -> String {
        let kept = streak.recent.filter { $0.mark == .kept }.count
        let recovered = streak.recent.filter { $0.mark == .recovered || $0.mark == .awaitingRecovery }.count
        let missed = streak.recent.filter { $0.mark == .missed }.count
        var parts = ["Last \(streak.recent.count) weeks: \(kept) kept, \(recovered) recovered, \(missed) missed"]
        if streak.previousBest > 0 {
            parts.append("Previous best \(streak.previousBest) weeks")
        }
        return parts.joined(separator: ". ")
    }

    /// What the black bar says.
    static func nextAction(for home: HomeSnapshot) -> (small: String, big: String) {
        let gym = home.gym
        if gym.remaining == 0 {
            if let streak = gym.streak {
                return ("\(streak.weeks) \(weeksInARow(streak.weeks)) · \(gym.done) SESSIONS", "GYM WEEK DONE")
            }
            return ("WEEK \(home.week.isoWeek) · \(gym.done) SESSIONS", "GYM WEEK DONE")
        }
        if let streak = gym.streak, !streak.reachable {
            switch streak.state {
            case .onTrack:
                return ("THIS WEEK IS OUT OF REACH", "NEXT WEEK RECOVERS IT")
            case .recovering:
                return ("THE STREAK ENDS SUNDAY", "START AGAIN MONDAY")
            case .notStarted, .kept:
                return ("THIS WEEK IS OUT OF REACH", "START AGAIN MONDAY")
            }
        }
        let trainedToday = gym.sessions.contains { $0.date == home.today }
        let small = "\(gym.remaining) MORE \(deadline(for: home))"
        if trainedToday {
            return (small, "DONE FOR TODAY")
        }
        if let streak = gym.streak, streak.remaining == streak.openDays {
            // Every day left is needed, starting with this one.
            return ("NEEDED TODAY · " + small, "GYM SESSION")
        }
        if gym.streak?.state == .recovering {
            return ("RECOVERY · " + small, "GYM SESSION")
        }
        return ("NEXT · " + small, "GYM SESSION")
    }
}
