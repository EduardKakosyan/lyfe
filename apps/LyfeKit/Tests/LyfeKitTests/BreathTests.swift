import Foundation
import Testing

@testable import LyfeKit

private let start = Date(timeIntervalSince1970: 1_795_000_000)
/// The id the fixture gives the first session of the week.
private let confirmedID = "00000000-0000-4000-8000-000000000001"

/// A run of six 4:00 rounds started at `start`: the first hold begins ten
/// seconds later.
private func newRun(lastHolds: [Int?] = Array(repeating: nil, count: 6)) -> BreathRun {
    BreathRun(table: Fixture.table(lastHolds: lastHolds), startedAt: start)
}

/// The moment `seconds` into round `round`.
private func moment(_ run: BreathRun, round: Int, _ seconds: TimeInterval) -> Date {
    run.roundStart(round).addingTimeInterval(seconds)
}

@Suite struct BreathRunTests {
    @Test func theRoundsFollowTheClock() {
        var run = newRun()
        #expect(run.phase(at: start) == .leadIn(until: start.addingTimeInterval(10)))
        #expect(run.phase(at: start.addingTimeInterval(9.9)) == .leadIn(until: run.firstRoundAt))

        // The first hold begins when the lead-in ends, with no tap needed.
        let first = run.firstRoundAt
        #expect(run.phase(at: first) == .hold(round: 1, since: first, roundEnds: first.addingTimeInterval(240)))

        // A tap ends the hold; the rest of the round is recovery.
        do {
            let recorded = run.tap(at: moment(run, round: 1, 125.4))
            #expect(recorded)
        }
        #expect(run.holdsMs[0] == 125_400)
        #expect(
            run.phase(at: moment(run, round: 1, 200))
                == .recover(round: 1, holdMs: 125_400, nextAt: first.addingTimeInterval(240)))

        // The second round begins on time, whatever the first hold was.
        #expect(
            run.phase(at: moment(run, round: 2, 0))
                == .hold(round: 2, since: first.addingTimeInterval(240), roundEnds: first.addingTimeInterval(480)))
        #expect(!run.isFinished)
    }

    @Test func onlyATapDuringAHoldCounts() {
        var run = newRun()
        // During the lead-in.
        do {
            let recorded = run.tap(at: start.addingTimeInterval(5))
            #expect(!recorded)
        }
        // A slip of the finger as the round begins.
        do {
            let recorded = run.tap(at: moment(run, round: 1, 0.4))
            #expect(!recorded)
        }
        do {
            let recorded = run.tap(at: moment(run, round: 1, 90))
            #expect(recorded)
        }
        // Again during the recovery: the hold stands.
        do {
            let recorded = run.tap(at: moment(run, round: 1, 120))
            #expect(!recorded)
        }
        #expect(run.holdsMs[0] == 90_000)
        #expect(run.recorded.count == 1)
    }

    @Test func aRoundWithoutATapHasNoHold() {
        var run = newRun()
        run.tap(at: moment(run, round: 1, 100))
        // Round 2 passes untouched, as when the phone was put down.
        run.tap(at: moment(run, round: 3, 110))
        #expect(run.holdsMs == [100_000, nil, 110_000, nil, nil, nil])
        #expect(run.roundsDone == 2)
        #expect(run.recorded.map(\.round) == [1, 3])
    }

    @Test func theLastTapEndsTheSession() {
        var run = newRun()
        for round in 1...6 {
            do {
                let recorded = run.tap(at: moment(run, round: round, 100 + Double(round)))
                #expect(recorded)
            }
        }
        #expect(run.isFinished)
        #expect(run.endedAt == moment(run, round: 6, 106))
        #expect(run.phase(at: moment(run, round: 6, 107)) == .finished)
        #expect(run.nextEvent(after: moment(run, round: 6, 107)) == nil)
        do {
            let recorded = run.tap(at: moment(run, round: 6, 120))
            #expect(!recorded)
        }
    }

    @Test func aSessionLeftAloneEndsWhenTheRoundsRunOut() {
        var run = newRun()
        run.tap(at: moment(run, round: 1, 100))
        let later = run.scheduleEnds.addingTimeInterval(3600)
        // By the clock it is over even before anything records that.
        #expect(run.phase(at: later) == .finished)
        run.settle(at: moment(run, round: 3, 0))
        #expect(!run.isFinished)
        run.settle(at: later)
        #expect(run.endedAt == run.scheduleEnds)
        #expect(run.roundsDone == 1)
    }

    @Test func stoppingEarlyKeepsTheHoldsAndDropsTheOneInProgress() {
        var run = newRun()
        run.tap(at: moment(run, round: 1, 100))
        run.tap(at: moment(run, round: 2, 105))
        run.stop(at: moment(run, round: 3, 60))
        #expect(run.isFinished)
        #expect(run.endedAt == moment(run, round: 3, 60))
        #expect(run.holdsMs == [100_000, 105_000, nil, nil, nil, nil])
        // Stopping twice changes nothing.
        run.stop(at: moment(run, round: 4, 0))
        #expect(run.endedAt == moment(run, round: 3, 60))
    }

    @Test func aHoldIsComparedWithTheSameRoundLastTime() {
        var run = newRun(lastHolds: [125, 132, nil, 118, 121, 119])
        #expect(run.holdToBeat(round: 2) == 132_000)
        #expect(run.holdToBeat(round: 3) == nil)
        #expect(run.beatMoment(round: 2) == moment(run, round: 2, 132))
        run.tap(at: moment(run, round: 1, 125))
        run.tap(at: moment(run, round: 2, 139))
        run.tap(at: moment(run, round: 3, 90))
        // Level is not a beat; a round with nothing to beat is not one either.
        #expect(!run.beat(round: 1))
        #expect(run.beat(round: 2))
        #expect(!run.beat(round: 3))
        #expect(run.lastBestMs == 132_000)
    }

    @Test func theNextEventIsTheNextThingTheClockBrings() {
        var run = newRun(lastHolds: [125, nil, nil, nil, nil, nil])
        #expect(run.nextEvent(after: start) == run.firstRoundAt)
        // In a hold: the moment it passes last time's, then the round's end.
        #expect(run.nextEvent(after: moment(run, round: 1, 30)) == moment(run, round: 1, 125))
        #expect(run.nextEvent(after: moment(run, round: 1, 130)) == moment(run, round: 2, 0))
        // With nothing to beat: the round's end.
        #expect(run.nextEvent(after: moment(run, round: 2, 30)) == moment(run, round: 3, 0))
        run.tap(at: moment(run, round: 3, 50))
        #expect(run.nextEvent(after: moment(run, round: 3, 60)) == moment(run, round: 4, 0))
        #expect(run.nextEvent(after: run.scheduleEnds) == nil)
    }

    @Test func aSessionIsSummedUpByItsHolds() {
        var run = newRun()
        for (round, seconds) in [125.0, 132, 120, 118].enumerated() {
            run.tap(at: moment(run, round: round + 1, seconds))
        }
        #expect(run.bestMs == 132_000)
        #expect(run.meanMs == 123_750)
        // 4:00 rounds and a 2:12 hold leave 1:48.
        #expect(run.tightestRecoveryMs == 108_000)
        let empty = newRun()
        #expect(empty.bestMs == nil)
        #expect(empty.meanMs == nil)
        #expect(empty.tightestRecoveryMs == nil)
        // Ten seconds of lead-in and six rounds of four minutes.
        #expect(BreathRun.minutes(for: empty.table) == 25)
    }

    @Test func aSessionIsSentInTheShapeTheBackendTakes() throws {
        var run = BreathRun(
            id: UUID(uuidString: "A1B2C3D4-0000-4000-8000-000000000001")!, table: Fixture.table(),
            startedAt: Date(timeIntervalSince1970: 1_795_000_000))
        run.tap(at: moment(run, round: 1, 125.4))
        run.tap(at: moment(run, round: 3, 110))
        run.stop(at: moment(run, round: 4, 30))

        let data = try JSONEncoder.lyfe.encode(BreathSessionUpload(run))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["id"] as? String == "A1B2C3D4-0000-4000-8000-000000000001")
        #expect(json["started_at"] as? String == "2026-11-18T11:06:40Z")
        #expect(json["ended_at"] as? String == "2026-11-18T11:19:20Z")
        #expect(json["round_s"] as? Int == 240)
        #expect(json["rounds"] as? Int == 6)
        // The round without a tap is left out.
        let holds = try #require(json["holds"] as? [[String: Int]])
        #expect(holds == [["round": 1, "hold_ms": 125_400], ["round": 3, "hold_ms": 110_000]])
    }

    @Test func durationsReadAsMinutesAndSeconds() {
        #expect(clockLabel(ms: 132_000) == "2:12")
        #expect(clockLabel(ms: 132_999) == "2:12")
        #expect(clockLabel(ms: 5_000) == "0:05")
        #expect(clockLabel(seconds: 240) == "4:00")
        #expect(clockLabel(seconds: 615) == "10:15")
        #expect(clockLabel(ms: -4) == "0:00")
    }
}

