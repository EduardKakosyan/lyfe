import Foundation
import Testing

@testable import LyfeKit

@Suite struct TypedWeightTests {
    @Test func whatPeopleTypeIntoAPromptIsRead() {
        let read = { (text: String, unit: String) in TypedWeight(text, unit: unit) }
        #expect(read("82.4", "kg") == TypedWeight(value: 82.4, unit: "kg"))
        #expect(read("82,4", "kg") == TypedWeight(value: 82.4, unit: "kg"))
        #expect(read(" 82.4 KG\n", "kg") == TypedWeight(value: 82.4, unit: "kg"))
        #expect(read("82", "kg") == TypedWeight(value: 82, unit: "kg"))
        #expect(read("181.4", "lb") == TypedWeight(value: 181.4, unit: "lb"))
        // A unit typed after the number wins over the one lyfe shows.
        #expect(read("181.4 lb", "kg") == TypedWeight(value: 181.4, unit: "lb"))
        #expect(read("181lbs", "kg") == TypedWeight(value: 181, unit: "lb"))
        #expect(read("82.4kgs", "lb") == TypedWeight(value: 82.4, unit: "kg"))
    }

    @Test func slipsAreNotWeights() {
        for slip in ["", "abc", "8.24", "824", "82.4.1", "-82", "82 4", "eighty", "82.456", "1e2", "30 lb"] {
            #expect(TypedWeight(slip, unit: "kg") == nil, "\(slip)")
        }
    }
}

@MainActor
@Suite struct WeighInTests {
    /// The weigh-ins sent so far, as JSON objects.
    func sent(_ world: World) -> [[String: Any]] {
        world.backend.bodies("POST /v1/weigh-ins").compactMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
    }

    @Test func aWeightTypedIsSentAndTheTrendComesBack() async throws {
        let world = World.signedIn()
        world.backend.on(
            "POST /v1/weigh-ins", .ok(Fixture.home(weight: Fixture.weight([("2026-11-18", 181.4)], unit: "lb"))))
        let model = world.launch()

        // Pounds until the server says otherwise.
        let outcome = await model.recordWeight("181.4")

        #expect(outcome == .sent)
        let body = try #require(sent(world).first)
        #expect(body["value"] as? Double == 181.4)
        #expect(body["unit"] as? String == "lb")
        #expect(body["measured_at"] as? String == "2026-11-18T11:06:40Z")
        #expect(UUID(uuidString: body["id"] as? String ?? "") != nil)
        let request = try #require(world.backend.lastRequest("POST /v1/weigh-ins"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer device-token")
        #expect(model.home?.weight?.latest == .init(date: CalendarDay(year: 2026, month: 11, day: 18), value: 181.4))
        #expect(model.unsentWeighIns.isEmpty)
        #expect(world.weighIns.outbox().isEmpty)
    }

    @Test func aWeightTypedWithNoConnectionIsKeptAndSentOnceOnTheNextRefresh() async throws {
        let world = World.signedIn()
        world.backend.goDown()
        let model = world.launch()

        #expect(await model.recordWeight("82.4") == .saved)
        #expect(model.unsentWeighIns.count == 1)
        #expect(model.isOffline)
        let kept = try #require(world.weighIns.outbox().first)

        // The app is closed and opened again later, with the server back.
        let relaunched = world.launch()
        #expect(relaunched.unsentWeighIns == [kept.id])
        world.backend.goDown(false)
        world.backend.on("POST /v1/weigh-ins", .ok(Fixture.home(weight: Fixture.weight([("2026-11-18", 82.4)]))))
        world.backend.on("GET /v1/home", .ok(Fixture.home(weight: Fixture.weight([("2026-11-18", 82.4)]))))
        world.backend.on("POST /v1/sync", .ok(Fixture.sources()))
        await relaunched.refresh()

        let ids = sent(world).compactMap { $0["id"] as? String }
        #expect(ids.last == kept.id.uuidString)
        #expect(relaunched.unsentWeighIns.isEmpty)
        #expect(world.weighIns.outbox().isEmpty)
        // The time is when it was typed, not when it was sent.
        #expect(sent(world).last?["measured_at"] as? String == "2026-11-18T11:06:40Z")
    }

    @Test func aReplyThatIsNotAWeightKeepsNothing() async {
        let world = World.signedIn()
        let model = world.launch()
        #expect(await model.recordWeight("8.24") == .unreadable)
        #expect(await model.recordWeight("ok") == .unreadable)
        #expect(world.backend.requests.isEmpty)
        #expect(world.weighIns.outbox().isEmpty)
    }

