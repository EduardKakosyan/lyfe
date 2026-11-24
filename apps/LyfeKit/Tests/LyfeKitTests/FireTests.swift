import Foundation
import Testing

@testable import LyfeKit

/// The way to financial independence, in exactly the shape the backend
/// sends: two whole months of 3,000 in and 1,200 spent, and November
/// running.
enum FireFixture {
    static func plan(withdrawal: Int = 350, growth: Int = 400, born: Int? = nil, coast: Int = 65, fund: Int = 0) -> String {
        """
        {"withdrawal_bp": \(withdrawal), "return_bp": \(growth), "birth_year": \(born.map(String.init) ?? "null"), "coast_age": \(coast),
         "emergency_fund_minor": \(fund)}
        """
    }

    static func fire(plan: String = plan(), born: Bool = false, problems: String = "[]") -> String {
        let age = born ? "36" : "null"
        let coast =
            born
            ? "{\"age\": 65, \"years\": 29, \"number_minor\": 13192515, \"progress_pct\": 15.2, \"reached\": false}" : "null"
        return """
            {"currency": "CAD",
             "months": [{"month": "2026-09", "spent_minor": 120000, "income_minor": 300000, "whole": true},
                        {"month": "2026-10", "spent_minor": 120000, "income_minor": 300000, "whole": true},
                        {"month": "2026-11", "spent_minor": 90000, "income_minor": 300000, "whole": false}],
             "counted": 2, "monthly_income_minor": 300000, "monthly_spent_minor": 120000, "monthly_kept_minor": 180000,
             "savings_rate_pct": 60.0, "yearly_spent_minor": 1440000, "yearly_kept_minor": 2160000,
             "set_aside_minor": 2000000, "emergency_fund_minor": 0, "fi_number_minor": 41142857, "progress_pct": 4.9, "reached": false,
             "years_to_fi": 13.5, "fi_year": 2040, "fi_age": \(born ? "50" : "null"), "age": \(age), "coast": \(coast),
             "on_hand_minor": 238000, "runway_months": 2.0,
             "ahead": [{"year": 2026, "age": \(age), "kept_minor": 2000000, "coast_minor": 2000000},
                       {"year": 2027, "age": \(born ? "37" : "null"), "kept_minor": 4240000, "coast_minor": 2080000},
                       {"year": 2028, "age": \(born ? "38" : "null"), "kept_minor": 6569600, "coast_minor": 2163200}],
             "plan": \(plan), "problems": \(problems),
             "source": {"state": "ok", "last_success_at": "2026-11-17T14:00:00Z", "last_attempt_at": "2026-11-17T14:00:00Z", "message": null}}
            """
    }

    /// Nothing held whole yet: only the month running, and nothing worked out.
    static let new = """
        {"currency": "CAD", "months": [{"month": "2026-11", "spent_minor": 90000, "income_minor": 300000, "whole": false}],
         "counted": 0, "monthly_income_minor": null, "monthly_spent_minor": null, "monthly_kept_minor": null,
         "savings_rate_pct": null, "yearly_spent_minor": null, "yearly_kept_minor": null, "set_aside_minor": 2000000,
         "emergency_fund_minor": 0, "fi_number_minor": null, "progress_pct": null, "reached": false, "years_to_fi": null, "fi_year": null,
         "fi_age": null, "age": null, "coast": null, "on_hand_minor": 238000, "runway_months": null, "ahead": [],
         "plan": \(plan()), "problems": [],
         "source": {"state": "ok", "last_success_at": "2026-11-17T14:00:00Z", "last_attempt_at": "2026-11-17T14:00:00Z", "message": null}}
        """

    static func decoded(_ json: String = fire()) -> MoneyFire {
        try! JSONDecoder.lyfe.decode(MoneyFire.self, from: Data(json.utf8))
    }
}

