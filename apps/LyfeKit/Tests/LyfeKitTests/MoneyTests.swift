import Foundation
import Testing

@testable import LyfeKit

/// A month in exactly the shape the backend sends.
enum MoneyFixture {
    static func id(_ n: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", n)
    }

    static func entry(
        _ n: Int, day: String, name: String, minor: Int, kind: String, category: String? = nil,
        sortedBy: String = "auto", account: String = "Chequing", currency: String = "CAD", hasPayee: Bool = true
    ) -> String {
        let waits = sortedBy == "auto" && kind != "transfer"
        return """
            {"id": "\(id(n))", "day": "\(day)", "name": "\(name)", "amount_minor": \(minor), "currency": "\(currency)",
             "kind": "\(kind)", "category": \(category.map { "\"\($0)\"" } ?? "null"), "sorted_by": "\(sortedBy)",
             "to_sort": \(waits), "has_payee": \(hasPayee), "account": "\(account)"}
            """
    }

    /// Newest first, as the backend lists them.
    static let waitingEntries = [
        entry(4, day: "2026-11-14", name: "Employer", minor: 300_000, kind: "income"),
        entry(3, day: "2026-11-05", name: "Corner Grocer #2", minor: -3_990, kind: "expense", account: "Card"),
        entry(2, day: "2026-11-03", name: "Corner Grocer", minor: -4_510, kind: "expense"),
        entry(1, day: "2026-11-02", name: "Noodle Bar", minor: -8_000, kind: "expense", account: "Card"),
    ]

    static func month(
        _ month: String = "2026-11", entries: [String] = waitingEntries, spent: Int = 16_500, unsorted: Int = 16_500,
        toSort: Int = 4, categories: String = "[]", previous: String = "null", earlier: String? = "2026-10",
        later: String? = nil, problems: String = "[]", state: String = "ok"
    ) -> String {
        func text(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }
        return """
            {"month": "\(month)", "current": \(later == nil), "earlier": \(text(earlier)), "later": \(text(later)),
             "currency": "CAD", "spent_minor": \(spent), "unsorted_minor": \(unsorted), "to_sort": \(toSort),
             "income_minor": 300000, "previous": \(previous), "categories": \(categories),
             "entries": [\(entries.joined(separator: ","))],
             "accounts": [
               {"id": "\(id(901))", "name": "Card", "connection": "First Bank", "currency": "CAD", "balance_minor": -12000,
                "available_minor": null, "balance_at": "2026-11-17T12:00:00Z", "set_aside": false, "stale": false, "problem": null},
               {"id": "\(id(902))", "name": "Savings", "connection": "First Bank", "currency": "CAD", "balance_minor": 900000,
                "available_minor": 900000, "balance_at": "2026-11-12T12:00:00Z", "set_aside": true, "stale": true, "problem": null}
             ],
             "everyday_minor": -12000, "set_aside_minor": 900000,
             "category_names": ["Groceries", "Eating out", "Fuel", "Other"],
             "problems": \(problems),
             "source": {"state": "\(state)", "last_success_at": "2026-11-17T14:00:00Z", "last_attempt_at": "2026-11-17T14:00:00Z", "message": null}}
            """
    }

    static func decoded(_ json: String = month()) -> MoneyMonth {
        try! JSONDecoder.lyfe.decode(MoneyMonth.self, from: Data(json.utf8))
    }

    static let glance = """
        {"month": "2026-11", "currency": "CAD", "spent_minor": 16500, "to_sort": 4, "problem": null,
         "last_success_at": "2026-11-17T14:00:00Z"}
        """
}

@Suite struct MoneyTextTests {
    @Test func amountsAreWrittenTheSameWhateverThePhonesRegion() {
        #expect(MoneyText.amount(123_456) == "1,234.56")
        #expect(MoneyText.amount(-4_510) == "−45.10")
        #expect(MoneyText.amount(5) == "0.05")
        #expect(MoneyText.amount(0) == "0.00")
        #expect(MoneyText.amount(100_000_000) == "1,000,000.00")
        #expect(MoneyText.whole(164_950) == "1,650")
        #expect(MoneyText.whole(49) == "0")
        #expect(MoneyText.whole(-49) == "0")
        #expect(MoneyText.whole(-12_000) == "−120")
    }

    @Test func monthsAreNamed() {
        #expect(MoneyText.short("2026-11") == "NOV")
        #expect(MoneyText.long("2026-01") == "JANUARY 2026")
        #expect(MoneyText.short("soon") == "soon")
    }

