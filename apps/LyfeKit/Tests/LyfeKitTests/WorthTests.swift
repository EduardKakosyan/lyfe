import Foundation
import Testing

@testable import LyfeKit

/// What everything comes to, in exactly the shape the backend sends.
enum WorthFixture {
    static func account(_ n: Int, _ name: String, minor: Int, aside: Bool = false, invested: Bool = false) -> String {
        """
        {"id": "\(MoneyFixture.id(n))", "name": "\(name)", "connection": "First Bank", "currency": "CAD",
         "balance_minor": \(minor), "available_minor": null, "balance_at": "2026-11-17T12:00:00Z",
         "set_aside": \(aside), "invested": \(invested), "stale": false, "problem": null}
        """
    }

    static let holdings = """
        [{"symbol": "WRLD", "name": "Whole World Equity Fund", "currency": "CAD", "shares_micro": 420500000,
          "value_minor": 2100000, "cost_minor": 1750000, "accounts": ["Brokerage", "Retirement"]},
         {"symbol": "BOND", "name": "Bond Fund", "currency": "CAD", "shares_micro": 100000000,
          "value_minor": 400000, "cost_minor": null, "accounts": ["Brokerage"]},
         {"symbol": "", "name": "Big Tech Co", "currency": "USD", "shares_micro": 0,
          "value_minor": 150050, "cost_minor": 160000, "accounts": ["Brokerage"]}]
        """

    static func worth(
        series: String = """
            [{"day": "2026-11-14", "worth_minor": 3600000}, {"day": "2026-11-15", "worth_minor": 3650000},
             {"day": "2026-11-16", "worth_minor": 3650000}, {"day": "2026-11-17", "worth_minor": 3738000}]
            """,
        change: String = "{\"since\": \"2026-11-14\", \"minor\": 138000}", holdings: String = holdings,
        setAside: Int = 2_600_000, state: String = "ok"
    ) -> String {
        """
        {"currency": "CAD", "worth_minor": 3738000, "banked_minor": 1150000, "invested_minor": 2600000,
         "owed_minor": 12000, "everyday_minor": 1138000, "set_aside_minor": \(setAside),
         "recorded_since": "2026-11-14", "series": \(series), "change": \(change),
         "holdings": \(holdings), "held_minor": 2500000, "loose_minor": 100000,
         "paid": {"paid_minor": 1750000, "worth_minor": 2100000, "holdings": 1},
         "accounts": [\(account(901, "Chequing", minor: 250_000)), \(account(902, "Card", minor: -12_000)),
                      \(account(903, "Brokerage", minor: 2_000_000, aside: true, invested: true))],
         "problems": [],
         "source": {"state": "\(state)", "last_success_at": "2026-11-17T14:00:00Z", "last_attempt_at": "2026-11-17T14:00:00Z", "message": null}}
        """
    }

    static func decoded(_ json: String = worth()) -> MoneyWorth {
        try! JSONDecoder.lyfe.decode(MoneyWorth.self, from: Data(json.utf8))
    }
}

@Suite struct WorthTextTests {
    @Test func theAnswerIsReadAsTheBackendSendsIt() {
        let worth = WorthFixture.decoded()
        #expect(worth.worthMinor == 3_738_000)
        #expect(worth.recordedSince == CalendarDay(year: 2026, month: 11, day: 14))
        #expect(worth.series.count == 4)
        #expect(worth.holdings.map(\.symbol) == ["WRLD", "BOND", ""])
        #expect(worth.holdings[1].costMinor == nil)
        #expect(worth.accounts.map(\.invested) == [false, false, true])
        #expect(worth.paid == .init(paidMinor: 1_750_000, worthMinor: 2_100_000, holdings: 1))
        // A month's accounts, from a backend that does not say, still read.
        #expect(MoneyFixture.decoded().accounts.map(\.invested) == [nil, nil])
    }

    @Test func theChangeIsSaidAgainstTheDayItIsSince() {
        var worth = WorthFixture.decoded()
        #expect(WorthText.changeLine(worth) == "▲ 1,380 SINCE 14 NOV")
        worth.change?.minor = -52_050
        #expect(WorthText.changeLine(worth) == "▼ 521 SINCE 14 NOV")
        worth.change?.minor = 40
        #expect(WorthText.changeLine(worth) == "LEVEL SINCE 14 NOV")
        // One day kept is nothing to set today against.
        worth.change = nil
        #expect(WorthText.changeLine(worth) == "")
        #expect(WorthText.caption(worth) == "CAD · EVERYTHING ADDED UP")
        #expect(WorthText.spoken(WorthFixture.decoded()) == "Net worth 37,380 CAD, up 1,380 since 14 NOV")
    }

    @Test func aDayLongAgoIsSaidWithItsYear() {
        var worth = WorthFixture.decoded()
        let first = CalendarDay(year: 2026, month: 11, day: 14)
        #expect(WorthText.dayLabel(first, in: worth) == "14 NOV")
        // The line a year on: the same day and month would read as this year's.
        worth.series.append(.init(day: CalendarDay(year: 2027, month: 11, day: 20), worthMinor: 4_000_000))
        #expect(WorthText.dayLabel(first, in: worth) == "14 NOV 2026")
        #expect(WorthText.dayLabel(CalendarDay(year: 2027, month: 6, day: 1), in: worth) == "1 JUN")
    }

