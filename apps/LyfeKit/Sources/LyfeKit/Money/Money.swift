import Foundation

/// The three things Money shows: a month's spending, what everything comes
/// to, and how far off financial independence is.
public enum MoneySection: String, CaseIterable, Sendable {
    case month, worth, fire

    var title: String {
        switch self {
        case .month: "MONTH"
        case .worth: "WORTH"
        case .fire: "FIRE"
        }
    }
}

/// The little of money Home shows. Missing while no bank is set up.
public struct MoneyGlance: Codable, Equatable, Sendable {
    /// "2026-11"
    public var month: String
    public var currency: String
    public var spentMinor: Int
    public var toSort: Int
    /// The first thing wrong with where the figures come from, if anything.
    public var problem: String?
    public var lastSuccessAt: Date?
}

/// A month of money as the backend worked it out. Amounts are in minor
/// units (cents). The backend decides what an entry is; the app shows it
/// and passes on what the owner says.
public struct MoneyMonth: Codable, Equatable, Sendable {
    /// "2026-11"
    public var month: String
    /// True for the month today is in.
    public var current: Bool
    /// The nearest months with anything in them, either way.
    public var earlier: String?
    public var later: String?
    /// The currency the totals are in.
    public var currency: String
    /// Expenses less refunds, sorted or not. Transfers are never in it.
    public var spentMinor: Int
    public var unsortedMinor: Int
    /// Entries still waiting for the owner.
    public var toSort: Int
    public var incomeMinor: Int
    /// Missing when the history does not cover the whole month before.
    public var previous: Previous?
    /// Largest first.
    public var categories: [Category]
    /// Newest first.
    public var entries: [Entry]
    public var accounts: [Account]
    /// What is in the bank less what is owed on cards.
    public var everydayMinor: Int
    public var setAsideMinor: Int
    public var categoryNames: [String]
    public var problems: [Problem]
    public var source: SourceStatus

    public struct Previous: Codable, Equatable, Sendable {
        public var month: String
        public var spentMinor: Int
        /// What had been spent by the same day of that month.
        public var byNowMinor: Int?
    }

    public struct Category: Codable, Equatable, Sendable, Identifiable {
        public var name: String
        public var spentMinor: Int
        public var entries: Int

        public var id: String { name }
    }

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var day: CalendarDay
        public var name: String
        /// Negative for money out.
        public var amountMinor: Int
        public var currency: String
        public var kind: Kind
        public var category: String?
        public var sortedBy: SortedBy
        public var toSort: Bool
        /// False when the bank gave nothing to tell the payee by.
        public var hasPayee: Bool
        public var account: String

        public enum Kind: String, Codable, Sendable {
            case expense, refund, income, transfer
        }

        public enum SortedBy: String, Codable, Sendable {
            /// Nobody yet.
            case auto
            /// The other half of the transfer was found.
            case match
            /// What the owner said of its payee.
            case rule
            /// What the owner said of this one entry.
            case owner
        }
    }

    public struct Account: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        /// The bank it is at.
        public var connection: String
        public var currency: String
        public var balanceMinor: Int
        public var availableMinor: Int?
        public var balanceAt: Date
        /// Savings or investments: on show, and never spending.
        public var setAside: Bool
        /// The bank has not refreshed the balance for some days.
        public var stale: Bool
        public var problem: String?
        /// The bank lists what it holds: an investment account. Missing in
        /// an answer from a backend older than that.
        public var invested: Bool?
    }

    public struct Problem: Codable, Equatable, Sendable, Hashable {
        public var text: String
        /// True when the owner has to sign in to the bank again.
        public var reconnect: Bool
    }

    /// The entries waiting for the owner, oldest first: the order they are
    /// gone through in.
    public var waiting: [Entry] {
        Array(entries.filter(\.toSort).reversed())
    }
}

/// What the owner can say an entry is.
public enum MoneyChoice: Equatable, Sendable {
    case category(String)
    case income
    case transfer
    /// Takes back what was said.
    case unsorted

    /// As the backend takes it.
    var word: String {
        switch self {
        case .category(let name): name
        case .income: "income"
        case .transfer: "transfer"
        case .unsorted: "unsorted"
        }
    }
}