    @Test func theMonthIsSetAgainstTheLastOnlyWhenThereIsOne() {
        var money = MoneyFixture.decoded()
        #expect(MoneyText.comparison(money) == "")
        money.previous = .init(month: "2026-10", spentMinor: 248_310, byNowMinor: 212_640)
        #expect(MoneyText.comparison(money) == "1,961 LESS THAN OCT BY NOW")
        money.spentMinor = 230_000
        #expect(MoneyText.comparison(money) == "174 MORE THAN OCT BY NOW")
        money.spentMinor = 212_650
        #expect(MoneyText.comparison(money) == "LEVEL WITH OCT BY NOW")
        // A finished month is set against the whole of the one before.
        money.previous?.byNowMinor = nil
        #expect(MoneyText.comparison(money) == "OCT WAS 2,483")
    }

    @Test func anEntrySaysWhatItIs() {
        let money = MoneyFixture.decoded(
            MoneyFixture.month(entries: [
                MoneyFixture.entry(1, day: "2026-11-02", name: "Noodle Bar", minor: -8_000, kind: "expense", account: "Card"),
                MoneyFixture.entry(
                    2, day: "2026-11-03", name: "Corner Grocer", minor: -4_510, kind: "expense", category: "Groceries",
                    sortedBy: "rule"),
                MoneyFixture.entry(
                    3, day: "2026-11-04", name: "Corner Grocer", minor: 500, kind: "refund", category: "Groceries",
                    sortedBy: "rule"),
                MoneyFixture.entry(4, day: "2026-11-10", name: "Card payment", minor: -50_000, kind: "transfer", sortedBy: "match"),
                MoneyFixture.entry(5, day: "2026-11-14", name: "Employer", minor: 300_000, kind: "income", sortedBy: "rule"),
                MoneyFixture.entry(
                    6, day: "2026-11-15", name: "Bookshop", minor: -900, kind: "expense", category: "Other",
                    sortedBy: "owner", account: "Dollars", currency: "USD"),
            ]))
        let entries = money.entries
        #expect(MoneyText.detail(entries[0]) == "2 NOV · CARD · TO SORT")
        #expect(MoneyText.detail(entries[1]) == "3 NOV · CHEQUING · GROCERIES")
        #expect(MoneyText.what(entries[2]) == "MONEY BACK · GROCERIES")
        #expect(MoneyText.what(entries[3]) == "MOVED · PAIRED")
        #expect(MoneyText.what(entries[4]) == "MONEY IN")
        #expect(entries.map { MoneyText.figure($0, in: "CAD") } == ["80.00", "45.10", "+5.00", "500.00", "+3,000.00", "9.00 USD"])
        #expect(entries.map(MoneyText.mark) == [.outline, .solid, .solid, .striped, .striped, .solid])
    }

    @Test func theBarLeadsToWhatIsLeftToSort() {
        var money = MoneyFixture.decoded()
        #expect(MoneyText.bar(money).big == "SORT THEM")
        #expect(MoneyText.bar(money).small == "4 ENTRIES · ONCE FOR EACH PAYEE")
        #expect(MoneyText.bar(money).opensSorting)
        money.toSort = 0
        #expect(MoneyText.bar(money) == ("NOVEMBER 2026 · 165 CAD", "ALL SORTED", false))
        money.entries = []
        #expect(MoneyText.bar(money).small == "NOTHING POSTED YET THIS MONTH")
        // Oldest first is the order they are gone through in.
        #expect(MoneyFixture.decoded().waiting.map(\.name) == ["Noodle Bar", "Corner Grocer", "Corner Grocer #2", "Employer"])
    }

    @Test func categoriesAreDrawnAgainstTheLargest() {
        var money = MoneyFixture.decoded()
        money.spentMinor = 20_000
        money.categories = [
            .init(name: "Groceries", spentMinor: 12_000, entries: 3), .init(name: "Fuel", spentMinor: 3_000, entries: 1),
            .init(name: "Other", spentMinor: -500, entries: 1),
        ]
        #expect(money.categories.map { MoneyText.share($0, of: money) } == [1, 0.25, 0])
        #expect(MoneyText.categoryDetail(money.categories[0], of: money) == "3 ENTRIES · 60%")
        #expect(MoneyText.categoryDetail(money.categories[2], of: money) == "1 ENTRY")
    }

