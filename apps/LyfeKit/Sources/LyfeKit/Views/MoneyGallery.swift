#if DEBUG
    import SwiftUI

    /// Money with made-up figures: a debug build shows one when launched
    /// with LYFE_DEBUG_MONEY set to `month` (part sorted), `sorted`,
    /// `entries` (the list under the categories), `sort` (the sorting
    /// screen), `income` (the same for money in), `resort` (an entry sorted
    /// already), `trouble` (a bank to sign in to again), `empty` or
    /// `waiting`; to `worth`, `worth-new` (the first day kept) or
    /// `worth-plain` (no investments); or to `fire`, `fire-new` (no whole
    /// month yet), `fire-short` (more spent than comes in), `fire-there`
    /// (independent) or `plan` (what it assumes). A Worth or FIRE screen
    /// followed by `+` and a number, as in `fire+700`, shows what is that
    /// many points down it, which a screenshot cannot scroll to.
    public struct MoneyGallery: View {
        var screen: String

        public init(screen: String) {
            self.screen = screen
        }

        public var body: some View {
            let pieces = self.screen.split(separator: "+")
            let screen = pieces.first.map(String.init) ?? ""
            let down = pieces.count > 1 ? CGFloat(Int(pieces[1]) ?? 0) : 0
            let money = Self.shown(screen)
            Group {
                switch screen {
                case _ where down > 0:
                    VStack(spacing: 0) {
                        if screen.hasPrefix("worth") {
                            WorthSection(worth: Self.worth(screen), onAccount: { _ in })
                        } else {
                            FireSection(fire: Self.fire(screen), onPlan: {})
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: -down)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .foregroundStyle(Poster.ink)
                    .background(Poster.paper.ignoresSafeArea())
                case "sort":
                    SortEntryView(
                        entry: money.waiting[0], categories: money.categoryNames, currency: money.currency,
                        waiting: money.toSort, onSort: { _, _ in nil }, onClose: {})
                case "income":
                    SortEntryView(
                        entry: money.waiting.first { $0.amountMinor > 0 }!, categories: money.categoryNames, currency: money.currency,
                        waiting: money.toSort, onSort: { _, _ in nil }, onClose: {})
                case "resort":
                    SortEntryView(
                        entry: money.entries.first { $0.category == "Groceries" }!, categories: money.categoryNames,
                        currency: money.currency, onSort: { _, _ in nil }, onClose: {})
                case "waiting":
                    MoneyScreen(
                        money: nil, problem: "Could not fetch the month: can't reach the server (it did not answer in time (-1001)).",
                        onBack: {}, onMonth: { _ in }, onSort: { _ in }, onSortNext: {}, onSetAside: { _, _ in nil })
                case "worth", "worth-new", "worth-plain":
                    MoneyScreen(
                        money: money, worth: Self.worth(screen), section: .worth, onBack: {}, onMonth: { _ in },
                        onSort: { _ in }, onSortNext: {}, onSetAside: { _, _ in nil })
                case "fire", "fire-new", "fire-short", "fire-there":
                    MoneyScreen(
                        money: money, fire: Self.fire(screen), section: .fire, onBack: {}, onMonth: { _ in },
                        onSort: { _ in }, onSortNext: {}, onSetAside: { _, _ in nil })
                case "plan":
                    PlanView(plan: Self.fire("fire").plan, thisYear: 2026, onSave: { _ in nil }, onClose: {})
                default:
                    MoneyScreen(
                        money: money, onBack: {}, onMonth: { _ in }, onSort: { _ in }, onSortNext: {},
                        onSetAside: { _, _ in nil })
                }
            }
            .preferredColorScheme(.light)
        }

        static func shown(_ screen: String) -> MoneyMonth {
            var money = month(sorted: screen == "sorted", trouble: screen == "trouble", empty: screen == "empty")
            if screen == "entries" { money.categories = [] }
            return money
        }

        static let names = [
            "Groceries", "Eating out", "Fuel", "Transport", "Home", "Bills", "Subscriptions", "Health", "Shopping",
            "Fun", "Travel", "Other",
        ]

        static let source = SourceStatus(
            state: .ok, lastSuccessAt: Date().addingTimeInterval(-2 * 3_600),
            lastAttemptAt: Date().addingTimeInterval(-2 * 3_600), message: nil)

        static func day(_ back: Int, before today: CalendarDay) -> CalendarDay {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let date = calendar.date(from: DateComponents(year: today.year, month: today.month, day: today.day - back, hour: 12))!
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return CalendarDay(year: parts.year!, month: parts.month!, day: parts.day!)
        }

        /// Made-up accounts: two banks and a broker, with the same fund
        /// held in two accounts, one fund down on what was paid, and a
        /// little in the brokerage that is in no holding.
        static func worth(_ screen: String) -> MoneyWorth {
            let plain = screen == "worth-plain"
            func account(_ n: Int, _ name: String, _ bank: String, _ minor: Int, aside: Bool = false, invested: Bool = false)
                -> MoneyMonth.Account
            {
                MoneyMonth.Account(
                    id: UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", n))!, name: name,
                    connection: bank, currency: "CAD", balanceMinor: minor, availableMinor: nil,
                    balanceAt: Date().addingTimeInterval(-3_600), setAside: aside, stale: false, problem: nil,
                    invested: invested)
            }
            var accounts = [
                account(1, "Chequing", "First Bank", 284_512),
                account(2, "Everyday Card", "First Bank", -41_733),
                account(3, "Travel Card", "Second Bank", -6_217),
                account(4, "Savings", "First Bank", 1_250_000, aside: true),
            ]
            if !plain {
                accounts += [
                    account(5, "Brokerage", "Broker", 2_210_455, aside: true, invested: true),
                    account(6, "Retirement", "Broker", 398_975, aside: true, invested: true),
                ]
            }
            let invested = plain ? 0 : 2_609_430
            let total = 1_534_512 + invested - 47_950
            // Ten weeks drifting up with pay, down with rent, and with the
            // market's own noise on top.
            let today = CalendarDay(year: 2026, month: 11, day: 24)
            let days = screen == "worth-new" ? 1 : 71
            let series: [MoneyWorth.Point] = (0..<days).map { index in
                let back = days - 1 - index
                let drift = -Double(back) * 4_300
                let pay = Double((back + 3) % 14 < 2 ? 0 : -((back + 3) % 14)) * 9_000
                let market = sin(Double(back) * 0.55) * 31_000 + sin(Double(back) * 0.17) * 52_000
                return MoneyWorth.Point(
                    day: day(back, before: today), worthMinor: back == 0 ? total : total + Int(drift + pay + market))
            }
            return MoneyWorth(
                currency: "CAD", worthMinor: total, bankedMinor: 1_534_512, investedMinor: invested, owedMinor: 47_950,
                everydayMinor: 236_562, setAsideMinor: 1_250_000 + invested, recordedSince: series.first?.day,
                series: series,
                change: series.count > 30
                    ? .init(since: series[series.count - 31].day, minor: total - series[series.count - 31].worthMinor) : nil,
                holdings: plain
                    ? []
                    : [
                        .init(
                            symbol: "WRLD", name: "Whole World Equity Fund", currency: "CAD", sharesMicro: 390_400_000,
                            valueMinor: 1_946_995, costMinor: 1_670_000, accounts: ["Brokerage", "Retirement"]),
                        .init(
                            symbol: "HOME", name: "Home Market Index Fund", currency: "CAD", sharesMicro: 120_000_000,
                            valueMinor: 431_075, costMinor: 400_000, accounts: ["Brokerage"]),
                        .init(
                            symbol: "BOND", name: "Bond Fund", currency: "CAD", sharesMicro: 150_250_000,
                            valueMinor: 195_010, costMinor: 205_000, accounts: ["Brokerage"]),
                    ],
                heldMinor: plain ? 0 : 2_573_080, looseMinor: plain ? 0 : 36_350,
                paid: plain ? nil : .init(paidMinor: 2_275_000, worthMinor: 2_573_080, holdings: 3),
                accounts: accounts, problems: [], source: source)
        }

        /// A made-up year: pay twice a month with two months of three, and
        /// spending that moves about. Worked out the way the backend does.
        static func fire(_ screen: String) -> MoneyFire {
            let plan = MoneyPlan(withdrawalBp: 350, returnBp: 400, birthYear: 1998, coastAge: 65)
            let running = MoneyFire.Month(month: "2026-11", spentMinor: 194_117, incomeMinor: 314_000, whole: false)
            if screen == "fire-new" {
                return MoneyFire(
                    currency: "CAD", months: [running], counted: 0, monthlyIncomeMinor: nil, monthlySpentMinor: nil,
                    monthlyKeptMinor: nil, savingsRatePct: nil, yearlySpentMinor: nil, yearlyKeptMinor: nil,
                    setAsideMinor: 3_859_430, fiNumberMinor: nil, progressPct: nil, reached: false, yearsToFi: nil,
                    fiYear: nil, fiAge: nil, age: 28, coast: nil, onHandMinor: 1_486_562, runwayMonths: nil, ahead: [],
                    plan: plan, problems: [], source: source)
            }
            let short = screen == "fire-short"
            let income = [4_200, 4_200, 6_300, 4_200, 4_200, 4_200, 4_200, 6_300, 4_200, 4_200, 4_200, 4_200]
                .map { (short ? $0 / 2 : $0) * 100 }
            let spent = [2_710, 3_340, 2_480, 2_590, 2_820, 2_460, 2_930, 2_650, 3_120, 2_540, 2_760, 2_483].map { $0 * 100 }
            let names = [
                "2025-11", "2025-12", "2026-01", "2026-02", "2026-03", "2026-04", "2026-05", "2026-06", "2026-07",
                "2026-08", "2026-09", "2026-10",
            ]
            let months = zip(names, zip(spent, income)).map {
                MoneyFire.Month(month: $0, spentMinor: $1.0, incomeMinor: $1.1, whole: true)
            }
            let monthlyIncome = income.reduce(0, +) / 12
            let monthlySpent = spent.reduce(0, +) / 12
            let yearlySpent = monthlySpent * 12
            let yearlyKept = (monthlyIncome - monthlySpent) * 12
            let setAside = screen == "fire-there" ? 96_000_000 : 3_859_430
            let number = Double(yearlySpent) / 0.035
            let growth = 0.04
            let level = Double(setAside) + Double(yearlyKept) / growth
            let reached = Double(setAside) >= number
            let years: Double? =
                reached ? 0 : (level > 0 ? log((number + Double(yearlyKept) / growth) / level) / log(1 + growth) : nil)
            let until = min(60, max(10, years.map { Int($0.rounded(.up)) + 2 } ?? 37))
            let coastNumber = number / pow(1 + growth, 37)
            return MoneyFire(
                currency: "CAD", months: months + [running], counted: 12, monthlyIncomeMinor: monthlyIncome,
                monthlySpentMinor: monthlySpent, monthlyKeptMinor: monthlyIncome - monthlySpent,
                savingsRatePct: (Double(monthlyIncome - monthlySpent) / Double(monthlyIncome) * 1_000).rounded() / 10,
                yearlySpentMinor: yearlySpent, yearlyKeptMinor: yearlyKept, setAsideMinor: setAside,
                fiNumberMinor: Int(number.rounded()), progressPct: (Double(setAside) / number * 1_000).rounded() / 10,
                reached: reached, yearsToFi: years.map { ($0 * 10).rounded() / 10 },
                fiYear: years.map { 2026 + Int(($0 + 0.9).rounded(.down)) }, fiAge: years.map { 28 + Int(($0 + 0.9).rounded(.down)) },
                age: 28,
                coast: .init(
                    age: 65, years: 37, numberMinor: Int(coastNumber.rounded()),
                    progressPct: (Double(setAside) / coastNumber * 1_000).rounded() / 10,
                    reached: Double(setAside) >= coastNumber),
                onHandMinor: 1_486_562, runwayMonths: (Double(1_486_562) / Double(monthlySpent) * 10).rounded() / 10,
                ahead: (0...until).map { year in
                    let factor = pow(1 + growth, Double(year))
                    return .init(
                        year: 2026 + year, age: 28 + year,
                        keptMinor: max(0, Int(Double(setAside) * factor + Double(yearlyKept) * (factor - 1) / growth)),
                        coastMinor: Int(Double(setAside) * factor))
                }, plan: plan, problems: [], source: source)
        }

        /// A made-up November: two banks, a card paid from chequing, a
        /// refund, and a few payees nobody has sorted yet.
        static func month(sorted: Bool = false, trouble: Bool = false, empty: Bool = false) -> MoneyMonth {
            typealias Entry = MoneyMonth.Entry
            var number = 0
            func entry(
                _ day: Int, _ name: String, _ minor: Int, _ account: String, _ category: String? = nil,
                kind: Entry.Kind? = nil, by: Entry.SortedBy? = nil
            ) -> Entry {
                number += 1
                let waits = category == nil && kind == nil && !sorted
                let kind = kind ?? (minor < 0 ? .expense : (category == nil ? .income : .refund))
                return Entry(
                    id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!,
                    day: CalendarDay(year: 2026, month: 11, day: day), name: name, amountMinor: minor, currency: "CAD",
                    kind: kind, category: category ?? (sorted && kind == .expense ? "Other" : nil),
                    sortedBy: by ?? (waits ? .auto : .rule), toSort: waits, hasPayee: true, account: account)
            }
            let entries: [Entry] =
                empty
                ? []
                : [
                    entry(17, "Corner Grocer", -6_412, "Everyday Card", "Groceries"),
                    entry(16, "Harbour Fuel", -7_150, "Everyday Card", "Fuel"),
                    entry(15, "Bookshop on Main", -3_299, "Everyday Card"),
                    entry(14, "Pay", 310_000, "Chequing", kind: .income),
                    entry(13, "Noodle Bar", -2_860, "Everyday Card", "Eating out"),
                    entry(12, "Payment received", 85_000, "Everyday Card", kind: .transfer, by: .match),
                    entry(12, "Streaming Co", -1_699, "Travel Card", "Subscriptions"),
                    entry(11, "Card payment", -85_000, "Chequing", kind: .transfer, by: .match),
                    entry(10, "Corner Grocer", 1_250, "Everyday Card", "Groceries"),
                    entry(9, "E-transfer from R.", 4_000, "Chequing"),
                    entry(8, "Corner Grocer", -11_840, "Everyday Card", "Groceries"),
                    entry(6, "City Transit", -3_350, "Chequing", "Transport"),
                    entry(5, "Hardware & Co", -4_518, "Travel Card"),
                    entry(3, "Power Company", -9_240, "Chequing", "Bills"),
                    entry(1, "Landlord", -145_000, "Chequing", "Home"),
                ]
            let counted = entries.filter { $0.kind == .expense || $0.kind == .refund }
            var byCategory: [String: (Int, Int)] = [:]
            for entry in counted {
                guard let category = entry.category else { continue }
                byCategory[category, default: (0, 0)].0 -= entry.amountMinor
                byCategory[category, default: (0, 0)].1 += 1
            }
            func account(_ n: Int, _ name: String, _ bank: String, _ minor: Int, aside: Bool = false, old: Bool = false)
                -> MoneyMonth.Account
            {
                MoneyMonth.Account(
                    id: UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", n))!, name: name,
                    connection: bank, currency: n == 5 ? "USD" : "CAD", balanceMinor: minor, availableMinor: nil,
                    balanceAt: Date().addingTimeInterval(old ? -5 * 86_400 : -3_600), setAside: aside, stale: old,
                    problem: nil)
            }
            return MoneyMonth(
                month: "2026-11", current: true, earlier: "2026-10", later: nil, currency: "CAD",
                spentMinor: -counted.map(\.amountMinor).reduce(0, +),
                unsortedMinor: -counted.filter { $0.category == nil }.map(\.amountMinor).reduce(0, +),
                toSort: entries.filter(\.toSort).count,
                incomeMinor: entries.filter { $0.kind == .income }.map(\.amountMinor).reduce(0, +),
                previous: empty ? nil : .init(month: "2026-10", spentMinor: 248_310, byNowMinor: 212_640),
                categories: byCategory.map { .init(name: $0.key, spentMinor: $0.value.0, entries: $0.value.1) }
                    .sorted { ($0.spentMinor, $1.name) > ($1.spentMinor, $0.name) },
                entries: entries,
                accounts: [
                    account(1, "Chequing", "First Bank", 284_512),
                    account(2, "Everyday Card", "First Bank", -41_733),
                    account(3, "Travel Card", "Second Bank", -6_217, old: trouble),
                    account(4, "Savings", "First Bank", 1_250_000, aside: true),
                    account(5, "Brokerage", "Broker", 2_210_455, aside: true),
                ],
                everydayMinor: 284_512 - 41_733 - 6_217, setAsideMinor: 1_250_000, categoryNames: names,
                problems: trouble ? [.init(text: "Second Bank: Sign in again to keep it updating", reconnect: true)] : [],
                source: source)
        }
    }
#endif