/// The words and figures on the money screens. Plain functions, so they
/// can be checked without a screen.
public enum MoneyText {
    private static let months = [
        "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC",
    ]
    private static let fullMonths = [
        "JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER",
        "DECEMBER",
    ]

    private static func parts(_ month: String) -> (year: Int, month: Int)? {
        let pieces = month.split(separator: "-")
        guard pieces.count == 2, let year = Int(pieces[0]), let number = Int(pieces[1]), (1...12).contains(number)
        else { return nil }
        return (year, number)
    }

    /// "2026-11" becomes "NOV".
    static func short(_ month: String) -> String {
        parts(month).map { months[$0.month - 1] } ?? month
    }

    /// "2026-11" becomes "NOVEMBER 2026".
    static func long(_ month: String) -> String {
        parts(month).map { "\(fullMonths[$0.month - 1]) \($0.year)" } ?? month
    }

    private static func grouped(_ whole: Int) -> String {
        var digits = String(whole)
        var groups: [String] = []
        while digits.count > 3 {
            groups.insert(String(digits.suffix(3)), at: 0)
            digits.removeLast(3)
        }
        groups.insert(digits, at: 0)
        return groups.joined(separator: ",")
    }

    /// "1,234.56", with a real minus sign, whatever the phone's region.
    static func amount(_ minor: Int) -> String {
        let size = abs(minor)
        let text = "\(grouped(size / 100)).\(String(format: "%02d", size % 100))"
        return minor < 0 ? "−" + text : text
    }

    /// "1,235": to the nearest whole unit, for the giant figure.
    static func whole(_ minor: Int) -> String {
        let size = (abs(minor) + 50) / 100
        return minor < 0 && size > 0 ? "−" + grouped(size) : grouped(size)
    }

    /// The line beside the heading: this month against the last. Empty
    /// while the history does not cover the month before.
    static func comparison(_ money: MoneyMonth) -> String {
        guard let previous = money.previous else { return "" }
        let then = short(previous.month)
        guard let byNow = previous.byNowMinor else {
            return "\(then) WAS \(whole(previous.spentMinor))"
        }
        let difference = money.spentMinor - byNow
        if abs(difference) < 100 { return "LEVEL WITH \(then) BY NOW" }
        return "\(whole(abs(difference))) \(difference < 0 ? "LESS" : "MORE") THAN \(then) BY NOW"
    }

    /// Under the figure.
    static func caption(_ money: MoneyMonth) -> String {
        var parts = ["\(money.currency) SPENT"]
        if money.unsortedMinor != 0 {
            parts.append("\(amount(money.unsortedMinor)) NOT SORTED")
        }
        return parts.joined(separator: " · ")
    }

    /// The line under the header's bar.
    static func inLine(_ money: MoneyMonth) -> String {
        money.incomeMinor == 0 ? "NOTHING IN YET" : "\(amount(money.incomeMinor)) IN"
    }

    /// How much of the month's sorted spending a category is, 0 to 1,
    /// against the largest one, for its bar.
    static func share(_ category: MoneyMonth.Category, of money: MoneyMonth) -> Double {
        let largest = money.categories.map(\.spentMinor).max() ?? 0
        guard largest > 0, category.spentMinor > 0 else { return 0 }
        return Double(category.spentMinor) / Double(largest)
    }

    static func categoryDetail(_ category: MoneyMonth.Category, of money: MoneyMonth) -> String {
        let count = category.entries == 1 ? "1 ENTRY" : "\(category.entries) ENTRIES"
        guard money.spentMinor > 0, category.spentMinor > 0 else { return count }
        let percent = Int((Double(category.spentMinor) / Double(money.spentMinor) * 100).rounded())
        return "\(count) · \(percent)%"
    }

    /// What an entry is, in a word or two.
    static func what(_ entry: MoneyMonth.Entry) -> String {
        if entry.toSort { return "TO SORT" }
        switch entry.kind {
        case .expense: return entry.category?.uppercased() ?? "NOT SORTED"
        case .refund: return "MONEY BACK · \(entry.category?.uppercased() ?? "")"
        case .income: return "MONEY IN"
        case .transfer: return entry.sortedBy == .match ? "MOVED · PAIRED" : "MOVED"
        }
    }

    /// The line under an entry's name: "TUE 3 NOV · CARD · GROCERIES".
    static func detail(_ entry: MoneyMonth.Entry) -> String {
        "\(entry.day.shortLabel) · \(entry.account.uppercased()) · \(what(entry))"
    }