@Suite struct FireTextTests {
    @Test func theAnswerIsReadAsTheBackendSendsIt() {
        let fire = FireFixture.decoded()
        #expect(fire.months.map(\.month) == ["2026-09", "2026-10", "2026-11"])
        #expect(fire.months.map(\.whole) == [true, true, false])
        #expect(fire.savingsRatePct == 60)
        #expect(fire.fiNumberMinor == 41_142_857)
        #expect(fire.yearsToFi == 13.5)
        #expect(fire.coast == nil)
        #expect(fire.plan == MoneyPlan(withdrawalBp: 350, returnBp: 400, birthYear: nil, coastAge: 65))
        let born = FireFixture.decoded(FireFixture.fire(plan: FireFixture.plan(born: 1990), born: true))
        #expect(born.coast == .init(age: 65, years: 29, numberMinor: 13_192_515, progressPct: 15.2, reached: false))
        #expect(born.ahead.map(\.age) == [36, 37, 38])
        #expect(FireFixture.decoded(FireFixture.new).counted == 0)
        // What is wrong with where the figures come from comes with them.
        #expect(fire.problems.isEmpty)
        #expect(fire.source.state == .ok)
        let broken = FireFixture.decoded(
            FireFixture.fire(problems: "[{\"text\": \"First Bank: Sign in again\", \"reconnect\": true}]"))
        #expect(broken.problems == [.init(text: "First Bank: Sign in again", reconnect: true)])
    }

    @Test func figuresAreWrittenTheSameWhateverThePhonesRegion() {
        #expect(FireText.number(33.3) == "33.3")
        #expect(FireText.number(60) == "60")
        #expect(FireText.number(-20) == "−20")
        #expect(FireText.number(-0.04) == "0")
        #expect(FireText.number(13.46) == "13.5")
        #expect(FireText.rate(350) == "3.5%")
        #expect(FireText.rate(325) == "3.25%")
        #expect(FireText.rate(400) == "4%")
        #expect(FireText.rate(0) == "0%")
    }

    @Test func theHeadLeadsWithWhatWasKept() {
        var fire = FireFixture.decoded()
        #expect(FireText.hero(fire) == ("60%", "OF WHAT CAME IN, KEPT"))
        #expect(FireText.basis(fire) == "FROM THE LAST 2 MONTHS")
        #expect(FireText.headline(fire) == "FI IN 13.5 YEARS")
        #expect(FireText.when(fire) == "2040")
        #expect(FireText.spoken(fire) == "60 percent of what came in was kept, financial independence in 13.5 years")
        fire.fiAge = 50
        #expect(FireText.when(fire) == "2040 · AGE 50")
        fire.savingsRatePct = -20.4
        #expect(FireText.hero(fire).figure == "−20%")
        // Not reached at this rate, reached already, and one year off.
        fire.yearsToFi = nil
        fire.fiYear = nil
        #expect(FireText.headline(fire) == "NOT AT THIS RATE")
        #expect(FireText.when(fire) == "")
        fire.yearsToFi = 1
        #expect(FireText.headline(fire) == "FI IN 1 YEAR")
        // A cent short of the number is not nought years away.
        fire.yearsToFi = 0
        #expect(FireText.headline(fire) == "FI THIS YEAR")
        fire.reached = true
        #expect(FireText.headline(fire) == "INDEPENDENT")
        // Nothing came in, and no whole month at all.
        fire.savingsRatePct = nil
        #expect(FireText.hero(fire) == ("–", "KEPT · NOTHING CAME IN"))
        let new = FireFixture.decoded(FireFixture.new)
        #expect(FireText.hero(new) == ("–", "KEPT · NEEDS A WHOLE MONTH OF ENTRIES"))
        #expect(FireText.basis(new) == "NO WHOLE MONTH YET")
        #expect(FireText.headline(new) == "")
        fire.counted = 1
        #expect(FireText.basis(fire) == "FROM LAST MONTH")
    }