@Suite struct BreathCueTests {
    @Test func everyRoundIsCountedInAndAnnounced() {
        let run = newRun()
        let cues = CuePlan.cues(for: run, after: start)
        // Six rounds, each with three ticks and a tone; rounds two to six
        // also get a ten-second warning.
        #expect(cues.filter { $0.sound == .hold }.map(\.at) == (1...6).map { run.roundStart($0) })
        #expect(cues.filter { $0.sound == .tick }.count == 18)
        #expect(cues.filter { $0.sound == .warning }.map(\.at) == (2...6).map { moment(run, round: $0, -10) })
        #expect(cues.map(\.at) == cues.map(\.at).sorted())
    }

    @Test func comingBackMidSessionKeepsOnlyWhatIsStillAhead() {
        var run = newRun()
        let cues = CuePlan.cues(for: run, after: moment(run, round: 5, 100))
        #expect(cues.first?.at == moment(run, round: 6, -10))
        #expect(cues.last?.at == run.roundStart(6))
        #expect(cues.count == 5)
        run.stop(at: moment(run, round: 5, 120))
        #expect(CuePlan.cues(for: run, after: moment(run, round: 5, 100)).isEmpty)
    }
}

@Suite struct BreathStoreTests {
    @Test func theSessionInProgressSurvivesBeingWrittenAndRead() {
        let store = BreathStore(directory: Fixture.temporaryDirectory())
        #expect(store.loadActive() == nil)
        var run = newRun(lastHolds: [125, 132, nil, 118, 121, 119])
        run.tap(at: moment(run, round: 1, 125.4))
        store.saveActive(run)
        #expect(store.loadActive() == run)
        store.clearActive()
        #expect(store.loadActive() == nil)
    }