    @Test func accountsSayWhereTheyAreAndHowOldTheirBalanceIs() {
        let money = MoneyFixture.decoded()
        let now = ISO8601DateFormatter().date(from: "2026-11-17T15:00:00Z")!
        #expect(MoneyText.accountDetail(money.accounts[0], now: now) == "FIRST BANK")
        #expect(MoneyText.accountDetail(money.accounts[1], now: now) == "FIRST BANK · SET ASIDE · LAST SEEN 5 D AGO")
        #expect(MoneyText.balance(money.accounts[0], in: "CAD") == "−120.00")
        #expect(MoneyText.balance(money.accounts[0], in: "USD") == "−120.00 CAD")
        #expect(MoneyText.sourceLine(money.source, now: now).right == "IMPORTED 1 H AGO")
    }

    @Test func aBankToSignInToAgainSaysWhere() {
        #expect(MoneyText.notice(.init(text: "The last import failed.", reconnect: false)) == "The last import failed.")
        #expect(
            MoneyText.notice(.init(text: "First Bank: Sign in again.", reconnect: true))
                == "First Bank: Sign in again. Sign in to it again at SimpleFIN Bridge.")
    }

    @Test func homeLeadsToMoneyWithTheMonth() throws {
        var glance = try JSONDecoder.lyfe.decode(MoneyGlance.self, from: Data(MoneyFixture.glance.utf8))
        #expect(MoneyText.homeLine(glance) == "Money · NOV 165 CAD · 4 to sort")
        glance.toSort = 0
        #expect(MoneyText.homeLine(glance) == "Money · NOV 165 CAD")
    }
}