    @Test func withNoLineYetWhatStandsInItsPlaceIsSaid() {
        var worth = WorthFixture.decoded()
        worth.series = [worth.series[3]]
        worth.change = nil
        #expect(WorthText.lineNote(worth).hasPrefix("The line starts today"))
        #expect(WorthText.spoken(worth).hasPrefix("Net worth 37,380 CAD, The line starts today"))
        worth.series = []
        #expect(WorthText.lineNote(worth).hasPrefix("The line starts with the next import"))
    }

    @Test func whatItIsMadeOfIsDrawnAgainstTheLargestPart() {
        var worth = WorthFixture.decoded()
        let parts = WorthText.parts(worth)
        #expect(parts.map(\.name) == ["In the bank", "Invested", "Owed"])
        #expect(parts.map(\.minor) == [1_150_000, 2_600_000, -12_000])
        #expect(parts.map(\.mark) == [.solid, .solid, .striped])
        #expect(parts[1].share == 1)
        #expect(abs(parts[0].share - 1_150_000.0 / 2_600_000) < 0.0001)
        // Nothing invested and nothing owed: the bank alone.
        worth.investedMinor = 0
        worth.owedMinor = 0
        worth.holdings = []
        #expect(WorthText.parts(worth).map(\.name) == ["In the bank"])
        #expect(WorthText.parts(worth)[0].share == 1)
    }

    @Test func sharesAreWrittenWithTheDecimalsTheyHave() {
        #expect(WorthText.shares(420_500_000) == "420.5")
        #expect(WorthText.shares(100_000_000) == "100")
        #expect(WorthText.shares(123_457) == "0.1235")
        #expect(WorthText.shares(1_234_000_000) == "1,234")
        #expect(WorthText.shares(2_000_049) == "2")
    }

    @Test func aHoldingSaysWhatItIsWhereItIsAndHowItHasDone() {
        let worth = WorthFixture.decoded()
        let (world, bond, tech) = (worth.holdings[0], worth.holdings[1], worth.holdings[2])
        #expect(WorthText.title(world) == "WRLD")
        #expect(WorthText.holdingDetail(world, of: worth) == "84% · 420.5 SHARES")
        #expect(WorthText.holdingLine(world) == "WHOLE WORLD EQUITY FUND · BROKERAGE, RETIREMENT · ▲ 20%")
        #expect(WorthText.value(world, in: "CAD") == "21,000.00")
        // Nothing known of what was paid: nothing said of how it has done.
        #expect(WorthText.holdingLine(bond) == "BOND FUND · BROKERAGE")
        #expect(WorthText.growth(bond) == nil)
        // No ticker: its name is what it is called. In another currency it
        // is listed with it, and has no share of the rest and no bar.
        #expect(WorthText.title(tech) == "Big Tech Co")
        #expect(WorthText.holdingLine(tech) == "BROKERAGE · ▼ 6.2%")
        #expect(WorthText.holdingDetail(tech, of: worth) == "")
        #expect(WorthText.value(tech, in: "CAD") == "1,500.50 USD")
        #expect(worth.holdings.map { WorthText.share($0, of: worth) }[0] == 1)
        #expect(abs(WorthText.share(bond, of: worth) - 400_000.0 / 2_100_000) < 0.0001)
        #expect(WorthText.share(tech, of: worth) == 0)

        var one = world
        one.sharesMicro = 1_000_000
        one.accounts = ["A", "B", "C"]
        one.costMinor = 2_100_000
        #expect(WorthText.holdingDetail(one, of: worth) == "84% · 1 SHARE")
        #expect(WorthText.holdingLine(one) == "WHOLE WORLD EQUITY FUND · 3 ACCOUNTS · LEVEL")
        one.symbol = ""
        one.name = ""
        #expect(WorthText.title(one) == "Holding")
    }

    @Test func whatWasPaidIsSetAgainstWhatItIsWorth() {
        let worth = WorthFixture.decoded()
        let paid = worth.paid!
        let bar = WorthText.paidBar(paid)
        #expect(bar.grew)
        #expect(abs(bar.solid - 1_750_000.0 / 2_100_000) < 0.0001)
        // Said of the holdings a cost is known for, and how many that is.
        #expect(WorthText.paidLine(paid, of: worth) == "PAID 17,500 · GREW 3,500 · ▲ 20% · 1 OF 2 HOLDINGS")

        let lost = MoneyWorth.Paid(paidMinor: 205_000, worthMinor: 195_010, holdings: 2)
        #expect(!WorthText.paidBar(lost).grew)
        #expect(abs(WorthText.paidBar(lost).solid - 195_010.0 / 205_000) < 0.0001)
        #expect(WorthText.paidLine(lost, of: worth) == "PAID 2,050 · LOST 100 · ▼ 4.9%")
        let level = MoneyWorth.Paid(paidMinor: 205_000, worthMinor: 205_040, holdings: 2)
        #expect(WorthText.paidLine(level, of: worth) == "PAID 2,050 · LEVEL")
    }