    @Test func theMonthsAreSaidAsWhatCameInWasSpentAndWasKept() {
        var fire = FireFixture.decoded()
        #expect(FireText.flowRows(fire).map(\.0) == ["In, a month", "Spent", "Kept"])
        #expect(FireText.flowRows(fire).map(\.1) == ["3,000.00", "1,200.00", "1,800.00"])
        fire.monthlyKeptMinor = -50_000
        #expect(FireText.flowRows(fire)[2] == ("Short", "500.00"))
        #expect(FireText.flowRows(FireFixture.decoded(FireFixture.new)).isEmpty)
        #expect(
            FireText.flowsSpoken(FireFixture.decoded())
                == "In, a month 3,000.00, Spent 1,200.00, Kept 1,800.00, from the last 2 months")
        #expect(FireText.flowsSpoken(FireFixture.decoded(FireFixture.new)).hasSuffix("no whole month yet"))
        #expect(FireText.monthLabel("2026-09", of: 3) == "SEP")
        #expect(FireText.monthLabel("2026-09", of: 13) == "S")
    }

    @Test func theWayThereIsSaidWithWhatItAssumes() {
        let fire = FireFixture.decoded(FireFixture.fire(plan: FireFixture.plan(born: 1990), born: true))
        #expect(FireText.assumed(fire.plan) == "3.5% DRAWN A YEAR · 4% GROWTH")
        #expect(FireText.multiple(fire.plan) == "× 28.6")
        #expect(FireText.multiple(MoneyPlan(withdrawalBp: 400, returnBp: 500, birthYear: nil, coastAge: 60)) == "× 25")
        #expect(abs(FireText.progress(fire) - 2_000_000.0 / 41_142_857) < 0.0001)
        #expect(abs(FireText.coastMark(fire)! - 13_192_515.0 / 41_142_857) < 0.0001)
        #expect(FireText.progressLine(fire) == "4.9% OF THE WAY")
        #expect(
            FireText.coastLine(fire.coast!)
                == "COAST NUMBER 131,925 GROWS THERE BY 65 WITH NOTHING ADDED · 15.2% OF IT SET ASIDE")
        #expect(FireText.numberRows(fire).map(\.0) == [
            "Spending a year", "FI number · × 28.6", "Set aside", "Kept a year", "Reached", "Coast number · by 65",
        ])
        #expect(FireText.numberRows(fire).map(\.1) == [
            "14,400.00", "411,428.57", "20,000.00", "21,600.00", "2040 · AGE 50", "131,925.15",
        ])
        #expect(FireText.aheadLegend(fire) == ("KEEPING 21,600 A YEAR", "ADDING NOTHING"))
        #expect(FireText.aheadEnds(fire) == ("NOW · AGE 36", "AGE 38"))

        var other = FireFixture.decoded()
        #expect(FireText.coastMark(other) == nil)
        #expect(FireText.aheadEnds(other) == ("NOW · 2026", "2028"))
        // More spent than comes in: short, and never there.
        other.yearlyKeptMinor = -600_000
        other.yearsToFi = nil
        other.fiYear = nil
        #expect(FireText.aheadLegend(other).kept == "SHORT 6,000 A YEAR")
        #expect(FireText.numberRows(other).map(\.0)[3] == "Short a year")
        #expect(FireText.numberRows(other)[4] == ("Reached", "NOT AT THIS RATE"))
        other.reached = true
        other.progressPct = 104
        #expect(FireText.numberRows(other)[4] == ("Reached", "NOW"))
        #expect(FireText.progressLine(other) == "ALL OF IT IS SET ASIDE")
        var coast = fire.coast!
        coast.reached = true
        #expect(FireText.coastLine(coast) == "COAST NUMBER 131,925 · PASSED: IT GROWS THERE BY 65 WITH NOTHING ADDED")
        // What was held back for the emergency fund is said beside what is set aside.
        var funded = FireFixture.decoded()
        funded.emergencyFundMinor = 500_000
        #expect(FireText.numberRows(funded).map(\.0)[2...3] == ["Set aside", "Emergency fund · held back"])
        #expect(FireText.numberRows(funded)[3].1 == "5,000.00")
        // With nothing to work a number from, only what is set aside is said.
        #expect(FireText.numberRows(FireFixture.decoded(FireFixture.new)).map(\.0) == ["Set aside"])
        #expect(FireText.progress(FireFixture.decoded(FireFixture.new)) == 0)
    }

    @Test func theRunwayIsMonthsOfSpendingOnHand() {
        var fire = FireFixture.decoded()
        #expect(FireText.runway(fire) == "2 MONTHS")
        #expect(abs(FireText.runwayShare(fire) - 2.0 / 6) < 0.0001)
        #expect(FireText.runwayLine(fire) == "2,380.00 ON HAND · 3 TO 6 MONTHS IS THE USUAL CUSHION")
        fire.runwayMonths = 7.5
        #expect(FireText.runway(fire) == "7.5 MONTHS")
        #expect(FireText.runwayShare(fire) == 1)
        fire.runwayMonths = 1
        #expect(FireText.runway(fire) == "1 MONTH")
        fire.runwayMonths = nil
        #expect(FireText.runway(fire) == "–")
        #expect(FireText.runwayShare(fire) == 0)
    }

    @Test func aBirthYearIsAYearThatHasBegunOrNothing() {
        #expect(FireText.birthYear("1990", thisYear: 2026) == .some(1990))
        #expect(FireText.birthYear(" 1998 ", thisYear: 2026) == .some(1998))
        #expect(FireText.birthYear("", thisYear: 2026) == .some(nil))
        #expect(FireText.birthYear("2027", thisYear: 2026) == nil)
        #expect(FireText.birthYear("98", thisYear: 2026) == nil)
        #expect(FireText.birthYear("about 2000", thisYear: 2026) == nil)
    }

    @Test func eachMonthIsTwoBarsOnOneScale() {
        let fire = FireFixture.decoded()
        let layout = FlowBarsLayout(months: fire.months, size: CGSize(width: 300, height: 100))
        #expect(layout.pairs.count == 3)
        // What came in is the tallest thing there, and fills the height.
        #expect(layout.pairs[0].income == CGRect(x: 27, y: 4, width: 22, height: 93))
        #expect(layout.pairs[0].spent == CGRect(x: 51, y: 60, width: 22, height: 37))
        #expect(layout.pairs[1].income.minX == 127)
        #expect(layout.pairs.map(\.whole) == [true, true, false])
        // Money back can outrun a month's spending: that is no bar, not one below the line.
        var back = fire.months
        back[0].spentMinor = -5_000
        #expect(FlowBarsLayout(months: back, size: CGSize(width: 300, height: 100)).pairs[0].spent.height == 0)
        // Thirteen months still fit, with thinner bars.
        let year = (0..<13).map { MoneyFire.Month(month: "2026-\($0)", spentMinor: 100, incomeMinor: 200, whole: true) }
        let narrow = FlowBarsLayout(months: year, size: CGSize(width: 357, height: 100))
        #expect(narrow.pairs.allSatisfy { $0.income.width < 22 && $0.income.width >= 2 })
        #expect(narrow.pairs.last!.spent.maxX <= 357)
        #expect(FlowBarsLayout(months: [], size: CGSize(width: 300, height: 100)).pairs.isEmpty)
    }

    @Test func theLineAheadStopsWhereItReachesTheNumber() {
        func ahead(_ kept: [Int], coast: [Int]? = nil) -> [MoneyFire.Ahead] {
            kept.enumerated().map { index, minor in
                MoneyFire.Ahead(year: 2026 + index, age: nil, keptMinor: minor, coastMinor: coast?[index] ?? kept[0])
            }
        }
        let size = CGSize(width: 212, height: 100)
        let layout = AheadChartLayout(ahead: ahead([100, 300, 700]), numberMinor: 500, size: size)
        // The number's rule sits under the headroom left for its label.
        #expect(abs(layout.numberY - (95 - 91 / 1.18)) < 0.001)
        // Half way between the second year and the third.
        #expect(layout.kept.count == 3)
        #expect(layout.kept[0].x == 6)
        #expect(abs(layout.reached!.x - 156) < 0.001)
        #expect(layout.reached!.y == layout.numberY)
        #expect(layout.kept.last == layout.reached)
        // With nothing added it stays level, and reaches nothing.
        #expect(layout.coast.count == 3)
        #expect(layout.coast[0].y == layout.coast[2].y)

        // Never reached: the whole line, and no square.
        let never = AheadChartLayout(ahead: ahead([100, 200, 300]), numberMinor: 500, size: size)
        #expect(never.kept.count == 3)
        #expect(never.reached == nil)
        #expect(never.kept[2].x == 206)
        // There already: one point, on the rule.
        let there = AheadChartLayout(ahead: ahead([600, 700]), numberMinor: 500, size: size)
        #expect(there.kept == [CGPoint(x: 6, y: there.numberY)])
        #expect(there.reached != nil)
        // Running out: the line stops on the baseline where it gets there.
        let out = AheadChartLayout(ahead: ahead([100, 50, -50, -150]), numberMinor: 500, size: CGSize(width: 312, height: 100))
        #expect(out.kept.count == 3)
        #expect(abs(out.kept[2].x - 156) < 0.001)
        #expect(out.kept[2].y == 95)
        #expect(out.reached == nil)
    }

    @Test func theYearItIsReachedIsSetClearOfTheRulesOwnLabel() {
        #expect(AheadChartLayout.labelLeft(reachedAt: 300, in: 357) == 170)
        // Reached soon: it cannot go left of the rule's label, so it starts after it.
        #expect(AheadChartLayout.labelLeft(reachedAt: 40, in: 357) == 78)
        // On a narrow chart it stays inside.
        #expect(AheadChartLayout.labelLeft(reachedAt: 190, in: 190) == 78)
    }

    @Test func aMeterShowsSomethingAsSoonAsThereIsAnything() {
        #expect(MeterLayout.filled(0, of: 300) == 0)
        #expect(MeterLayout.filled(0.001, of: 300) == 4)
        #expect(MeterLayout.filled(0.5, of: 300) == 150)
        #expect(MeterLayout.filled(1.7, of: 300) == 300)
        #expect(MeterLayout.tick(0.5, of: 300) == 148.75)
        #expect(MeterLayout.tick(1, of: 300) == 297.5)
        #expect(MeterLayout.tick(0, of: 300) == 0)
    }
}

