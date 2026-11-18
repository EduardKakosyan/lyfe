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
                        GymBand(gym: home.gym)
                        PosterRule()
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

/// The gym band: this week's sessions as squares, and the count as the
/// screen's one giant numeral.
struct GymBand: View {
    let gym: HomeSnapshot.GymWeek

    private static let height: CGFloat = 150

    var body: some View {
        // The numeral is far taller than the band and is cut off by it on
        // purpose, so it is laid over the band and never sizes it.
        Poster.red
            .frame(height: Self.height)
            .overlay(alignment: .bottomTrailing) {
                Text("\(gym.done)")
                    .font(.system(size: 190, weight: .heavy))
                    .kerning(-10)
                    .contentTransition(.numericText())
                    .fixedSize()
                    .padding(.trailing, 22)
                    .offset(y: 46)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Gym").posterHeading()
                    Text("sessions this week").posterLabel()
                    HStack(spacing: 4) {
                        ForEach(0..<max(gym.target, gym.done), id: \.self) { index in
                            PosterSquare(state: index < gym.done ? .solid : .outline)
                        }
                    }
                    .padding(.top, 6)
                }
                .padding(.horizontal, Poster.margin)
                .padding(.top, 10)
            }
            .clipped()
        .animation(.snappy, value: gym.done)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gym: \(gym.done) of \(gym.target) sessions this week")
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

    /// What the black bar says.
    static func nextAction(for home: HomeSnapshot) -> (small: String, big: String) {
        let gym = home.gym
        if gym.remaining == 0 {
            return ("WEEK \(home.week.isoWeek) · \(gym.done) SESSIONS", "GYM WEEK DONE")
        }
        let trainedToday = gym.sessions.contains { $0.date == home.today }
        let small = "\(gym.remaining) MORE BY SUNDAY"
        if trainedToday {
            return (small, "DONE FOR TODAY")
        }
        return ("NEXT · " + small, "GYM SESSION")
    }
}
