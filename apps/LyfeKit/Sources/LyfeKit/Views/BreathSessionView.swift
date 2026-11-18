import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// A breath session, full screen: the table before START, the timer while
/// it runs, and what was recorded once it is over.
public struct BreathSessionView: View {
    let model: AppModel
    let session: BreathSessionModel
    @State private var confirmingEnd = false

    public init(model: AppModel, session: BreathSessionModel) {
        self.model = model
        self.session = session
    }

    public var body: some View {
        Group {
            if let run = session.run {
                if session.isFinished {
                    let unsent = model.unsentBreath.contains(run.id)
                    BreathDoneView(
                        run: run, breath: unsent ? nil : model.home?.breath, unsent: unsent,
                        today: model.home?.today, weekEnds: model.home?.week.endsOn
                    ) {
                        model.closeBreathSession()
                    }
                } else {
                    BreathTimerView(session: session, run: run) {
                        confirmingEnd = true
                    }
                }
            } else {
                BreathReadyView(session: session) { model.closeBreathSession() }
            }
        }
        .preferredColorScheme(.light)
        #if os(iOS)
            // Nothing but the timer while it runs.
            .statusBarHidden(session.isRunning)
        #endif
        .onAppear { session.drive() }
        // The screen stays on while a session runs, so a tap always lands.
        .onChange(of: session.isRunning, initial: true) { _, running in keepAwake(running) }
        .onDisappear { keepAwake(false) }
        .confirmationDialog("End this session now?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("End session", role: .destructive) { session.stop() }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("The holds recorded so far are kept.")
        }
    }

    private func keepAwake(_ awake: Bool) {
        #if canImport(UIKit) && os(iOS)
            UIApplication.shared.isIdleTimerDisabled = awake
        #endif
    }
}

// MARK: Before START

/// The table lyfe set, and START.
struct BreathReadyView: View {
    let session: BreathSessionModel
    let onClose: () -> Void

    var body: some View {
        let table = session.table
        let toBeat = table.lastHoldsMs.enumerated().compactMap { index, hold in hold.map { (index + 1, $0) } }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Text("✕ Close").posterLabel().padding(.vertical, 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Set by lyfe").posterLabel()
            }
            .padding(.horizontal, Poster.margin)

            BreathGiant(text: clockLabel(seconds: table.roundS))
            BreathWord(
                word: "Rounds",
                small: "\(table.rounds) rounds · hold as long as you can · tap when you breathe")

            BreathRows(
                rows: toBeat.map { ("ROUND \($0.0)", clockLabel(ms: $0.1)) },
                title: toBeat.isEmpty ? nil : "Last time")
                .padding(.top, 18)

            BreathCallout(label: "This table", text: BreathText.tableLine(table))
            Spacer(minLength: 0)
            Button {
                session.start()
            } label: {
                BreathBar(
                    small: "\(BreathRun.minutes(for: table)) MIN · FIRST HOLD \(Int(BreathRun.leadIn)) S AFTER START",
                    big: "START", mark: "→", onDark: true)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Poster.paper)
        .background(Poster.blue.ignoresSafeArea())
    }
}

// MARK: Running

/// The timer. The whole screen is the tap target during a hold.
///
/// What it shows is worked out from the clock at every tick, never from
/// what the session was last told: the screen then cannot be left on
/// BREATHE after a round has begun, however late anything else runs.
struct BreathTimerView: View {
    let session: BreathSessionModel
    let run: BreathRun
    let onEnd: () -> Void
    @State private var flash = false

