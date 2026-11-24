import Foundation
import Testing

@testable import LyfeKit

private let start = Date(timeIntervalSince1970: 1_795_000_000)

@Suite struct StudyRunTests {
    @Test func theTimeOnItIsTheTimeSinceStartLessPauses() {
        var run = StudyRun(subject: "System design", kind: .questions, startedAt: start)
        #expect(run.activeSeconds(at: start.addingTimeInterval(600)) == 600)
        run.pause(at: start.addingTimeInterval(600))
        #expect(run.isPaused)
        // A paused timer does not move, however long the phone is away.
        #expect(run.activeSeconds(at: start.addingTimeInterval(1500)) == 600)
        run.resume(at: start.addingTimeInterval(1500))
        #expect(run.activeSeconds(at: start.addingTimeInterval(2100)) == 1200)
        run.stop(at: start.addingTimeInterval(2400))
        #expect(run.isEnded)
        // Once ended it stays where it ended.
        #expect(run.activeSeconds(at: start.addingTimeInterval(9000)) == 1500)
    }

    @Test func theStartCanBeMovedBackTwoHoursAtMost() {
        var run = StudyRun(subject: "System design", kind: .reading, startedAt: start)
        run.startEarlier(by: 30 * 60)
        #expect(run.activeSeconds(at: start) == 1800)
        run.startEarlier(by: 120 * 60)
        #expect(run.movedBackS == StudyRun.longestMoveBack)
        #expect(run.activeSeconds(at: start) == 7200)
        #expect(StudyText.earlierChoices(movedBack: run.movedBackS).isEmpty)
        #expect(StudyText.earlierChoices(movedBack: 100 * 60) == [10, 15])
    }

    @Test func aTimerLeftRunningEndsItselfWhereItReachedTheLimit() {
        var run = StudyRun(subject: "System design", kind: .questions, startedAt: start)
        run.settle(at: start.addingTimeInterval(3 * 3600 - 1), stopAfter: 3 * 3600)
        #expect(!run.isEnded)
        run.settle(at: start.addingTimeInterval(5 * 3600), stopAfter: 3 * 3600)
        #expect(run.endedAt == start.addingTimeInterval(3 * 3600))
        #expect(run.endedItself)
        // The owner says they stopped an hour and a half before that.
        run.stoppedEarlier(by: 90 * 60)
        #expect(run.activeSeconds(at: .distantFuture) == 90 * 60)
        #expect(run.stoppedEarlierBy == 90 * 60)
        // Never before the start, and saying "then" puts it back.
        run.stoppedEarlier(by: 10 * 3600)
        #expect(run.activeSeconds(at: .distantFuture) == 0)
        run.stoppedEarlier(by: 0)
        #expect(run.activeSeconds(at: .distantFuture) == 3 * 3600)
    }

    @Test func aPauseLeftTooLongEndsTheSessionWhereThePauseBegan() {
        var run = StudyRun(subject: "System design", kind: .questions, startedAt: start)
        run.pause(at: start.addingTimeInterval(50 * 60))
        run.settle(at: start.addingTimeInterval(3 * 3600), stopAfter: 3 * 3600)
        #expect(!run.isEnded)
        run.settle(at: start.addingTimeInterval(3 * 3600 + 50 * 60), stopAfter: 3 * 3600)
        #expect(run.endedAt == start.addingTimeInterval(50 * 60))
        #expect(run.activeSeconds(at: .distantFuture) == 50 * 60)
        #expect(!run.isPaused)
    }

    @Test func whetherItCountsIsPreviewedFromTimeAndExplainBack() {
        let rules = StudyRules()
        var run = StudyRun(subject: "lyfe", kind: .build, startedAt: start)
        run.stop(at: start.addingTimeInterval(50 * 60))
        #expect(!run.wouldCount(rules: rules, at: .distantFuture))
        #expect(StudyText.verdict(run, rules: rules) == "Study · counts once explained")
        run.explainBack = "  \n "
        #expect(!run.wouldCount(rules: rules, at: .distantFuture))
        run.explainBack = "The timer, from the clock"
        #expect(run.wouldCount(rules: rules, at: .distantFuture))
        var short = StudyRun(subject: "lyfe", kind: .reading, startedAt: start)
        short.stop(at: start.addingTimeInterval(44 * 60))
        #expect(StudyText.verdict(short, rules: rules) == "Under 45 min · kept, not counted")
    }

