import Foundation
import Observation

/// The breath session on screen: the table before START, the run while it
/// lasts, and what was recorded once it is over.
@MainActor
@Observable
public final class BreathSessionModel {
    /// The table this session runs.
    public let table: BreathTable
    /// Nil until the owner taps START.
    public private(set) var run: BreathRun?
    /// Where the run stands, moved on by the clock and by taps.
    public private(set) var phase: BreathRun.Phase?
    /// Goes up by one each time a hold passes last session's, which the
    /// screen answers with a flash.
    public private(set) var beats = 0

    private let cues: any BreathCues
    private let now: @Sendable () -> Date
    /// Called after START and after every tap, to keep the run on disk.
    private let onChange: (BreathRun) -> Void
    /// Called once, when the run ends.
    private let onFinish: (BreathRun) -> Void
    private var driver: Task<Void, Never>?
    /// The round whose hold has already been announced as beating last time.
    private var beatenRound: Int?
    private var finishReported = false
    /// The longest the session goes without looking at the clock.
    static let longestNap: TimeInterval = 0.25

    public init(
        table: BreathTable,
        resuming run: BreathRun? = nil,
        cues: any BreathCues,
        now: @escaping @Sendable () -> Date = { Date() },
        onChange: @escaping (BreathRun) -> Void,
        onFinish: @escaping (BreathRun) -> Void
    ) {
        self.table = run?.table ?? table
        self.run = run
        self.cues = cues
        self.now = now
        self.onChange = onChange
        self.onFinish = onFinish
        if let run {
            phase = run.phase(at: now())
        }
    }

    public var isRunning: Bool {
        if let phase { phase != .finished } else { false }
    }

    public var isFinished: Bool { phase == .finished }

    /// The owner tapped START.
    public func start() {
        guard run == nil else { return }
        let started = now()
        let run = BreathRun(table: table, startedAt: started)
        self.run = run
        phase = run.phase(at: started)
        onChange(run)
        drive()
    }

    /// Picks a run in progress back up, after the app was closed or put
    /// away: the cues are lined up again from the clock.
    public func drive() {
        guard let run, driver == nil else { return }
        advance(to: now())
        guard isRunning else { return }
        cues.begin(run, now: now())
        driver = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let run = self.run else { return }
                let now = self.now()
                self.advance(to: now)
                guard let next = run.nextEvent(after: now) else { return }
                // Short naps, not one sleep to the next event: the system
                // may wake a long sleep late by a share of its length,
                // which would hold back everything that follows a round's
                // start by seconds.
                let wait = min(Self.longestNap, max(0.02, next.timeIntervalSince(self.now())))
                try? await Task.sleep(for: .seconds(wait), tolerance: .milliseconds(10))
            }
        }
    }

    /// The owner tapped during a hold.
    public func tap() {
        guard var run else { return }
        let now = now()
        guard run.tap(at: now) else { return }
        self.run = run
        onChange(run)
        cues.holdEnded()
        advance(to: now)
    }

    /// The owner ended the session early.
    public func stop() {
        guard var run, !run.isFinished else { return }
        run.stop(at: now())
        self.run = run
        advance(to: now())
    }

    /// Moves the session on to `now`: ends it when the last round has run
    /// out, and notices a hold passing last session's.
    func advance(to now: Date) {
        guard var run else { return }
        run.settle(at: now)
        self.run = run
        let phase = run.phase(at: now)
        self.phase = phase

        if case .hold(let round, _, _) = phase, beatenRound != round,
            let beat = run.beatMoment(round: round), now >= beat
        {
            beatenRound = round
            beats += 1
            cues.beatLast()
        }
        if phase == .finished, !finishReported {
            finishReported = true
            driver?.cancel()
            driver = nil
            cues.end(completed: run.roundsDone > 0)
            onFinish(run)
        }
    }
}