    @Test func finishedSessionsWaitInOrderUntilConfirmed() {
        let store = BreathStore(directory: Fixture.temporaryDirectory())
        #expect(store.outbox().isEmpty)
        let first = newRun()
        let second = BreathRun(table: Fixture.table(), startedAt: start.addingTimeInterval(86_400))
        store.enqueue(first)
        store.enqueue(second)
        // Kept once, however often it is handed over.
        store.enqueue(first)
        #expect(store.outbox().map(\.id) == [first.id, second.id])
        store.remove(first.id)
        #expect(store.outbox().map(\.id) == [second.id])
        store.remove(second.id)
        #expect(store.outbox().isEmpty)
    }
}

@MainActor
@Suite struct BreathSessionModelTests {
    final class Seen {
        var saved: [BreathRun] = []
        var finished: [BreathRun] = []
    }

    private func session(lastHolds: [Int?] = Array(repeating: nil, count: 6)) -> (BreathSessionModel, TestClock, RecordingCues, Seen) {
        let clock = TestClock(start)
        let cues = RecordingCues()
        let seen = Seen()
        let model = BreathSessionModel(
            table: Fixture.table(lastHolds: lastHolds), cues: cues, now: { clock.now },
            onChange: { seen.saved.append($0) }, onFinish: { seen.finished.append($0) })
        return (model, clock, cues, seen)
    }

    @Test func nothingRunsUntilStart() {
        let (model, _, cues, seen) = session()
        #expect(model.run == nil)
        #expect(!model.isRunning)
        model.tap()
        #expect(seen.saved.isEmpty)
        #expect(cues.log.isEmpty)
    }

    @Test func aSessionIsSavedFromTheStartAndAfterEveryTap() throws {
        let (model, clock, cues, seen) = session()
        model.start()
        let run = try #require(model.run)
        #expect(model.isRunning)
        #expect(seen.saved.count == 1)
        #expect(cues.log == ["begin"])

        clock.now = moment(run, round: 1, 100)
        model.advance(to: clock.now)
        #expect(model.phase == .hold(round: 1, since: run.firstRoundAt, roundEnds: run.roundStart(2)))
        model.tap()
        #expect(seen.saved.count == 2)
        #expect(seen.saved.last?.holdsMs[0] == 100_000)
        #expect(cues.log == ["begin", "holdEnded"])
        #expect(model.phase == .recover(round: 1, holdMs: 100_000, nextAt: run.roundStart(2)))
        // A second tap in the same round does nothing.
        model.tap()
        #expect(seen.saved.count == 2)
    }

    @Test func passingLastTimesHoldIsMarkedOncePerRound() throws {
        let (model, clock, cues, _) = session(lastHolds: [125, 132, nil, nil, nil, nil])
        model.start()
        let run = try #require(model.run)
        model.advance(to: moment(run, round: 1, 124))
        #expect(model.beats == 0)
        model.advance(to: moment(run, round: 1, 125))
        model.advance(to: moment(run, round: 1, 126))
        #expect(model.beats == 1)
        #expect(cues.log.filter { $0 == "beatLast" }.count == 1)
        // Round 2 has its own hold to beat.
        clock.now = moment(run, round: 2, 140)
        model.advance(to: clock.now)
        #expect(model.beats == 2)
        // Round 3 has none.
        model.advance(to: moment(run, round: 3, 200))
        #expect(model.beats == 2)
    }

    @Test func theSessionEndsOnceOnTheLastTap() throws {
        let (model, clock, cues, seen) = session()
        model.start()
        let run = try #require(model.run)
        for round in 1...6 {
            clock.now = moment(run, round: round, 100)
            model.advance(to: clock.now)
            model.tap()
        }
        #expect(model.isFinished)
        #expect(!model.isRunning)
        #expect(seen.finished.count == 1)
        #expect(seen.finished[0].roundsDone == 6)
        #expect(cues.log.last == "end true")
        model.advance(to: clock.now.addingTimeInterval(600))
        model.stop()
        #expect(seen.finished.count == 1)
    }

    @Test func stoppingBeforeAnyHoldEndsWithNothing() {
        let (model, clock, cues, seen) = session()
        model.start()
        clock.advance(40)
        model.stop()
        #expect(model.isFinished)
        #expect(seen.finished.map(\.roundsDone) == [0])
        #expect(cues.log.last == "end false")
    }

    @Test func aRunningSessionLooksAtTheClockSeveralTimesASecond() async throws {
        // The session must notice a round beginning, and a hold passing last
        // time's, promptly. It used to sleep straight through to the next
        // event, and a long sleep can be woken late.
        let (model, clock, cues, _) = session(lastHolds: [2, nil, nil, nil, nil, nil])
        model.start()
        let run = try #require(model.run)
        #expect(model.phase == .leadIn(until: run.firstRoundAt))
        // Let the session settle into waiting for the first round.
        try await Task.sleep(for: .milliseconds(60))

        // Ten seconds pass for the session while almost none pass here.
        clock.now = moment(run, round: 1, 3)
        try await Task.sleep(for: .seconds(BreathSessionModel.longestNap * 3))
        #expect(model.phase == .hold(round: 1, since: run.firstRoundAt, roundEnds: run.roundStart(2)))
        #expect(model.beats == 1)
        #expect(cues.log == ["begin", "beatLast"])
        model.stop()
    }