@MainActor
@Suite struct FireModelTests {
    func sent(_ world: World, _ route: String) -> [[String: Any]] {
        world.backend.bodies(route).compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    @Test func theWayThereIsFetchedWhenItsSectionOpens() async throws {
        let world = World.signedIn()
        world.backend.on("GET /v1/money/fire", .ok(FireFixture.fire()))
        let model = world.launch()
        model.showMoney(.fire)
        await model.reloadMoneySection()
        #expect(model.fire?.counted == 2)
        #expect(model.moneyProblem == nil)

        world.backend.goDown()
        await model.loadFire()
        #expect(model.fire?.counted == 2)
        #expect(model.moneyProblem?.hasPrefix("Could not fetch the way to independence: can't reach the server") == true)
    }

    @Test func whatItAssumesIsChangedAndEverythingIsWorkedOutAgain() async throws {
        let world = World.signedIn()
        world.backend.on("GET /v1/money/fire", .ok(FireFixture.fire()))
        let changed = FireFixture.plan(withdrawal: 400, growth: 500, born: 1990, coast: 60)
        world.backend.on("PUT /v1/money/plan", .ok(FireFixture.fire(plan: changed, born: true)))
        let model = world.launch()

        // Nothing to change until it has been fetched.
        model.openPlan()
        #expect(!model.isEditingPlan)
        await model.loadFire()
        model.openPlan()
        #expect(model.isEditingPlan)

        let plan = MoneyPlan(withdrawalBp: 400, returnBp: 500, birthYear: 1990, coastAge: 60)
        #expect(await model.setPlan(MoneyPlan(withdrawalBp: 400, returnBp: 500, birthYear: 1990, coastAge: 60, emergencyFundMinor: 500_000)) == nil)
        #expect(!model.isEditingPlan)
        #expect(model.fire?.plan == plan)
        #expect(model.fire?.age == 36)
        let body = try #require(sent(world, "PUT /v1/money/plan").first)
        #expect(body["withdrawal_bp"] as? Int == 400)
        #expect(body["return_bp"] as? Int == 500)
        #expect(body["birth_year"] as? Int == 1990)
        #expect(body["coast_age"] as? Int == 60)
        #expect(body["emergency_fund_minor"] as? Int == 500_000)

        // No birth year is sent as none, which takes it back.
        model.openPlan()
        await model.setPlan(MoneyPlan(withdrawalBp: 400, returnBp: 500, birthYear: nil, coastAge: 60))
        #expect(sent(world, "PUT /v1/money/plan").last?["birth_year"] == nil)
    }

    @Test func aPlanTheServerRefusesIsSaidAndStaysOpen() async {
        let world = World.signedIn()
        world.backend.on("GET /v1/money/fire", .ok(FireFixture.fire()))
        world.backend.on("PUT /v1/money/plan", .init(status: 400, body: "{}"))
        let model = world.launch()
        await model.loadFire()
        model.openPlan()

        let plan = MoneyPlan(withdrawalBp: 900, returnBp: 400, birthYear: nil, coastAge: 65)
        #expect(await model.setPlan(plan) == "The server would not change what it assumes (400).")
        #expect(model.isEditingPlan)
        #expect(model.fire?.plan.withdrawalBp == 350)
        model.closePlan()
        #expect(!model.isEditingPlan)
    }
}
