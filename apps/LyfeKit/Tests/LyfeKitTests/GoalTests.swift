import Foundation
import Testing

@testable import LyfeKit

extension Fixture {
    /// One goal in exactly the shape the backend sends.
    static func goal(
        _ n: Int, reading: String = "breath_hold", status: String = "active", start: Double = 140, target: Double = 180,
        current: Double? = 146, aheadBy: Double = -4, reached: Bool = false, movedBy: String = "breath"
    ) -> String {
        let standing =
            current.map { current in
                """
                {"current": \(current), "progress": 0.15, "pace_value": 150, "ahead_by": \(aheadBy),
                 "needed_per_week": \(reached ? "null" : "1.13"), "pace_per_week": 1, "reached": \(reached)}
                """
            } ?? "null"
        return """
            {"id": "00000000-0000-4000-c000-00000000000\(n)", "title": "Goal \(n)", "shape": "reach", "reading": "\(reading)",
             "subject_id": null, "subject": null, "start_on": "2026-11-02", "start_value": \(start),
             "target_value": \(target), "due_on": "2027-08-09", "status": "\(status)",
             "ended_on": \(status == "reached" || status == "dropped" ? "\"2026-11-20\"" : "null"), "note": null,
             "days_left": 258, "moved_by": "\(movedBy)", "standing": \(standing),
             "changes": [{"on": "2026-11-10", "what": "target", "was": "170", "now": "180"}]}
            """
    }

    static func homeWithGoals(_ goals: [String], limit: Int = 3) -> String {
        let home = Fixture.home()
        let cut = home.range(of: "\"sources\"")!.lowerBound
        return home[..<cut] + "\"goals\": {\"limit\": \(limit), \"goals\": [\(goals.joined(separator: ","))]},\n  "
            + home[cut...]
    }
}

@Suite struct GoalTextTests {
    @Test func goalsDecodeAsTheBackendSendsThem() throws {
        let home = try JSONDecoder.lyfe.decode(
            HomeSnapshot.self,
            from: Data(Fixture.homeWithGoals([Fixture.goal(1), Fixture.goal(2, status: "parked", current: nil)]).utf8))
        let goals = try #require(home.goals)
        #expect(goals.limit == 3)
        #expect(goals.active.map(\.title) == ["Goal 1"])
        #expect(goals.parked.first?.standing == nil)
        let goal = goals.goals[0]
        #expect(goal.reading == .breathHold)
        #expect(goal.standing?.aheadBy == -4)
        #expect(goal.changes.first?.what == "target")
        #expect(goal.dueOn == CalendarDay(year: 2027, month: 8, day: 9))
        // An answer from before goals existed still reads.
        #expect(try JSONDecoder.lyfe.decode(HomeSnapshot.self, from: Data(Fixture.home().utf8)).goals == nil)
    }

    @Test func figuresAreShownInTheOwnersUnits() {
        #expect(GoalText.figure(180, .breathHold, weightUnit: "kg") == "3:00")
        #expect(GoalText.figure(78_000, .weight, weightUnit: "kg") == "78.0 kg")
        #expect(GoalText.figure(78_000, .weight, weightUnit: "lb") == "172.0 lb")
        #expect(GoalText.figure(17, .bodyFat, weightUnit: "lb") == "17.0%")
        #expect(GoalText.figure(2850, .studyMinutes, weightUnit: "lb") == "47.5 h")
        #expect(GoalText.figure(12_000, .studyMinutes, weightUnit: "lb") == "200 h")
        #expect(GoalText.bare(2850, .studyMinutes, weightUnit: "lb") == "47.5")
    }

    @Test func typedFiguresAreReadIntoTheReadingsOwnUnit() {
        #expect(GoalText.parse("3:00", .breathHold, weightUnit: "kg") == 180)
        #expect(GoalText.parse("150", .breathHold, weightUnit: "kg") == 150)
        #expect(GoalText.parse("2:75", .breathHold, weightUnit: "kg") == nil)
        #expect(GoalText.parse("78", .weight, weightUnit: "kg") == 78_000)
        #expect(GoalText.parse("172,5", .weight, weightUnit: "lb").map { ($0 * 10).rounded() / 10 } == 78_244.7)
        #expect(GoalText.parse("17", .bodyFat, weightUnit: "kg") == 17)
        #expect(GoalText.parse("80", .studyMinutes, weightUnit: "kg") == 4800)
        #expect(GoalText.parse("", .studyMinutes, weightUnit: "kg") == nil)
        #expect(GoalText.parse("-3", .studyMinutes, weightUnit: "kg") == nil)
    }