    @Test func anInvestmentAccountSaysSo() {
        let worth = WorthFixture.decoded()
        let now = ISO8601DateFormatter().date(from: "2026-11-17T15:00:00Z")!
        #expect(MoneyText.accountDetail(worth.accounts[2], now: now) == "FIRST BANK · INVESTED · SET ASIDE")
        #expect(MoneyText.accountDetail(worth.accounts[0], now: now) == "FIRST BANK")
    }

    @Test func theLineRunsFromTheFirstDayKeptToToday() {
        let worth = WorthFixture.decoded()
        let layout = WorthChartLayout(points: worth.series, size: CGSize(width: 312, height: 150))
        #expect((layout.low, layout.high) == (3_600_000, 3_738_000))
        #expect(layout.line.count == 4)
        #expect(layout.line.first == CGPoint(x: 6, y: 139))
        #expect(layout.line.last == CGPoint(x: 306, y: 8))
        // A day apart is a third of the way across; the same amount is the same height.
        #expect(abs(layout.line[1].x - 106) < 0.001)
        #expect(layout.line[1].y == layout.line[2].y)
        #expect(WorthText.span(low: layout.low, high: layout.high, currency: "CAD") == "36,000–37,380 CAD")
    }

    @Test func aQuietStretchIsDrawnFlat() {
        let day = CalendarDay(year: 2026, month: 11, day: 16)
        let points = [
            MoneyWorth.Point(day: day, worthMinor: 1_000_000),
            MoneyWorth.Point(day: CalendarDay(year: 2026, month: 11, day: 17), worthMinor: 1_000_100),
        ]
        let layout = WorthChartLayout(points: points, size: CGSize(width: 312, height: 150))
        // A dollar's difference does not fill the chart: it spans 2% of the level.
        #expect(layout.high - layout.low == 20_002)
        #expect(abs(layout.line[0].y - layout.line[1].y) < 1)
        #expect(abs(layout.line[0].y - 73.5) < 1)
    }
}

@MainActor
@Suite struct WorthModelTests {
    @Test func worthIsFetchedWhenItsSectionOpensAndKeptWhileLyfeRuns() async throws {
        let world = World.signedIn()
        world.backend.on("GET /v1/money/worth", .ok(WorthFixture.worth()))
        let model = world.launch()
        #expect(model.moneySection == .month)

        model.showMoney(.worth)
        #expect(model.moneySection == .worth)
        await model.reloadMoneySection()
        #expect(model.worth?.worthMinor == 3_738_000)
        #expect(model.moneyProblem == nil)
        let request = try #require(world.backend.lastRequest("GET /v1/money/worth"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer device-token")

        // With no connection what was fetched stays, and the reason is said.
        world.backend.goDown()
        await model.loadWorth()
        #expect(model.worth?.worthMinor == 3_738_000)
        #expect(model.moneyProblem?.hasPrefix("Could not fetch what everything comes to: can't reach the server") == true)
        world.backend.goDown(false)
        await model.loadWorth()
        #expect(model.moneyProblem == nil)

        // Going to another section does not carry the last one's trouble along.
        world.backend.goDown()
        await model.loadWorth()
        model.showMoney(.month)
        #expect(model.moneyProblem == nil)
    }

    @Test func settingAnAccountAsideFetchesWhatItChanges() async throws {
        let world = World.signedIn()
        world.backend.on("GET /v1/money", .ok(MoneyFixture.month()))
        world.backend.on("GET /v1/money/worth", .ok(WorthFixture.worth()), .ok(WorthFixture.worth(setAside: 2_850_000)))
        world.backend.on("GET /v1/money/fire", .ok(FireFixture.fire()))
        world.backend.on("PUT /v1/money/accounts/\(MoneyFixture.id(901))", .ok(MoneyFixture.month()))
        let model = world.launch()
        await model.loadMoney(month: nil)
        await model.loadWorth()
        await model.loadFire()
        #expect(model.fire != nil)

        #expect(await model.setAside(account: UUID(uuidString: MoneyFixture.id(901))!, true) == nil)
        #expect(model.worth?.setAsideMinor == 2_850_000)
        // What counts towards independence changed: it is fetched again when next shown.
        #expect(model.fire == nil)
    }

    @Test func signingOutForgetsWorthAndTheWayThere() async {
        let world = World.signedIn()
        world.backend.on("GET /v1/money/worth", .ok(WorthFixture.worth()), .init(status: 401, body: "{}"))
        world.backend.on("GET /v1/money/fire", .ok(FireFixture.fire()))
        let model = world.launch()
        model.showMoney(.fire)
        await model.reloadMoneySection()
        await model.loadWorth()
        #expect(model.worth != nil)
        #expect(model.fire != nil)
        await model.loadWorth()
        #expect(model.worth == nil)
        #expect(model.fire == nil)
        #expect(model.moneySection == .month)
        #expect(model.phase == .signedOut)
    }
}