    @Test func aSessionIsSentInTheShapeTheBackendTakes() throws {
        var run = StudyRun(
            id: UUID(uuidString: "00000000-0000-4000-a000-000000000001")!, subject: "System design", kind: .questions,
            startedAt: start)
        run.pause(at: start.addingTimeInterval(600))
        run.resume(at: start.addingTimeInterval(900))
        run.stop(at: start.addingTimeInterval(3300))
        run.answered = 12
        run.rightFirst = 30
        run.explainBack = "  "
        let json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder.lyfe.encode(StudySessionUpload(run))) as? [String: Any])
        #expect(json["id"] as? String == "00000000-0000-4000-A000-000000000001")
        #expect(json["active_s"] as? Int == 3000)
        #expect(json["subject"] as? String == "System design")
        #expect(json["kind"] as? String == "questions")
        #expect(json["answered"] as? Int == 12)
        // Never more right than answered.
        #expect(json["right_first"] as? Int == 12)
        #expect(json["explain_back"] == nil)
        #expect(json["started_at"] as? String == "2026-11-18T11:06:40Z")
        #expect(json["ended_at"] as? String == "2026-11-18T12:01:40Z")
    }

    @Test func clocksReadAsMinutesUntilAnHourAndHoursAfter() {
        #expect(StudyText.clock(0) == "0:00")
        #expect(StudyText.clock(52 * 60 + 14.9) == "52:14")
        #expect(StudyText.clock(3600 + 5 * 60 + 9) == "1:05:09")
        #expect(StudyText.hoursMinutes(92 * 60 + 30) == "1:32")
        #expect(StudyText.counting(10 * 60, rules: StudyRules()) == "Counts at 45:00 · 35:00 to go")
        #expect(StudyText.counting(46 * 60, rules: StudyRules()) == "Counted · 45:00 passed")
        #expect(StudyText.toTarget(52 * 60 + 14, rules: StudyRules()) == "37:46 to the target")
        #expect(StudyText.notCounted("builds_used", rules: StudyRules()) == "2 builds already counted")
    }
}

@Suite struct StudyStoreTests {
    @Test func theSessionInProgressAndTheOutboxSurviveBeingWrittenAndRead() {
        let store = StudyStore(directory: Fixture.temporaryDirectory())
        var run = StudyRun(subject: "System design", kind: .reading, startedAt: start)
        run.pause(at: start.addingTimeInterval(61.5))
        store.saveActive(run)
        #expect(store.loadActive() == run)
        store.clearActive()
        #expect(store.loadActive() == nil)

        let other = StudyRun(subject: "Models", kind: .questions, startedAt: start)
        store.enqueue(run)
        store.enqueue(other)
        store.enqueue(run)
        #expect(store.outbox().map(\.id) == [run.id, other.id])
        store.remove(run.id)
        #expect(store.outbox().map(\.id) == [other.id])
    }
}

extension Fixture {
    /// Study in exactly the shape the backend sends.
    static func study(done: Int = 0, subjects: [String] = ["System design"], builds: Int = 0) -> String {
        let subjectsJSON = subjects.enumerated().map { index, name in
            """
            {"id": "00000000-0000-4000-b000-00000000000\(index + 1)", "name": "\(name)", "minutes": \(90 * (index + 1)),
             "sessions": \(index + 1), "last": "2026-11-1\(6 - index)"}
            """
        }
        let sessions = (0..<done).map { index in
            """
            {"id": "00000000-0000-4000-a000-00000000010\(index)", "date": "2026-11-1\(6 + index)", "minutes": 92,
             "subject": "System design", "kind": "questions", "answered": 12, "right_first": 8, "counts": true,
             "not_counted": null}
            """
        }
        return """
            {"target": 4, "done": \(done), "remaining": \(4 - done), "done_today": false, "minutes": \(92 * done),
             "builds": \(builds), "sessions": [\(sessions.joined(separator: ","))],
             "streak": \(Fixture.streak(weeks: 2, remaining: 4 - done)),
             "subjects": [\(subjectsJSON.joined(separator: ","))],
             "rules": {"min_minutes": 45, "target_minutes": 90, "builds_per_week": 2, "stop_after_minutes": 180}}
            """
    }

    static func homeWithStudy(done: Int = 0, subjects: [String] = ["System design"]) -> String {
        let home = Fixture.home()
        let cut = home.range(of: "\"sources\"")!.lowerBound
        return home[..<cut] + "\"study\": \(study(done: done, subjects: subjects)),\n  " + home[cut...]
    }
}

@MainActor
@Suite struct StudyAppTests {
    @Test func studyDecodesAsTheBackendSendsIt() throws {
        let snapshot = try JSONDecoder.lyfe.decode(HomeSnapshot.self, from: Data(Fixture.homeWithStudy(done: 1).utf8))
        let study = try #require(snapshot.study)
        #expect((study.done, study.target, study.minutes) == (1, 4, 92))
        #expect(study.sessions[0].kind == .questions)
        #expect((study.sessions[0].answered, study.sessions[0].rightFirst) == (12, 8))
        #expect(study.subjects.map(\.name) == ["System design"])
        #expect(study.rules == StudyRules())
        // An answer from before study sessions existed still reads.
        let old = try JSONDecoder.lyfe.decode(HomeSnapshot.self, from: Data(Fixture.home().utf8))
        #expect(old.study == nil)
    }