    var body: some View {
        // Ticks fall on the round's own seconds, so a round begins on a tick.
        TimelineView(.periodic(from: run.firstRoundAt, by: 0.2)) { timeline in
            let look = BreathText.look(for: run, at: timeline.date)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button(action: onEnd) {
                        Text("✕ End").posterLabel().padding(.vertical, 12).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Text(look.topLeft).posterLabel().padding(.leading, 10)
                    Spacer()
                    Text(look.topRight).posterLabel().monospacedDigit()
                }
                .padding(.horizontal, Poster.margin)

                BreathGiant(text: look.giant)
                BreathWord(word: look.word, small: look.small)
                Spacer(minLength: 0)
                BreathRows(
                    rows: run.recorded.suffix(4).map {
                        ("ROUND \($0.round)", clockLabel(ms: $0.holdMs) + (run.beat(round: $0.round) ? " ▲" : ""))
                    }, title: nil
                )
                .padding(.bottom, 14)
                BreathBar(small: look.barSmall, big: look.barBig, mark: look.holding ? "●" : "", onDark: !look.holding)
            }
            .foregroundStyle(look.ink)
            .background(look.background.ignoresSafeArea())
            .animation(.linear(duration: 0.2), value: look.background)
        }
        .overlay {
            // The hard flash when a hold passes last session's.
            Poster.paper.ignoresSafeArea().opacity(flash ? 1 : 0).allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { session.tap() }
        .onChange(of: session.beats) {
            flash = true
            withAnimation(.easeOut(duration: 0.45)) { flash = false }
        }
        .accessibilityAction(named: "End hold") { session.tap() }
    }
}

// MARK: After

/// Where lyfe pushes: the best hold, how it compares, and the next table.
struct BreathDoneView: View {
    let run: BreathRun
    /// The backend's answer, once it has this session.
    let breath: HomeSnapshot.BreathWeek?
    /// True while the session is only on this phone.
    let unsent: Bool
    let today: CalendarDay?
    let weekEnds: CalendarDay?
    let onDone: () -> Void

    var body: some View {
        let text = BreathText.done(run: run, breath: breath, unsent: unsent, today: today, weekEnds: weekEnds)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Session done").posterLabel()
                Spacer()
                Text("\(run.roundsDone) of \(run.table.rounds) rounds").posterLabel()
            }
            .padding(.horizontal, Poster.margin)
            .padding(.vertical, 12)

            BreathGiant(text: run.bestMs.map { clockLabel(ms: $0) } ?? "0:00")
            BreathWord(word: "Best hold", small: text.comparison)
            BreathRows(rows: text.rows, title: nil).padding(.top, 16)
            BreathCallout(label: text.calloutLabel, text: text.callout)
            Spacer(minLength: 0)
            Button(action: onDone) {
                BreathBar(small: text.barSmall, big: "DONE", mark: "→", onDark: true)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Poster.paper)
        .background(Poster.blue.ignoresSafeArea())
    }
}

// MARK: Pieces

/// The one giant figure of the screen.
struct BreathGiant: View {
    let text: String

    var body: some View {
        Text(Poster.tight(text, by: -8))
            .font(.system(size: 150, weight: .heavy))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .contentTransition(.numericText())
            .padding(.horizontal, Poster.margin - 6)
            .padding(.top, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BreathWord: View {
    let word: String
    let small: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(word).posterHeading(34)
            Text(small).posterLabel().fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Poster.margin)
    }
}

/// Ruled rows: a label on the left, a figure on the right.
struct BreathRows: View {
    let rows: [(String, String)]
    let title: String?

    var body: some View {
        if !rows.isEmpty {
            VStack(spacing: 0) {
                if let title {
                    Text(title).posterLabel()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 5)
                }
                Rectangle().fill(.foreground).frame(height: Poster.rule)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.0)
                        Spacer()
                        Text(row.1).monospacedDigit()
                    }
                    .font(.system(size: 15, weight: .heavy))
                    .padding(.vertical, 6)
                    Rectangle().fill(.foreground).frame(height: 1.5)
                }
            }
            .padding(.horizontal, Poster.margin)
        }
    }
}

/// A paper panel with a few words in it.
struct BreathCallout: View {
    let label: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).posterLabel()
            Text(text)
                .font(.system(size: 19, weight: .heavy))
                .tracking(-0.5)
                .lineSpacing(-2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .foregroundStyle(Poster.ink)
        .background(Poster.paper)
        .padding(.horizontal, Poster.margin)
        .padding(.top, 16)
    }
}