    @Test func paceIsAnAmountNeverAFailure() throws {
        func decoded(_ json: String) throws -> Goal {
            try JSONDecoder.lyfe.decode(Goal.self, from: Data(json.utf8))
        }
        #expect(GoalText.pace(try decoded(Fixture.goal(1)), weightUnit: "kg") == "0:04 behind pace")
        #expect(GoalText.pace(try decoded(Fixture.goal(1, aheadBy: 5)), weightUnit: "kg") == "0:05 ahead of pace")
        #expect(GoalText.pace(try decoded(Fixture.goal(1, aheadBy: 0.4)), weightUnit: "kg") == "On the line")
        #expect(GoalText.pace(try decoded(Fixture.goal(1, reached: true)), weightUnit: "kg") == "Reached")
        #expect(GoalText.pace(try decoded(Fixture.goal(1, current: nil)), weightUnit: "kg") == "No reading yet")
        let goal = try decoded(Fixture.goal(1))
        #expect(GoalText.aim(goal, weightUnit: "kg") == "3:00 by 9 Aug 2027")
        #expect(GoalText.needed(goal, weightUnit: "kg") == "0:01 a week from now · the line asks 0:01")
        #expect(GoalText.change(goal.changes[0], reading: .breathHold, weightUnit: "kg") == "Figure 2:50 → 3:00")
        #expect(GoalList.right(try decoded(Fixture.goal(3, status: "reached")), weightUnit: "kg") == "Reached 20 Nov 2026")
    }

    @Test func theEditorOffersOnlyReadingsLyfeHas() {
        #expect(GoalEditorView.now(.weight, home: nil, weightUnit: "kg") == nil)
        #expect(GoalEditorView.now(.bodyFat, home: nil, weightUnit: "kg") == nil)
        #expect(GoalEditorView.now(.breathHold, home: nil, weightUnit: "kg") == "Best 0:00")
        #expect(GoalEditorView.now(.studyMinutes, home: nil, weightUnit: "kg") == "From today")
        #expect(CalendarDay(year: 2026, month: 12, day: 30).adding(days: 3) == CalendarDay(year: 2027, month: 1, day: 2))
    }
}

@MainActor
@Suite struct GoalAppTests {
    @Test func aGoalIsSetAndOpensOnItsOwnScreen() async throws {
        let world = World.signedIn()
        let goal = Fixture.goal(1)
        world.backend.on("PUT /v1/goals/00000000-0000-4000-c000-000000000001", .ok(Fixture.homeWithGoals([goal])))
        let model = world.launch()
        model.openGoals()
        let id = UUID(uuidString: "00000000-0000-4000-C000-000000000001")!
        model.openGoalEditor(.new(id))
        #expect(model.goalEditor?.id == id)
        let problem = await model.saveGoal(
            id: id,
            GoalRequest(
                title: nil, reading: .breathHold, subject: nil, targetValue: 180,
                dueOn: CalendarDay(year: 2027, month: 8, day: 9)))
        #expect(problem == nil)
        #expect(model.goalEditor == nil)
        #expect(model.openGoalId == id)
        #expect(model.home?.goals?.active.count == 1)
        let body = try #require(world.backend.bodies("PUT /v1/goals/00000000-0000-4000-c000-000000000001").first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["reading"] as? String == "breath_hold")
        #expect(json["target_value"] as? Double == 180)
        #expect(json["due_on"] as? String == "2027-08-09")
        #expect(json["subject"] == nil)
    }