    /// An entry's figure: what was spent plain, money in with a plus, and
    /// its currency when that is not the one the totals are in.
    static func figure(_ entry: MoneyMonth.Entry, in currency: String) -> String {
        let text = entry.amountMinor > 0 ? "+" + amount(entry.amountMinor) : amount(-entry.amountMinor)
        return entry.currency == currency ? text : "\(text) \(entry.currency)"
    }

    /// Whether an entry counts in the month's spending, for its mark:
    /// solid when sorted, outline while waiting, striped when it is not
    /// spending at all.
    static func mark(_ entry: MoneyMonth.Entry) -> MarkState {
        if entry.toSort { return .outline }
        switch entry.kind {
        case .expense, .refund: return entry.category == nil ? .outline : .solid
        case .income, .transfer: return .striped
        }
    }

    static func accountDetail(_ account: MoneyMonth.Account, now: Date) -> String {
        var parts = [account.connection.uppercased()]
        if account.invested == true { parts.append("INVESTED") }
        if account.setAside { parts.append("SET ASIDE") }
        if let problem = account.problem {
            parts.append(problem.uppercased())
        } else if account.stale {
            parts.append("LAST SEEN \(agoLabel(from: account.balanceAt, to: now))")
        }
        return parts.joined(separator: " · ")
    }

    static func balance(_ account: MoneyMonth.Account, in currency: String) -> String {
        let text = amount(account.balanceMinor)
        return account.currency == currency ? text : "\(text) \(account.currency)"
    }

    /// The black bar on Money.
    static func bar(_ money: MoneyMonth) -> (small: String, big: String, opensSorting: Bool) {
        if money.toSort > 0 {
            let count = money.toSort == 1 ? "1 ENTRY" : "\(money.toSort) ENTRIES"
            return ("\(count) · ONCE FOR EACH PAYEE", "SORT THEM", true)
        }
        if money.entries.isEmpty {
            return (money.current ? "NOTHING POSTED YET THIS MONTH" : "NOTHING IN THIS MONTH", long(money.month), false)
        }
        return ("\(long(money.month)) · \(whole(money.spentMinor)) \(money.currency)", "ALL SORTED", false)
    }

    /// Where the figures come from and how fresh they are.
    static func sourceLine(_ source: SourceStatus, now: Date) -> (mark: MarkState, left: String, right: String) {
        let synced = source.lastSuccessAt.map { "IMPORTED \(agoLabel(from: $0, to: now))" }
        switch source.state {
        case .ok: return (.solid, "BANKS", synced ?? "IMPORTED")
        case .failing: return (.striped, "BANKS", synced ?? "NEVER IMPORTED")
        case .neverSynced: return (.outline, "BANKS", "FIRST IMPORT TO COME")
        case .notConfigured: return (.outline, "BANKS", "NOT CONNECTED")
        }
    }

    /// The strip on Home that leads to Money.
    static func homeLine(_ glance: MoneyGlance) -> String {
        var parts = ["Money · \(short(glance.month)) \(whole(glance.spentMinor)) \(glance.currency)"]
        if glance.toSort > 0 {
            parts.append("\(glance.toSort) to sort")
        }
        return parts.joined(separator: " · ")
    }

    /// The question over the choices, and what a choice will hold for.
    static func scope(_ entry: MoneyMonth.Entry, onlyThis: Bool) -> String {
        if !entry.hasPayee { return "THE BANK NAMED NO PAYEE · THIS ENTRY ONLY" }
        return onlyThis ? "THIS ENTRY ONLY" : "EVERY ENTRY FROM THIS PAYEE, PAST AND TO COME"
    }

    /// A problem as it is shown, with what to do about it.
    static func notice(_ problem: MoneyMonth.Problem) -> String {
        guard problem.reconnect else { return problem.text }
        let said = problem.text.hasSuffix(".") ? String(problem.text.dropLast()) : problem.text
        return "\(said). Sign in to it again at SimpleFIN Bridge."
    }

    static func asideQuestion(_ account: MoneyMonth.Account) -> String {
        account.setAside
            ? "Bring \(account.name) back? What moves in it counts as spending and income again."
            : "Set \(account.name) aside? For savings and investments: its balance stays on show, and nothing in it counts as spending."
    }
}