/// The bar at the bottom: the single next action. On a dark or coloured
/// screen it is paper; on a hold it is black.
struct BreathBar: View {
    let small: String
    let big: String
    let mark: String
    let onDark: Bool

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                if !small.isEmpty {
                    Text(small).posterLabel()
                }
                Text(big)
                    .font(.system(size: 30, weight: .heavy))
                    .tracking(-0.9)
                    // A long meal name is set smaller rather than wrapped.
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer()
            Text(mark).font(.system(size: 32, weight: .heavy))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Poster.margin)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .foregroundStyle(onDark ? Poster.ink : Poster.paper)
        .background((onDark ? Poster.paper : Poster.ink).ignoresSafeArea(edges: .bottom))
        .contentShape(Rectangle())
    }
}

// MARK: Words

/// The words and colours of the breath screens. Plain functions, so they
/// can be checked without a screen.
enum BreathText {
    struct Look: Equatable {
        var topLeft: String
        var topRight: String
        var giant: String
        var word: String
        var small: String
        var barSmall: String
        var barBig: String
        var holding: Bool
        var background: Color
        var ink: Color
    }

    /// A hold with nothing to beat takes this long to go from yellow to red.
    static let plainHoldMs = 120_000

    /// What the timer shows at one moment, from the run and the time alone.
    static func look(for run: BreathRun, at now: Date) -> Look {
        let phase = run.phase(at: now)
        let table = run.table
        let rounds = "\(clockLabel(seconds: table.roundS)) ROUNDS · SET BY LYFE"
        func left(until date: Date) -> String {
            clockLabel(seconds: Int(max(0, date.timeIntervalSince(now)).rounded(.up)))
        }
        func toBeat(_ round: Int) -> String? {
            run.holdToBeat(round: round).map { "TO BEAT \(clockLabel(ms: $0))" }
        }
        switch phase {
        case .leadIn(let until):
            return Look(
                topLeft: "GET READY", topRight: "\(table.rounds) ROUNDS OF \(clockLabel(seconds: table.roundS))",
                giant: left(until: until), word: "BREATHE",
                small: (["HOLD AT THE TONE"] + [toBeat(1)].compactMap { $0 }).joined(separator: " · "),
                barSmall: "NEXT · ROUND 1 OF \(table.rounds)", barBig: "HOLD", holding: false,
                background: Poster.ink, ink: Poster.paper)
        case .hold(let round, let since, let roundEnds):
            let heldMs = Int(max(0, now.timeIntervalSince(since)) * 1000)
            let colours = holdColours(heldMs: heldMs, toBeatMs: run.holdToBeat(round: round))
            return Look(
                topLeft: "ROUND \(round) / \(table.rounds)", topRight: "ENDS IN \(left(until: roundEnds))",
                giant: clockLabel(ms: heldMs), word: "HOLD",
                small: ([rounds] + [toBeat(round)].compactMap { $0 }).joined(separator: " · "),
                barSmall: "TAP ANYWHERE WHEN YOU BREATHE", barBig: "BREATHE", holding: true,
                background: colours.background, ink: colours.ink)
        case .recover(let round, let holdMs, let nextAt):
            let held = "HELD \(clockLabel(ms: holdMs))" + (run.beat(round: round) ? " ▲" : "")
            return Look(
                topLeft: "ROUND \(round) / \(table.rounds)", topRight: held,
                giant: left(until: nextAt), word: "BREATHE",
                small: (["NEXT HOLD AT THE TONE"] + [toBeat(round + 1)].compactMap { $0 }).joined(separator: " · "),
                barSmall: "NEXT · ROUND \(round + 1) OF \(table.rounds)", barBig: "HOLD", holding: false,
                background: Poster.ink, ink: Poster.paper)
        case .finished:
            return Look(
                topLeft: "SESSION DONE", topRight: "", giant: "0:00", word: "DONE", small: "", barSmall: "",
                barBig: "DONE", holding: false, background: Poster.blue, ink: Poster.paper)
        }
    }