    @Test func aRunPickedUpAgainCarriesOnFromTheClock() {
        let clock = TestClock(start)
        var earlier = newRun()
        earlier.tap(at: moment(earlier, round: 1, 100))
        // The app comes back two rounds later.
        clock.now = moment(earlier, round: 3, 30)
        let cues = RecordingCues()
        let model = BreathSessionModel(
            table: Fixture.table(roundS: 300), resuming: earlier, cues: cues, now: { clock.now },
            onChange: { _ in }, onFinish: { _ in })
        // The run keeps the table it was started with.
        #expect(model.table.roundS == 240)
        #expect(model.phase == .hold(round: 3, since: earlier.roundStart(3), roundEnds: earlier.roundStart(4)))
        model.tap()
        #expect(model.run?.holdsMs == [100_000, nil, 30_000, nil, nil, nil])
    }
}

@MainActor
@Suite struct BreathOfflineTests {
    /// Signed in, with Home fetched and the first table on it.
    private func ready() async -> (World, AppModel) {
        let world = World.signedIn()
        world.backend.on("GET /v1/home", .ok(Fixture.home(breath: Fixture.breath())))
        world.backend.on("POST /v1/sync", .ok(Fixture.sources()))
        let model = world.launch()
        await model.refresh()
        return (world, model)
    }

    /// Runs the open session to the end: a 1:40 hold in every round.
    private func runThrough(_ model: AppModel, _ world: World) throws -> BreathRun {
        let session = try #require(model.breathSession)
        session.start()
        let run = try #require(session.run)
        for round in 1...6 {
            world.time.now = moment(run, round: round, 100)
            session.advance(to: world.time.now)
            session.tap()
        }
        return try #require(session.run)
    }

    @Test func theTableComesFromTheBackendAndOpensWithoutStarting() async throws {
        let (world, model) = await ready()
        #expect(model.home?.breath?.table.roundS == 240)
        #expect(model.breathSession == nil)
        model.openBreathSession()
        let session = try #require(model.breathSession)
        #expect(session.table == model.home?.breath?.table)
        #expect(session.run == nil)
        // Closing before START leaves nothing behind.
        model.closeBreathSession()
        #expect(model.breathSession == nil)
        #expect(world.breath.loadActive() == nil)
        #expect(model.unsentBreath.isEmpty)
    }

