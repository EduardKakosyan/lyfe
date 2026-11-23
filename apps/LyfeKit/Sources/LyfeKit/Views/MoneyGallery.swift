#if DEBUG
    import SwiftUI

    /// Money with made-up figures: a debug build shows one when launched
    /// with LYFE_DEBUG_MONEY set to `month` (part sorted), `sorted`,
    /// `entries` (the list under the categories), `sort` (the sorting
    /// screen), `income` (the same for money in), `resort` (an entry sorted
    /// already), `trouble` (a bank to sign in to again), `empty` or
    /// `waiting`.
    public struct MoneyGallery: View {
        var screen: String

        public init(screen: String) {
            self.screen = screen
        }

        public var body: some View {
            let money = Self.shown(screen)
            Group {
                switch screen {
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
                source: SourceStatus(
                    state: .ok, lastSuccessAt: Date().addingTimeInterval(-2 * 3_600),
                    lastAttemptAt: Date().addingTimeInterval(-2 * 3_600), message: nil))
        }
    }
#endif