    @Test func aWeightTheServerRefusesIsDroppedAndSaidOutLoud() async {
        let world = World.signedIn()
        world.backend.on("POST /v1/weigh-ins", .init(status: 400, body: #"{"error": "bad_request"}"#))
        let model = world.launch()
        #expect(await model.recordWeight("181.4") == .refused)
        #expect(world.weighIns.outbox().isEmpty)
        #expect(model.weighInProblem == "The server would not take the weight 181.4 lb (400).")
    }

    @Test func aServerFaultKeepsTheWeightForLater() async {
        let world = World.signedIn()
        world.backend.on("POST /v1/weigh-ins", .init(status: 500, body: #"{"error": "internal"}"#))
        let model = world.launch()
        #expect(await model.recordWeight("82.4") == .saved)
        #expect(world.weighIns.outbox().count == 1)
        #expect(model.weighInProblem == "The server could not store a weight just now (500). It stays on this phone.")
    }

    @Test func aStoredWeightWhoseAnswerWasUnreadableIsNotSentAgain() async {
        let world = World.signedIn()
        world.backend.on("POST /v1/weigh-ins", .ok("<html>new server</html>"))
        let model = world.launch()
        #expect(await model.recordWeight("82.4") == .sent)
        #expect(world.weighIns.outbox().isEmpty)
        #expect(model.refreshProblem != nil)
    }

    @Test func theUnitIsTheOneTheServerShows() async {
        let world = World.signedIn()
        world.backend.on("GET /v1/home", .ok(Fixture.home(weight: Fixture.weight([("2026-11-17", 82.0)], unit: "kg"))))
        world.backend.on("POST /v1/sync", .ok(Fixture.sources()))
        world.backend.on("POST /v1/weigh-ins", .ok(Fixture.home(weight: Fixture.weight([], unit: "kg"))))
        let model = world.launch()
        #expect(model.weightUnit == "lb")
        await model.refresh()
        #expect(model.weightUnit == "kg")

        await model.recordWeight("82.4")
        #expect(sent(world).last?["unit"] as? String == "kg")
        #expect(sent(world).last?["value"] as? Double == 82.4)
    }

    @Test func tappingThePromptOpensTheEntryOverProgress() async {
        let world = World.signedIn()
        world.backend.on("POST /v1/auth/sign-out", .init(status: 204, body: ""))
        let model = world.launch()
        #expect(model.screen == .home)

        model.openWeighIn()
        #expect(model.screen == .progress)
        #expect(model.isEnteringWeight)
        model.closeWeighIn()
        #expect(model.screen == .progress)
        #expect(!model.isEnteringWeight)
        model.closeProgress()
        #expect(model.screen == .home)

        model.openWeighIn()
        await model.signOut()
        #expect(model.screen == .home)
        #expect(!model.isEnteringWeight)
    }

    @Test func homeFromBeforeWeighInsStillReads() throws {
        let old = try JSONDecoder.lyfe.decode(HomeSnapshot.self, from: Data(Fixture.home().utf8))
        #expect(old.weight == nil)
        let new = try JSONDecoder.lyfe.decode(
            HomeSnapshot.self,
            from: Data(Fixture.home(weight: Fixture.weight([("2026-11-15", 82.6), ("2026-11-16", 82.2), ("2026-11-17", 82.0)])).utf8))
        let weight = try #require(new.weight)
        #expect(weight.unit == "kg")
        #expect(weight.promptAt == "06:30")
        #expect(weight.average == 82.27)
        #expect(weight.days.map(\.average) == [nil, nil, 82.27])
    }
}

@Suite struct WeightTextTests {
    let today = CalendarDay(year: 2026, month: 11, day: 18)

    func trend(
        average: Double? = 82.7, latest: (Int, Double)? = (18, 82.4), change: Double? = -0.7, pct: Double? = -0.84,
        weighed: Int = 6, unit: String = "kg", promptAt: String? = "06:30"
    ) -> WeightTrend {
        WeightTrend(
            unit: unit, promptAt: promptAt,
            latest: latest.map { .init(date: CalendarDay(year: 2026, month: 11, day: $0.0), value: $0.1) },
            average: average, daysWeighed: weighed, change: change, changePct: pct, days: [])
    }

    @Test func theGiantFigureIsTheAverageOnceThereIsOne() {
        #expect(WeightText.hero(trend()) == ("82.7", "7-day average · KG"))
        #expect(WeightText.hero(trend(average: nil)) == ("82.4", "Latest · KG"))
        #expect(WeightText.hero(trend(average: nil, latest: nil)) == ("–", "No weigh-ins yet"))
        #expect(WeightText.hero(nil) == ("–", "No weigh-ins yet"))
    }

    @Test func theChangeOnLastWeekIsSaidWithItsDirection() {
        #expect(WeightText.changeLine(trend()) == "▼ 0.7 KG · −0.84% on last week")
        #expect(WeightText.changeLine(trend(change: 0.3, pct: 0.36)) == "▲ 0.3 KG · +0.36% on last week")
        #expect(WeightText.changeLine(trend(change: 0.02, pct: 0.02)) == "Level with last week")
        #expect(WeightText.changeLine(trend(change: nil, pct: nil)) == "The change shows after two weeks of weigh-ins")
        #expect(
            WeightText.changeLine(trend(average: nil, change: nil, pct: nil, weighed: 2))
                == "Average after 3 weigh-ins in 7 days · 2 so far")
        #expect(WeightText.changeLine(trend(average: nil, latest: nil, change: nil, pct: nil)) == "Reply to the morning prompt to start")
    }

    @Test func theBarSaysWhetherTodayIsIn() {
        #expect(WeightText.bar(trend(), today: today) == ("TODAY 82.4 KG · TAP TO CORRECT", "WEIGHED IN"))
        #expect(WeightText.bar(trend(latest: (17, 82.4)), today: today) == ("PROMPT AT 06:30 · OR TYPE IT HERE", "WEIGH IN"))
        #expect(WeightText.bar(trend(latest: nil, promptAt: nil), today: today) == ("TYPE TODAY'S WEIGHT", "WEIGH IN"))
        #expect(WeightText.bar(nil, today: today) == ("TYPE TODAY'S WEIGHT", "WEIGH IN"))
    }

    @Test func rowsUnderTheLine() {
        let rows = WeightText.rows(trend(latest: (17, 82.4), promptAt: nil), today: today)
        #expect(rows.map(\.0) == ["Latest", "Last 7 days", "Morning prompt"])
        #expect(rows.map(\.1) == ["TUE 17 NOV · 82.4 KG", "6 OF 7 WEIGHED", "OFF"])
        #expect(WeightText.rows(trend(), today: today)[0].1 == "TODAY · 82.4 KG")
        #expect(WeightText.chartStart(today: today) == "24 SEP")
    }

    @Test func homeLeadsToProgressWithTheTrend() {
        #expect(WeightText.homeLine(trend()) == "Weight · 7-day 82.7 KG")
        #expect(WeightText.homeLine(trend(average: nil)) == "Weight · latest 82.4 KG")
        #expect(WeightText.homeLine(nil) == "Weight · not weighed yet")
    }

    @Test func aReplyThatWasNotTakenIsAskedForAgain() {
        #expect(WeightText.retry(after: .sent, typed: "82.4", unit: "kg") == nil)
        #expect(WeightText.retry(after: .saved, typed: "82.4", unit: "kg") == nil)
        let again = WeightText.retry(after: .unreadable, typed: " 8.24 ", unit: "kg")
        #expect(again?.title == "Weigh-in not saved")
        #expect(again?.body == "“8.24” is not a weight. Hold this and type it again, like 82.4.")
        #expect(WeightText.retry(after: .unreadable, typed: "x", unit: "lb")?.body.hasSuffix("like 181.4.") == true)
        #expect(WeightText.retry(after: .refused, typed: "82.4", unit: "kg")?.body
            == "The server would not take “82.4”. Hold this and type it again.")
    }

    @Test func theEntrySaysWhatItReplaces() {
        let latest = WeightTrend.Reading(date: CalendarDay(year: 2026, month: 11, day: 17), value: 82.1)
        #expect(WeightText.entryLine(latest: latest, unit: "kg", today: today) == "Last 82.1 KG · TUE 17 NOV")
        let todays = WeightTrend.Reading(date: today, value: 82.1)
        #expect(WeightText.entryLine(latest: todays, unit: "kg", today: today) == "Today so far 82.1 KG · this replaces it")
        #expect(WeightText.entryLine(latest: nil, unit: "kg", today: today) == "First weigh-in")
    }
}

@Suite struct WeightChartTests {
    let today = CalendarDay(year: 2026, month: 11, day: 18)

    func day(_ day: Int, month: Int = 11, _ value: Double?, _ average: Double?) -> WeightTrend.Day {
        .init(date: CalendarDay(year: 2026, month: month, day: day), value: value, average: average)
    }

    @Test func aFlatStretchIsDrawnFlatNotAsACliff() {
        let layout = WeightChartLayout(
            days: [day(16, 82.1, nil), day(17, 82.3, nil), day(18, 82.2, 82.2)], today: today,
            size: CGSize(width: 300, height: 150))
        #expect(abs(layout.low - 81.2) < 1e-9 && abs(layout.high - 83.2) < 1e-9)
    }

    @Test func todayIsAtTheRightEdgeAndEightWeeksAgoAtTheLeft() {
        let layout = WeightChartLayout(
            days: [day(24, month: 9, 85, nil), day(18, 82, nil)], today: today, size: CGSize(width: 304, height: 150))
        #expect(layout.dots.map(\.x) == [2, 302])
        // The heavier day is higher up.
        #expect(layout.dots[0].y < layout.dots[1].y)
    }

    @Test func aGapInTheAverageBreaksTheLine() {
        let layout = WeightChartLayout(
            days: [
                day(10, 83, 83), day(11, 83, 83), day(12, nil, 82.9),
                // No average on the 13th and 14th: too few weigh-ins.
                day(15, 82, 82.5), day(16, 82, 82.4), day(17, nil, 82.3),
            ],
            today: today, size: CGSize(width: 300, height: 150))
        #expect(layout.segments.map(\.count) == [3, 3])
        #expect(layout.dots.count == 4)
    }

    @Test func daysOlderThanEightWeeksAreLeftOff() {
        let layout = WeightChartLayout(
            days: [day(1, month: 9, 90, 90), day(18, 82, 82)], today: today, size: CGSize(width: 300, height: 150))
        #expect(layout.dots.count == 1)
        #expect(layout.segments.map(\.count) == [1])
    }
}