@MainActor
@Suite struct MoneyModelTests {
    func sent(_ world: World, _ route: String) -> [[String: Any]] {
        world.backend.bodies(route).compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    func entryID(_ n: Int) -> UUID { UUID(uuidString: MoneyFixture.id(n))! }

    @Test func homeFromBeforeMoneyStillReadsAndCarriesItOnceThereIsABank() throws {
        #expect(Fixture.snapshot().money == nil)
        let json = Fixture.home().replacingOccurrences(of: "\"sources\":", with: "\"money\": \(MoneyFixture.glance), \"sources\":")
        let home = try JSONDecoder.lyfe.decode(HomeSnapshot.self, from: Data(json.utf8))
        #expect(home.money?.spentMinor == 16_500)
        #expect(home.money?.toSort == 4)
    }

    @Test func openingMoneyFetchesTheMonthAndOtherMonthsOnRequest() async throws {
        let world = World.signedIn()
        world.backend.on("GET /v1/money", .ok(MoneyFixture.month()), .ok(MoneyFixture.month("2026-10", later: "2026-11")))
        let model = world.launch()

        await model.loadMoney(month: nil)
        #expect(model.money?.month == "2026-11")
        #expect(model.money?.entries.count == 4)
        #expect(model.moneyProblem == nil)
        #expect(world.backend.lastRequest("GET /v1/money")?.url?.query == nil)

        await model.loadMoney(month: "2026-10")
        #expect(model.money?.month == "2026-10")
        let request = try #require(world.backend.lastRequest("GET /v1/money"))
        #expect(request.url?.query == "month=2026-10")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer device-token")
    }

    @Test func withNoConnectionTheMonthOnScreenStaysAndTheReasonIsSaid() async {
        let world = World.signedIn()
        world.backend.on("GET /v1/money", .ok(MoneyFixture.month()))
        let model = world.launch()
        await model.loadMoney(month: nil)

        world.backend.goDown()
        await model.loadMoney(month: "2026-10")
        #expect(model.money?.month == "2026-11")
        #expect(model.moneyProblem?.hasPrefix("Could not fetch the month: can't reach the server") == true)
        #expect(model.isOffline)

        world.backend.goDown(false)
        await model.loadMoney(month: nil)
        #expect(model.moneyProblem == nil)
        #expect(!model.isOffline)
    }

    @Test func sortingAPayeeGoesOnToTheNextEntryStillWaiting() async throws {
        let world = World.signedIn()
        world.backend.on("GET /v1/money", .ok(MoneyFixture.month()))
        let model = world.launch()
        await model.loadMoney(month: nil)

        // The bar opens the oldest one waiting.
        model.openSortingNext()
        #expect(model.sortingEntry == entryID(1))

        // The noodles sorted: the grocer is next.
        var entries = MoneyFixture.waitingEntries
        entries[3] = MoneyFixture.entry(
            1, day: "2026-11-02", name: "Noodle Bar", minor: -8_000, kind: "expense", category: "Eating out",
            sortedBy: "rule", account: "Card")
        world.backend.on(
            "POST /v1/money/entries/\(MoneyFixture.id(1))/sort", .ok(MoneyFixture.month(entries: entries, toSort: 3)))
        #expect(await model.sortMoney(entryID(1), to: .category("Eating out"), onlyThis: false) == nil)
        #expect(model.sortingEntry == entryID(2))
        let body = try #require(sent(world, "POST /v1/money/entries/\(MoneyFixture.id(1))/sort").first)
        #expect(body["to"] as? String == "Eating out")
        #expect(body["only_this"] as? Bool == false)
        #expect(body["month"] as? String == "2026-11")

        // The grocer said once takes its other entry with it: on to the pay.
        entries[2] = MoneyFixture.entry(
            2, day: "2026-11-03", name: "Corner Grocer", minor: -4_510, kind: "expense", category: "Groceries",
            sortedBy: "rule")
        entries[1] = MoneyFixture.entry(
            3, day: "2026-11-05", name: "Corner Grocer #2", minor: -3_990, kind: "expense", category: "Groceries",
            sortedBy: "rule", account: "Card")
        world.backend.on(
            "POST /v1/money/entries/\(MoneyFixture.id(2))/sort", .ok(MoneyFixture.month(entries: entries, toSort: 1)))
        await model.sortMoney(entryID(2), to: .category("Groceries"), onlyThis: false)
        #expect(model.sortingEntry == entryID(4))

        // The last one sorted closes the screen.
        entries[0] = MoneyFixture.entry(4, day: "2026-11-14", name: "Employer", minor: 300_000, kind: "income", sortedBy: "rule")
        world.backend.on(
            "POST /v1/money/entries/\(MoneyFixture.id(4))/sort", .ok(MoneyFixture.month(entries: entries, toSort: 0)))
        await model.sortMoney(entryID(4), to: .income, onlyThis: false)
        #expect(model.sortingEntry == nil)
        #expect(model.money?.toSort == 0)
        #expect(sent(world, "POST /v1/money/entries/\(MoneyFixture.id(4))/sort").first?["to"] as? String == "income")

        // Sorting one again, by itself, closes rather than moving on.
        model.openSorting(entryID(2))
        world.backend.on(
            "POST /v1/money/entries/\(MoneyFixture.id(2))/sort", .ok(MoneyFixture.month(entries: entries, toSort: 0)))
        await model.sortMoney(entryID(2), to: .category("Other"), onlyThis: true)
        #expect(model.sortingEntry == nil)
        #expect(sent(world, "POST /v1/money/entries/\(MoneyFixture.id(2))/sort").last?["only_this"] as? Bool == true)
    }

    @Test func aSortTheServerRefusesIsSaidAndTheEntryStaysOpen() async {
        let world = World.signedIn()
        world.backend.on("GET /v1/money", .ok(MoneyFixture.month()))
        world.backend.on("POST /v1/money/entries/\(MoneyFixture.id(1))/sort", .init(status: 400, body: "{}"))
        let model = world.launch()
        await model.loadMoney(month: nil)
        model.openSorting(entryID(1))

        #expect(await model.sortMoney(entryID(1), to: .income, onlyThis: false) == "The server would not sort it (400).")
        #expect(model.sortingEntry == entryID(1))
        #expect(model.money?.toSort == 4)
        // An entry that is not in the month shown opens nothing.
        model.closeSorting()
        model.openSorting(entryID(77))
        #expect(model.sortingEntry == nil)
    }

    @Test func anAccountIsSetAsideForTheMonthOnScreen() async throws {
        let world = World.signedIn()
        world.backend.on("GET /v1/money", .ok(MoneyFixture.month("2026-10", later: "2026-11")))
        world.backend.on(
            "PUT /v1/money/accounts/\(MoneyFixture.id(901))", .ok(MoneyFixture.month("2026-10", spent: 0, later: "2026-11")))
        let model = world.launch()
        await model.loadMoney(month: "2026-10")

        #expect(await model.setAside(account: entryID(901), true) == nil)
        let body = try #require(sent(world, "PUT /v1/money/accounts/\(MoneyFixture.id(901))").first)
        #expect(body["set_aside"] as? Bool == true)
        #expect(body["month"] as? String == "2026-10")
        #expect(model.money?.spentMinor == 0)
    }

    @Test func signingOutForgetsTheMonth() async {
        let world = World.signedIn()
        world.backend.on("GET /v1/money", .ok(MoneyFixture.month()), .init(status: 401, body: "{}"))
        let model = world.launch()
        await model.loadMoney(month: nil)
        #expect(model.money != nil)
        await model.loadMoney(month: nil)
        #expect(model.money == nil)
        #expect(model.phase == .signedOut)
    }
}