    @Test func aSessionRunOfflineIsKeptAndCountedOnceOnReconnect() async throws {
        let (world, model) = await ready()

        // Airplane mode. The table seen earlier is enough to run a session.
        world.backend.goDown(as: .notConnectedToInternet)
        model.openBreathSession()
        let run = try runThrough(model, world)
        #expect(run.isFinished)
        await eventually { model.isOffline }

        // Finished and kept on the phone; the session screen stays for DONE.
        #expect(model.unsentBreath == [run.id])
        #expect(world.breath.outbox() == [run])
        #expect(world.breath.loadActive() == nil)
        #expect(model.breathSession != nil)
        #expect(model.home?.breath?.done == 0)
        model.closeBreathSession()

        // The app is closed and opened again, still offline.
        let relaunched = world.launch()
        #expect(relaunched.unsentBreath == [run.id])
        await relaunched.refresh()
        #expect(relaunched.unsentBreath == [run.id])

        // Back online: it is sent, and the answer is the week with it in.
        world.backend.goDown(false)
        world.backend.on(
            "POST /v1/breath/sessions",
            .ok(Fixture.home(breath: Fixture.breath(holds: [[], [100, 100, 100, 100, 100, 100]], doneToday: true))))
        world.backend.on(
            "GET /v1/home",
            .ok(Fixture.home(breath: Fixture.breath(holds: [[], [100, 100, 100, 100, 100, 100]], doneToday: true))))
        await relaunched.refresh()
        #expect(relaunched.unsentBreath.isEmpty)
        #expect(world.breath.outbox().isEmpty)
        #expect(relaunched.home?.breath?.done == 1)
        #expect(!relaunched.isOffline)

        // Nothing is left to send, however often the app refreshes.
        await relaunched.refresh()
        await relaunched.sendUnsentBreath()
        let sent = world.backend.bodies("POST /v1/breath/sessions")
        // Three attempts while offline and one that got through, all the same session.
        let ids = try sent.map { try #require(try JSONSerialization.jsonObject(with: $0) as? [String: Any])["id"] as? String }
        #expect(Set(ids) == [run.id.uuidString])
        #expect(world.backend.requests.filter { $0 == "POST /v1/breath/sessions" }.count == ids.count)
        let last = try #require(world.backend.lastRequest("POST /v1/breath/sessions"))
        #expect(last.value(forHTTPHeaderField: "Authorization") == "Bearer device-token")
    }

    @Test func aSessionWhoseAnswerWasLostIsSentAgainUnderTheSameId() async throws {
        let (world, model) = await ready()
        // The backend stores the session, but its answer never arrives.
        world.backend.on(
            "POST /v1/breath/sessions", .init(status: 504, body: ""),
            .ok(Fixture.home(breath: Fixture.breath(holds: [[], [100, 100, 100, 100, 100, 100]], doneToday: true))))
        model.openBreathSession()
        let run = try runThrough(model, world)
        await eventually { model.isOffline }
        #expect(model.unsentBreath == [run.id])

        await model.refresh()
        #expect(model.unsentBreath.isEmpty)
        let bodies = world.backend.bodies("POST /v1/breath/sessions")
        #expect(bodies.count == 2)
        // The same session both times, under the same id, is what lets the
        // backend count it once.
        let sent = try bodies.map { try #require(try JSONSerialization.jsonObject(with: $0) as? NSDictionary) }
        #expect(sent[0] == sent[1])
        #expect(sent[0]["id"] as? String == run.id.uuidString)
    }

    @Test func onlineTheAnswerArrivesWhileTheDoneScreenIsUp() async throws {
        let (world, model) = await ready()
        world.backend.on(
            "POST /v1/breath/sessions",
            .ok(Fixture.home(breath: Fixture.breath(holds: [[], [100, 100, 100, 100, 100, 100]], doneToday: true))))
        model.openBreathSession()
        let run = try runThrough(model, world)
        await eventually { model.unsentBreath.isEmpty }
        #expect(model.unsentBreath.isEmpty)
        #expect(model.home?.breath?.done == 1)
        #expect(model.home?.breath?.table.lastHoldsMs.first == 100_000)
        // The cache holds the new state too, for the next launch offline.
        #expect(world.cache.load()?.snapshot.breath?.done == 1)
        #expect(model.breathSession?.run?.id == run.id)
        model.closeBreathSession()
        #expect(model.breathSession == nil)
    }

    @Test func aSessionStoppedBeforeItsFirstHoldLeavesNothing() async throws {
        let (world, model) = await ready()
        model.openBreathSession()
        let session = try #require(model.breathSession)
        session.start()
        #expect(world.breath.loadActive() != nil)
        world.time.advance(30)
        model.closeBreathSession()
        #expect(model.breathSession == nil)
        #expect(model.unsentBreath.isEmpty)
        #expect(world.breath.loadActive() == nil)
        #expect(world.breath.outbox().isEmpty)
        #expect(!world.backend.requests.contains("POST /v1/breath/sessions"))
    }

    @Test func aSessionInterruptedByClosingTheAppIsPickedUp() async throws {
        let (world, model) = await ready()
        model.openBreathSession()
        let session = try #require(model.breathSession)
        session.start()
        let run = try #require(session.run)
        world.time.now = moment(run, round: 1, 100)
        session.advance(to: world.time.now)
        session.tap()

        // Reopened during round 2: the timer is back, with round 1 kept.
        world.time.now = moment(run, round: 2, 50)
        let reopened = world.launch()
        let resumed = try #require(reopened.breathSession)
        #expect(resumed.run?.id == run.id)
        #expect(resumed.run?.holdsMs.first == 100_000)
        #expect(resumed.phase == .hold(round: 2, since: run.roundStart(2), roundEnds: run.roundStart(3)))

        // Reopened the next day instead: the rounds ran out long ago, and
        // what was recorded is waiting to be sent.
        world.time.now = run.scheduleEnds.addingTimeInterval(86_400)
        let nextDay = world.launch()
        #expect(nextDay.breathSession == nil)
        #expect(nextDay.unsentBreath == [run.id])
        #expect(world.breath.loadActive() == nil)
        #expect(world.breath.outbox().first?.endedAt == run.scheduleEnds)
    }

    @Test func aSessionTheServerRefusesStaysOnThePhoneAndIsSaidOutLoud() async throws {
        let (world, model) = await ready()
        world.backend.on("POST /v1/breath/sessions", .init(status: 400, body: #"{"error": "bad_request"}"#))
        model.openBreathSession()
        let run = try runThrough(model, world)
        await eventually { model.breathProblem != nil }
        #expect(model.breathProblem == "The server would not take a saved breath session (400). It stays on this phone.")
        #expect(model.unsentBreath == [run.id])
        #expect(world.breath.outbox().count == 1)
    }

    @Test func signingOutKeepsUnsentSessionsForTheNextSignIn() async throws {
        let (world, model) = await ready()
        world.backend.goDown()
        model.openBreathSession()
        let run = try runThrough(model, world)
        await eventually { model.isOffline }
        model.closeBreathSession()
        await model.signOut()
        #expect(model.phase == .signedOut)
        #expect(world.breath.outbox().map(\.id) == [run.id])
    }
}

@Suite struct BreathTextTests {
    private func breathHome(_ breath: String, done: Int = 0, streak: String? = nil, today: String = "2026-11-17")
        -> HomeSnapshot
    {
        Fixture.snapshot(done: done, streak: streak, today: today, breath: breath)
    }

    @Test func decodesBreathAsTheBackendSendsIt() throws {
        let home = breathHome(
            Fixture.breath(
                holds: [[125, 132, 120, 118, 121, 119], [150]],
                streak: Fixture.streak(weeks: 2, state: "recovering", remaining: 2, openDays: 6, recent: "KKA")))
        let breath = try #require(home.breath)
        #expect(breath.target == 3)
        #expect(breath.done == 1)
        #expect(breath.remaining == 2)
        #expect(breath.sessions.count == 2)
        #expect(breath.sessions[0].holdsMs == [125_000, 132_000, 120_000, 118_000, 121_000, 119_000])
        #expect(breath.sessions[0].counts)
        #expect(breath.sessions[1].holdsMs == [150_000, nil, nil, nil, nil, nil])
        #expect(!breath.sessions[1].counts)
        #expect(breath.streak.state == .recovering)
        #expect(breath.table.roundS == 240)
        #expect(breath.table.changedFromS == nil)
        #expect(breath.table.lastHoldsMs[1] == 132_000)
        #expect(breath.bestMs == 150_000)
        // And an answer from before breath sessions existed still decodes.
        #expect(Fixture.snapshot().breath == nil)
    }

    @Test func theTableIsExplainedInASentence() {
        #expect(
            BreathText.tableLine(Fixture.table())
                == "4:00 rounds to start. You move to 4:15 when recovery drops under 0:45.")
        #expect(
            BreathText.tableLine(Fixture.table(lastHolds: [125, 132, nil, nil, nil, nil]))
                == "4:00 rounds again. You move to 4:15 when recovery drops under 0:45.")
        var longer = Fixture.table(lastHolds: [180, 200, 170, nil, nil, nil], roundS: 255)
        longer.changedFromS = 240
        #expect(
            BreathText.tableLine(longer, next: true)
                == "4:15 rounds next, up from 4:00. Recovery dropped under 0:45, so the rounds get longer.")
        #expect(HomeText.tableLabel(Fixture.table()) == "6 ROUNDS OF 4:00 · 25 MIN")
    }

    @Test func theTimerSaysWhatToDoInEveryPhase() {
        var run = newRun(lastHolds: [125, 132, nil, nil, nil, nil])
        let ready = BreathText.look(for: run, at: start.addingTimeInterval(0.3))
        #expect(ready.giant == "0:10")
        #expect(ready.word == "BREATHE")
        #expect(ready.small == "HOLD AT THE TONE · TO BEAT 2:05")
        #expect(ready.barBig == "HOLD")
        #expect(!ready.holding)

        let at = moment(run, round: 1, 102.6)
        let hold = BreathText.look(for: run, at: at)
        #expect(hold.topLeft == "ROUND 1 / 6")
        #expect(hold.topRight == "ENDS IN 2:18")
        #expect(hold.giant == "1:42")
        #expect(hold.word == "HOLD")
        #expect(hold.small == "4:00 ROUNDS · SET BY LYFE · TO BEAT 2:05")
        #expect(hold.barBig == "BREATHE")
        #expect(hold.holding)

        run.tap(at: moment(run, round: 1, 131))
        let after = moment(run, round: 1, 132)
        let recover = BreathText.look(for: run, at: after)
        #expect(recover.topRight == "HELD 2:11 ▲")
        #expect(recover.giant == "1:48")
        #expect(recover.word == "BREATHE")
        #expect(recover.small == "NEXT HOLD AT THE TONE · TO BEAT 2:12")
        #expect(recover.barSmall == "NEXT · ROUND 2 OF 6")
        #expect(!recover.holding)
    }

    @Test func theScreenGoesToHoldWhenTheRoundBeginsWhateverElseIsLate() {
        // Round 1 was tapped; nothing has touched the run since.
        var run = newRun()
        run.tap(at: moment(run, round: 1, 100))
        let before = BreathText.look(for: run, at: moment(run, round: 1, 239.5))
        #expect(before.word == "BREATHE")
        #expect(before.giant == "0:01")

        // The tone sounds at the start of round 2. From the run and the time
        // alone, the screen is on HOLD and counting, with nothing telling it.
        let onTheTone = BreathText.look(for: run, at: moment(run, round: 2, 0))
        #expect(onTheTone.word == "HOLD")
        #expect(onTheTone.giant == "0:00")
        #expect(onTheTone.topLeft == "ROUND 2 / 6")
        let after = BreathText.look(for: run, at: moment(run, round: 2, 3.4))
        #expect(after.word == "HOLD")
        #expect(after.giant == "0:03")
        #expect(after.barBig == "BREATHE")
        #expect(after.holding)
    }

    @Test func theHoldScreenTurnsBlueOncePastLastTime() {
        #expect(BreathText.holdColours(heldMs: 0, toBeatMs: 120_000).background == Poster.yellow.mix(with: Poster.red, by: 0))
        #expect(BreathText.holdColours(heldMs: 119_000, toBeatMs: 120_000).ink == Poster.ink)
        let past = BreathText.holdColours(heldMs: 120_000, toBeatMs: 120_000)
        #expect(past.background == Poster.blue)
        #expect(past.ink == Poster.paper)
        // With nothing to beat it reaches red and stays there.
        #expect(BreathText.holdColours(heldMs: 500_000, toBeatMs: nil).background == Poster.yellow.mix(with: Poster.red, by: 1))
    }

    @Test func afterASessionTheBackendsAnswerIsShown() {
        var run = BreathRun(
            id: UUID(uuidString: confirmedID)!,
            table: Fixture.table(lastHolds: [125, 125, 120, 118, 121, 119]), startedAt: start)
        for (round, seconds) in [125.0, 132, 120, 118, 121, 119].enumerated() {
            run.tap(at: moment(run, round: round + 1, seconds))
        }
        let home = breathHome(
            Fixture.breath(
                holds: [[125, 132, 120, 118, 121, 119], [120, 120, 120]],
                streak: Fixture.streak(weeks: 5, state: "on_track", remaining: 1, openDays: 5, recent: "KKKKK")))
        let text = BreathText.done(
            run: run, breath: home.breath, unsent: false, today: home.today, weekEnds: home.week.endsOn)
        #expect(text.comparison == "▲ 0:07 ON LAST SESSION")
        #expect(text.rows.map(\.0) == ["MEAN", "TIGHTEST RECOVERY", "THIS WEEK"])
        #expect(text.rows.map(\.1) == ["2:02", "1:48", "2 OF 3"])
        #expect(text.calloutLabel == "Next table")
        #expect(text.callout == "4:00 rounds again. You move to 4:15 when recovery drops under 0:45.")
        #expect(text.barSmall == "STREAK SAFE WITH 1 MORE BY SUNDAY")
    }

    @Test func afterASessionOfflineOnlyWhatWasCapturedIsShown() {
        var run = newRun()
        run.tap(at: moment(run, round: 1, 95))
        run.tap(at: moment(run, round: 2, 90))
        run.tap(at: moment(run, round: 3, 88))
        let text = BreathText.done(run: run, breath: nil, unsent: true, today: nil, weekEnds: nil)
        #expect(text.comparison == "FIRST SESSION ON RECORD")
        #expect(text.rows.map(\.1) == ["1:31", "2:25", "NOT SENT YET"])
        #expect(text.calloutLabel == "Saved on this phone")
        #expect(text.barSmall == "SENDS WHEN THE SERVER IS REACHABLE")
    }

    @Test func afterASessionTheWeekAndTheShortfallAreNamed() {
        var run = BreathRun(
            id: UUID(uuidString: confirmedID)!,
            table: Fixture.table(lastHolds: [125, 132, 120, nil, nil, nil]), startedAt: start)
        run.tap(at: moment(run, round: 1, 127))
        run.stop(at: moment(run, round: 2, 10))

        // One hold: under last session's best, and too short to count.
        let short = breathHome(Fixture.breath(holds: [[127]], lastHolds: [125, 132, 120, nil, nil, nil]))
        let text = BreathText.done(
            run: run, breath: short.breath, unsent: false, today: short.today, weekEnds: short.week.endsOn)
        #expect(text.comparison == "▼ 0:05 UNDER LAST SESSION")
        #expect(text.calloutLabel == "Not counted")
        #expect(text.barSmall == "3 MORE BY SUNDAY STARTS A STREAK")

        // The session that completes the week.
        let kept = breathHome(
            Fixture.breath(
                holds: [[127, 120, 118], [120, 120, 120], [120, 120, 120]],
                streak: Fixture.streak(weeks: 6, state: "kept", remaining: 0, openDays: 4, recent: "KKKKK")))
        let done = BreathText.done(
            run: run, breath: kept.breath, unsent: false, today: kept.today, weekEnds: kept.week.endsOn)
        #expect(done.barSmall == "WEEK DONE · 6 WEEKS IN A ROW")
        #expect(done.calloutLabel == "Next table")
    }
}

@Suite struct TwoRoutineHomeTests {
    private let gymOnTrack = Fixture.streak(weeks: 6, state: "on_track", remaining: 3, openDays: 6, recent: "KKKKKK")