    @Test func aFourthGoalIsNotMadeActiveAndNeedsAConnectionToChange() async throws {
        let world = World.signedIn()
        let full = Fixture.homeWithGoals([
            Fixture.goal(1), Fixture.goal(2), Fixture.goal(3), Fixture.goal(4, status: "parked"),
        ])
        world.backend.on("GET /v1/home", .ok(full))
        world.backend.on("POST /v1/sync", .ok(#"{"garmin": {"state": "ok"}}"#))
        let model = world.launch()
        await model.refresh()
        let fourth = UUID(uuidString: "00000000-0000-4000-C000-000000000004")!
        #expect(await model.setGoalStatus(fourth, .active) == "3 goals are active. Park one first.")
        #expect(!world.backend.requests.contains { $0.hasSuffix("/status") })

        world.backend.goDown()
        let problem = await model.setGoalStatus(fourth, .dropped, note: "Not this year")
        #expect(problem?.hasPrefix("Could not change the goal: can't reach the server") == true)
    }
}

extension Fixture {
    /// An exam goal in exactly the shape the backend sends.
    static func examGoal(scores: [Int] = [640, 705, 745], passed: Bool = false, daysLeft: Int = 41) -> String {
        let practice = scores.enumerated().map { index, score in
            """
            {"id": "00000000-0000-4000-d000-00000000000\(index + 1)", "taken_on": "2026-11-1\(index)", "score": \(score),
             "over_ready": \(score >= 750)}
            """
        }
        let inARow = scores.reversed().prefix { $0 >= 750 }.count
        let result = passed ? #"{"outcome": "passed", "on": "2027-01-04", "score": 801}"# : "null"
        return """
            {"id": "00000000-0000-4000-c000-000000000009", "title": "Solutions architect", "shape": "result",
             "reading": "exam", "subject_id": null, "subject": "Cloud certification", "start_on": "2026-11-02",
             "start_value": 0, "target_value": 720, "due_on": "2027-01-04", "status": "\(passed ? "reached" : "active")",
             "ended_on": \(passed ? "\"2027-01-04\"" : "null"), "note": null, "days_left": \(daysLeft), "moved_by": "study",
             "standing": null, "changes": [],
             "exam": {"name": "Solutions architect", "scale_max": 1000, "pass_mark": 720, "ready_at": 750, "ready_runs": 3,
                      "valid_months": 36, "result": \(result), "expires_on": \(passed ? "\"2030-01-04\"" : "null"),
                      "practice": [\(practice.joined(separator: ","))], "in_a_row": \(min(inARow, 3)),
                      "ready": \(inARow >= 3), "weakest": "Resilient", "minutes": 2850,
                      "domains": [{"name": "Secure", "weight_pct": 30, "latest_pct": 78},
                                  {"name": "Resilient", "weight_pct": 26, "latest_pct": null}]}}
            """
    }
}

@Suite struct ExamTextTests {
    func decoded(_ json: String) throws -> Goal {
        try JSONDecoder.lyfe.decode(Goal.self, from: Data(json.utf8))
    }

    @Test func anExamDecodesAndSaysHowCloseItIsToReady() throws {
        let goal = try decoded(Fixture.examGoal())
        let exam = try #require(goal.exam)
        #expect(goal.reading == .exam)
        #expect((exam.passMark, exam.readyAt, exam.inARow, exam.ready) == (720, 750, 0, false))
        #expect(exam.domains[1].latestPct == nil)
        #expect(GoalText.countdown(goal) == "41 days")
        #expect(GoalText.readiness(exam) == "Practice 745 · 0 of 3 over 750")
        #expect(GoalText.validity(exam) == "Valid 3 years once passed")
        #expect(GoalText.aim(goal, weightUnit: "kg") == "Sat on 4 Jan 2027")

        let ready = try decoded(Fixture.examGoal(scores: [640, 760, 755, 790]))
        let readyExam = try #require(ready.exam)
        #expect(GoalText.readiness(readyExam) == "Ready · 3 in a row over 750")
        let passed = try decoded(Fixture.examGoal(scores: [760], passed: true, daysLeft: -2))
        #expect(GoalText.countdown(passed) == "Passed")
        let passedExam = try #require(passed.exam)
        #expect(GoalText.validity(passedExam) == "Valid until 4 Jan 2030")
        #expect(GoalText.countdown(try decoded(Fixture.examGoal(daysLeft: 1))) == "Tomorrow")
        #expect(GoalText.countdown(try decoded(Fixture.examGoal(daysLeft: 0))) == "Today")
    }

    @Test func anExamsFiguresAreCheckedBeforeTheyAreSent() throws {
        var exam = ExamRequest(name: "Solutions architect", scaleMax: 1000, passMark: 720, readyMargin: 30)
        #expect(exam.problem == nil)
        exam.passMark = 990
        #expect(exam.problem == "The ready score is past what the exam is marked out of.")
        exam.passMark = 720
        exam.domains = [.init(name: " ", weightPct: 30)]
        #expect(exam.problem == "Each part needs a name and a share of 1 to 100%.")
        exam.name = ""
        #expect(exam.problem == "Name the exam.")
        // An exam already set is changed from the figures it has.
        let view = try #require(try decoded(Fixture.examGoal()).exam)
        let kept = ExamRequest(view)
        #expect((kept.passMark, kept.readyMargin, kept.readyRuns, kept.validMonths) == (720, 30, 3, 36))
        #expect(kept.domains.map(\.name) == ["Secure", "Resilient"])
    }
}

@MainActor
@Suite struct ExamAppTests {
    @Test func practiceAndTheResultAreSentInTheShapeTheBackendTakes() async throws {
        let world = World.signedIn()
        let id = UUID(uuidString: "00000000-0000-4000-C000-000000000009")!
        let path = "/v1/goals/00000000-0000-4000-c000-000000000009"
        world.backend.on("POST \(path)/scores", .ok(Fixture.homeWithGoals([Fixture.examGoal(scores: [640, 705, 745, 760])])))
        world.backend.on("POST \(path)/result", .ok(Fixture.homeWithGoals([Fixture.examGoal(passed: true)])))
        let model = world.launch()
        let day = CalendarDay(year: 2026, month: 11, day: 17)
        let entry = PracticeEntry(takenOn: day, score: 760, domains: [.init(name: "Secure", pct: 78)])
        #expect(await model.recordPractice(id, entry) == nil)
        #expect(model.home?.goals?.goals.first?.exam?.practice.count == 4)
        let practiceBody = try #require(world.backend.bodies("POST \(path)/scores").first)
        let practice = try #require(try JSONSerialization.jsonObject(with: practiceBody) as? [String: Any])
        #expect(practice["taken_on"] as? String == "2026-11-17")
        #expect(practice["score"] as? Int == 760)
        #expect((practice["domains"] as? [[String: Any]])?.first?["pct"] as? Int == 78)

        #expect(await model.recordExamResult(id, passed: true, on: day, score: 801) == nil)
        let resultBody = try #require(world.backend.bodies("POST \(path)/result").first)
        let result = try #require(try JSONSerialization.jsonObject(with: resultBody) as? [String: Any])
        #expect(result["outcome"] as? String == "passed")
        #expect(result["score"] as? Int == 801)
        #expect(model.home?.goals?.ended.first?.exam?.result?.outcome == "passed")
    }

    @Test func anExamGoalIsSetWithItsExamAndNoFigure() async throws {
        let world = World.signedIn()
        world.backend.on("PUT /v1/goals/00000000-0000-4000-c000-000000000009", .ok(Fixture.homeWithGoals([Fixture.examGoal()])))
        let model = world.launch()
        let request = GoalRequest(
            title: nil, reading: .exam, subject: "Cloud certification", targetValue: nil,
            dueOn: CalendarDay(year: 2027, month: 1, day: 4),
            exam: ExamRequest(name: "Solutions architect", scaleMax: 1000, passMark: 720, readyMargin: 30, validMonths: 36,
                              domains: [.init(name: "Secure", weightPct: 30)]))
        #expect(await model.saveGoal(id: UUID(uuidString: "00000000-0000-4000-C000-000000000009")!, request) == nil)
        let sent = try #require(world.backend.bodies("PUT /v1/goals/00000000-0000-4000-c000-000000000009").first)
        let body = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(body["reading"] as? String == "exam")
        #expect(body["target_value"] == nil)
        let exam = try #require(body["exam"] as? [String: Any])
        #expect(exam["pass_mark"] as? Int == 720)
        #expect(exam["ready_margin"] as? Int == 30)
        #expect((exam["domains"] as? [[String: Any]])?.first?["weight_pct"] as? Int == 30)
    }
}