    /// The hold screen shifts from yellow to red as the hold nears last
    /// session's, and turns blue once it has passed it.
    static func holdColours(heldMs: Int, toBeatMs: Int?) -> (background: Color, ink: Color) {
        if let toBeatMs, heldMs >= toBeatMs {
            return (Poster.blue, Poster.paper)
        }
        let share = min(1, Double(heldMs) / Double(max(toBeatMs ?? plainHoldMs, 1)))
        return (Poster.yellow.mix(with: Poster.red, by: share), Poster.ink)
    }

    /// Why the table is what it is, in a sentence or two.
    static func tableLine(_ table: BreathTable, next: Bool = false) -> String {
        let round = clockLabel(seconds: table.roundS)
        let under = clockLabel(seconds: table.advanceUnderS)
        if let from = table.changedFromS {
            return "\(round) rounds\(next ? " next" : ""), up from \(clockLabel(seconds: from)). "
                + "Recovery dropped under \(under), so the rounds get longer."
        }
        let longer = clockLabel(seconds: table.roundS + table.stepS)
        if table.lastHoldsMs.allSatisfy({ $0 == nil }) {
            return "\(round) rounds to start. You move to \(longer) when recovery drops under \(under)."
        }
        return "\(round) rounds again. You move to \(longer) when recovery drops under \(under)."
    }

    /// The after-session screen. `breath` is the backend's answer once it
    /// has this session; until then the screen shows only what was captured.
    static func done(
        run: BreathRun, breath: HomeSnapshot.BreathWeek?, unsent: Bool, today: CalendarDay?, weekEnds: CalendarDay?
    ) -> (comparison: String, rows: [(String, String)], calloutLabel: String, callout: String, barSmall: String) {
        var comparison = "FIRST SESSION ON RECORD"
        if let best = run.bestMs, let last = run.lastBestMs {
            let difference = abs(best - last) / 1000
            comparison =
                best > last
                ? "▲ \(clockLabel(seconds: difference)) ON LAST SESSION"
                : best == last || difference == 0
                    ? "LEVEL WITH LAST SESSION" : "▼ \(clockLabel(seconds: difference)) UNDER LAST SESSION"
        }

        var rows: [(String, String)] = []
        if let mean = run.meanMs { rows.append(("MEAN", clockLabel(ms: mean))) }
        if let recovery = run.tightestRecoveryMs { rows.append(("TIGHTEST RECOVERY", clockLabel(ms: recovery))) }

        guard let breath, !unsent else {
            rows.append(("THIS WEEK", "NOT SENT YET"))
            return (
                comparison, rows, "Saved on this phone",
                "It goes to the server as soon as it can be reached. The week and the next table come back with it.",
                "SENDS WHEN THE SERVER IS REACHABLE"
            )
        }
        rows.append(("THIS WEEK", "\(breath.done) OF \(breath.target)"))

        let counted = breath.sessions.first { $0.id == run.id }?.counts ?? true
        let callout =
            counted
            ? ("Next table", tableLine(breath.table, next: true))
            : (
                "Not counted",
                "Too short to count for the week: a session needs a hold in at least half its rounds. "
                    + "The holds are kept."
            )

        let streak = breath.streak
        let deadline = today != nil && today == weekEnds ? "TODAY" : "BY SUNDAY"
        let barSmall: String
        if breath.remaining == 0 {
            barSmall = "WEEK DONE · \(streak.weeks) \(HomeText.weeksInARow(streak.weeks))"
        } else if !streak.reachable {
            barSmall = "\(breath.done) OF \(breath.target) THIS WEEK"
        } else {
            switch streak.state {
            case .onTrack, .recovering, .kept:
                barSmall = "STREAK SAFE WITH \(breath.remaining) MORE \(deadline)"
            case .notStarted:
                barSmall = "\(breath.remaining) MORE \(deadline) STARTS A STREAK"
            }
        }
        return (comparison, rows, callout.0, callout.1, barSmall)
    }
}