    private func home(gymDone: Int, gym: String, breath: String, today: String = "2026-11-17") -> HomeSnapshot {
        Fixture.snapshot(done: gymDone, streak: gym, today: today, breath: breath)
    }

    private func breathStreak(remaining: Int, openDays: Int, state: String = "on_track") -> String {
        Fixture.streak(weeks: 4, state: state, remaining: remaining, openDays: openDays, recent: "KKKK")
    }

    @Test func theBreathBandReadsLikeTheGymBand() throws {
        let snapshot = home(
            gymDone: 1, gym: gymOnTrack,
            breath: Fixture.breath(holds: [[100, 100, 100]], streak: breathStreak(remaining: 2, openDays: 6)))
        let breath = try #require(snapshot.breath)
        let lines = HomeText.weekLines(for: breath.streak, home: snapshot)
        #expect(lines.headline == "WEEKS IN A ROW")
        #expect(lines.detail == "2 MORE BY SUNDAY")
        #expect(
            HomeText.spoken("Breath", streak: breath.streak, done: breath.done, target: breath.target)
                == "Breath: 4 weeks in a row. 1 of 3 sessions this week.")
    }

    @Test func theGymGoesFirstUntilTodaysSessionIsRecorded() {
        // Monday was trained; today (Tuesday) is not yet.
        let morning = home(
            gymDone: 1, gym: gymOnTrack, breath: Fixture.breath(streak: breathStreak(remaining: 3, openDays: 6)))
        let first = HomeText.next(for: morning)
        #expect(first.big == "GYM SESSION")
        #expect(!first.opensBreath)

        // The watch has synced today's session: breath is next, and the bar opens it.
        let trained = Fixture.streak(weeks: 6, state: "on_track", remaining: 2, openDays: 5, recent: "KKKKKK")
        let evening = home(
            gymDone: 2, gym: trained, breath: Fixture.breath(streak: breathStreak(remaining: 3, openDays: 6)))
        let next = HomeText.next(for: evening)
        #expect(next == HomeText.Next(small: "NEXT · 3 MORE BY SUNDAY · 25 MIN", big: "BREATH SESSION", opensBreath: true))
    }