    @Test func aSessionTimedOfflineIsKeptAndSentOnceOnReconnect() async throws {
        let world = World.signedIn()
        world.backend.on("GET /v1/home", .ok(Fixture.homeWithStudy()))
        world.backend.on("POST /v1/sync", .ok(#"{"garmin": {"state": "ok"}}"#))
        let model = world.launch()
        await model.refresh()
        #expect(model.studySubjects == ["System design"])

        world.backend.goDown()
        model.openStudy()
        #expect(model.isStudyOpen)
        model.startStudy(subject: "  Local   models ", kind: .reading)
        let run = try #require(model.studyRun)
        #expect(run.subject == "Local models")
        // Closing the screen leaves the timer running.
        model.closeStudy()
        world.time.advance(50 * 60)
        #expect(model.studyRun.map { Int($0.activeSeconds(at: world.time.now)) } == 3000)
        model.openStudy()
        model.endStudy()
        model.changeStudy { $0.kind = .questions }
        await model.finishStudy()
        #expect(model.studyRun == nil)
        #expect(!model.isStudyOpen)
        #expect(model.unsentStudy == [run.id])
        // The new subject is offered before the backend has heard of it.
        #expect(model.studySubjects == ["Local models", "System design"])

        // Tried while offline, and not taken.
        let tried = world.backend.bodies("POST /v1/study/sessions").count
        world.backend.goDown(false)
        let after = Fixture.homeWithStudy(done: 1, subjects: ["Local models", "System design"])
        world.backend.on("POST /v1/study/sessions", .ok(after))
        world.backend.on("GET /v1/home", .ok(after))
        await model.refresh()
        #expect(model.unsentStudy.isEmpty)
        #expect(model.home?.study?.done == 1)
        let sent = world.backend.bodies("POST /v1/study/sessions").dropFirst(tried)
        #expect(sent.count == 1)
        let body = try #require(try JSONSerialization.jsonObject(with: sent.first!) as? [String: Any])
        #expect(body["active_s"] as? Int == 3000)
        #expect(body["kind"] as? String == "questions")
        await model.refresh()
        #expect(world.backend.bodies("POST /v1/study/sessions").count == tried + 1)
    }

    @Test func aTimerRunningWhenLyfeClosedIsBackOnScreenAndEndedIfLeftTooLong() async throws {
        let world = World.signedIn()
        let first = world.launch()
        first.startStudy(subject: "System design", kind: .questions)
        let id = try #require(first.studyRun?.id)

        // Opened again twenty minutes later: still running, on screen.
        world.time.advance(20 * 60)
        let second = world.launch()
        #expect(second.studyRun?.id == id)
        #expect(second.isStudyOpen)
        #expect(second.studyRun?.isEnded == false)

        // Opened again the next morning: it stopped itself at three hours.
        world.time.advance(12 * 3600)
        let third = world.launch()
        let run = try #require(third.studyRun)
        #expect(run.isEnded && run.endedItself)
        #expect(run.activeSeconds(at: world.time.now) == 3 * 3600)
    }

    @Test func aSessionStartedByMistakeIsThrownAway() async throws {
        let world = World.signedIn()
        let model = world.launch()
        model.startStudy(subject: "System design", kind: .questions)
        model.discardStudy()
        #expect(model.studyRun == nil)
        #expect(model.unsentStudy.isEmpty)
        #expect(world.launch().studyRun == nil)
        // A subject of nothing but spaces starts nothing.
        model.startStudy(subject: "   ", kind: .questions)
        #expect(model.studyRun == nil)
    }

    @Test func aSessionTheServerRefusesStaysOnThePhoneAndIsSaidOutLoud() async throws {
        let world = World.signedIn()
        world.backend.on("POST /v1/study/sessions", StubBackend.Reply(status: 400, body: #"{"error": "bad_request"}"#))
        let model = world.launch()
        model.startStudy(subject: "System design", kind: .reading)
        world.time.advance(3000)
        model.endStudy()
        await model.finishStudy()
        #expect(model.unsentStudy.count == 1)
        #expect(model.studyProblem == "The server would not take a saved study session (400). It stays on this phone.")
    }

    @Test func homeSaysWhereTheTimerIs() {
        var run = StudyRun(subject: "System design", kind: .questions, startedAt: start)
        let later = start.addingTimeInterval(52 * 60 + 14)
        #expect(StudyText.homeFigure(nil, running: run, now: later) == "52:14")
        #expect(StudyText.homeCaption(nil, running: run, now: later) == "Running · 52:14")
        run.pause(at: later)
        #expect(StudyText.homeCaption(nil, running: run, now: later.addingTimeInterval(600)) == "Paused · 52:14")
        run.stop(at: later)
        #expect(StudyText.homeCaption(nil, running: run, now: later) == "Session ended · say what it was")
        #expect(StudyText.homeFigure(nil, running: nil, now: later) == "—")
    }
}