    @Test func theRoutineWithLessRoomToSpareIsNext() {
        // The gym has three days to spare, breath none.
        let tight = home(
            gymDone: 1, gym: gymOnTrack, breath: Fixture.breath(streak: breathStreak(remaining: 3, openDays: 3)))
        let next = HomeText.next(for: tight)
        #expect(next.big == "BREATH SESSION")
        #expect(next.small == "NEEDED TODAY · 3 MORE BY SUNDAY · 25 MIN")

        let recovering = home(
            gymDone: 2, gym: Fixture.streak(weeks: 6, state: "on_track", remaining: 2, openDays: 5, recent: "KKKKKK"),
            breath: Fixture.breath(streak: breathStreak(remaining: 3, openDays: 6, state: "recovering")))
        #expect(HomeText.next(for: recovering).small == "RECOVERY · 3 MORE BY SUNDAY · 25 MIN")
    }

    @Test func onceBothAreDoneForTodayTheBarSaysWhatTheWeekStillNeeds() {
        let trained = Fixture.streak(weeks: 6, state: "on_track", remaining: 2, openDays: 5, recent: "KKKKKK")
        let both = home(
            gymDone: 2, gym: trained,
            breath: Fixture.breath(
                holds: [[], [100, 100, 100]], streak: breathStreak(remaining: 2, openDays: 5), doneToday: true))
        #expect(HomeText.next(for: both) == HomeText.Next(small: "GYM 2 MORE · BREATH 2 MORE BY SUNDAY", big: "DONE FOR TODAY"))

        // Breath week already kept: only the gym is named.
        let breathKept = home(
            gymDone: 2, gym: trained,
            breath: Fixture.breath(
                holds: [[100, 100, 100], [100, 100, 100], [100, 100, 100]],
                streak: Fixture.streak(weeks: 5, state: "kept", remaining: 0, openDays: 5, recent: "KKKK"),
                doneToday: true))
        #expect(HomeText.next(for: breathKept).small == "GYM 2 MORE BY SUNDAY")
    }

    @Test func aWeekKeptInBothSaysSo() {
        let gymKept = Fixture.streak(weeks: 7, state: "kept", remaining: 0, openDays: 3, recent: "KKKKKK")
        let snapshot = Fixture.snapshot(
            done: 2, streak: gymKept,
            breath: Fixture.breath(
                holds: [[100, 100, 100], [100, 100, 100], [100, 100, 100]],
                streak: Fixture.streak(weeks: 5, state: "kept", remaining: 0, openDays: 5, recent: "KKKK")))
        // The fixture lists two gym sessions; the week's count is what matters here.
        var kept = snapshot
        kept.gym.done = 4
        kept.gym.remaining = 0
        #expect(HomeText.next(for: kept) == HomeText.Next(small: "GYM 4 · BREATH 3 SESSIONS", big: "WEEK DONE"))
    }

    @Test func aWeekOutOfReachIsNamedByRoutine() {
        let trained = Fixture.streak(weeks: 6, state: "on_track", remaining: 2, openDays: 5, recent: "KKKKKK")
        let lost = home(
            gymDone: 2, gym: trained, breath: Fixture.breath(streak: breathStreak(remaining: 3, openDays: 2)))
        let next = HomeText.next(for: lost)
        #expect(next == HomeText.Next(small: "BREATH · THIS WEEK IS OUT OF REACH", big: "NEXT WEEK RECOVERS IT"))
    }

    @Test func theWeeksSessionsAreListedByDayForBothRoutines() {
        let snapshot = home(
            gymDone: 2, gym: gymOnTrack,
            breath: Fixture.breath(holds: [[125, 132, 120], [150]], streak: breathStreak(remaining: 2, openDays: 6)))
        let rows = HomeText.sessionRows(for: snapshot)
        #expect(rows.map(\.day) == ["MON", "MON", "TUE", "TUE"])
        #expect(rows.map(\.label) == ["STRENGTH TRAINING", "BREATH", "LAP SWIMMING", "BREATH · TOO SHORT TO COUNT"])
        #expect(rows.map(\.value) == ["58 MIN", "BEST 2:12", "41 MIN", "BEST 2:30"])
        #expect(rows.map(\.counts) == [true, true, true, false])
    }

    @Test func sessionsWaitingOnThePhoneAreMentioned() {
        #expect(
            HomeText.unsentBreath(1)
                == "1 breath session is saved on this phone. It is sent when the server can be reached.")
        #expect(HomeText.unsentBreath(2).hasPrefix("2 breath sessions are saved"))
    }
}

/// Runs the app's own client against a backend started for the purpose,
/// to prove the two agree on what is sent and answered. It records a
/// session, so point it at a scratch database, never the real one:
/// `LYFE_LOCAL_SERVER=http://127.0.0.1:8799 LYFE_LOCAL_PASSWORD=... swift test`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LYFE_LOCAL_SERVER"] != nil))
struct BreathAgainstARealBackendTests {
    @Test func aSessionSentTwiceIsCountedOnceAndSetsTheNextTable() async throws {
        let environment = ProcessInfo.processInfo.environment
        let world = World(address: environment["LYFE_LOCAL_SERVER"])
        let model = world.launch(transport: URLSessionTransport())
        world.time.now = Date()
        await model.signIn(password: environment["LYFE_LOCAL_PASSWORD"] ?? "")
        #expect(model.phase == .signedIn, "\(model.signInProblem ?? "")")
        let before = try #require(model.home?.breath)

        // A session on the table the backend set, holds a little over last time's.
        model.openBreathSession()
        let session = try #require(model.breathSession)
        session.start()
        let started = try #require(session.run)
        for round in 1...started.table.rounds {
            let hold = Double((started.holdToBeat(round: round) ?? 60_000) / 1000 + 2)
            world.time.now = started.roundStart(round).addingTimeInterval(hold)
            session.advance(to: world.time.now)
            session.tap()
        }
        let run = try #require(session.run)
        // A real server answers in real time, not within so many yields.
        for _ in 0..<100 where !model.unsentBreath.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(model.unsentBreath.isEmpty, "\(model.breathProblem ?? model.offlineReason ?? "")")

        let after = try #require(model.home?.breath)
        let stored = try #require(after.sessions.first { $0.id == run.id })
        #expect(stored.holdsMs == run.holdsMs)
        #expect(stored.bestMs == run.bestMs)
        #expect(stored.counts)
        #expect(after.table.lastHoldsMs == run.holdsMs)
        #expect(after.sessions.count == before.sessions.count + 1)

        // The same session again, as after a lost answer: nothing changes.
        world.breath.enqueue(run)
        let again = world.launch(transport: URLSessionTransport())
        #expect(again.unsentBreath == [run.id])
        await again.refresh()
        #expect(again.unsentBreath.isEmpty)
        #expect(again.home?.breath?.sessions == after.sessions)
        #expect(again.home?.breath?.done == after.done)
    }
}
