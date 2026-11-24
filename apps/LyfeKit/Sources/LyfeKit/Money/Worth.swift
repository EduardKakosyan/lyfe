import Foundation

/// What everything comes to, as the backend worked it out: every account
/// added up, the line that has drawn since lyfe began keeping it, and what
/// the investments are in. Amounts are in minor units (cents). Like a
/// month, it is fetched when it is opened and never kept on the phone.
public struct MoneyWorth: Codable, Equatable, Sendable {
    /// The currency the totals are in.
    public var currency: String
    /// In the bank and invested, less what is owed.
    public var worthMinor: Int
    /// What is in accounts that hold no investments.
    public var bankedMinor: Int
    /// The balances of the accounts the bank lists holdings for.
    public var investedMinor: Int
    /// What is owed, on cards mostly, as a figure above zero.
    public var owedMinor: Int
    public var everydayMinor: Int
    public var setAsideMinor: Int
    /// The first day a balance was kept; the line starts there.
    public var recordedSince: CalendarDay?
    /// Net worth a day at a time, oldest first, today last.
    public var series: [Point]
    public var change: Change?
    /// Largest first.
    public var holdings: [Holding]
    /// The holdings added up.
    public var heldMinor: Int
    /// What sits in investment accounts and in no holding.
    public var looseMinor: Int
    public var paid: Paid?
    public var accounts: [MoneyMonth.Account]
    public var problems: [MoneyMonth.Problem]
    public var source: SourceStatus

    public struct Point: Codable, Equatable, Sendable {
        public var day: CalendarDay
        public var worthMinor: Int
    }

    /// How net worth moved since an earlier day.
    public struct Change: Codable, Equatable, Sendable {
        public var since: CalendarDay
        public var minor: Int
    }

    /// One thing the investments are in, across every account holding it.
    public struct Holding: Codable, Equatable, Sendable, Identifiable {
        /// The ticker, or empty when the bank gives none.
        public var symbol: String
        public var name: String
        public var currency: String
        /// In millionths; zero when the bank does not say.
        public var sharesMicro: Int
        public var valueMinor: Int
        /// What was paid for it, when the bank says.
        public var costMinor: Int?
        /// The accounts it is held in, by name.
        public var accounts: [String]

        public var id: String { "\(symbol)|\(name)|\(currency)" }
    }

    /// What the holdings are worth against what was paid for them, over
    /// the ones the bank gives a cost for.
    public struct Paid: Codable, Equatable, Sendable {
        public var paidMinor: Int
        public var worthMinor: Int
        public var holdings: Int
    }
}

/// The words and figures on Worth. Plain functions, so they can be checked
/// without a screen.
public enum WorthText {
    /// "▲ 5,550 SINCE 14 NOV": how net worth moved, beside the heading.
    /// Nothing until there is a day to set today against.
    static func changeLine(_ worth: MoneyWorth) -> String {
        guard let change = worth.change else { return "" }
        let since = "SINCE \(change.since.shortLabel)"
        if abs(change.minor) < 100 { return "LEVEL \(since)" }
        return "\(change.minor < 0 ? "▼" : "▲") \(MoneyText.whole(abs(change.minor))) \(since)"
    }

    /// "14 NOV", or "14 NOV 2025" once it is far enough back from the
    /// latest day kept that the year is no longer plain.
    static func dayLabel(_ day: CalendarDay, in worth: MoneyWorth) -> String {
        guard let latest = worth.series.last?.day, latest.ordinal - day.ordinal > 300 else { return day.shortLabel }
        return "\(day.shortLabel) \(day.year)"
    }

    /// Under the figure.
    static func caption(_ worth: MoneyWorth) -> String {
        "\(worth.currency) · EVERYTHING ADDED UP"
    }

    /// What the line says when there is not enough of it to draw.
    static func lineNote(_ worth: MoneyWorth) -> String {
        worth.series.isEmpty
            ? "The line starts with the next import: lyfe keeps what everything comes to once a day."
            : "The line starts today: lyfe keeps what everything comes to once a day, and draws it from tomorrow."
    }

    /// What net worth is made of, a bar each, drawn against the largest.
    /// What is owed is striped: it takes away.
    static func parts(_ worth: MoneyWorth) -> [(name: String, minor: Int, share: Double, mark: MarkState)] {
        let largest = max(worth.bankedMinor, worth.investedMinor, worth.owedMinor, 1)
        func share(_ minor: Int) -> Double { minor > 0 ? Double(minor) / Double(largest) : 0 }
        var parts: [(name: String, minor: Int, share: Double, mark: MarkState)] = [
            ("In the bank", worth.bankedMinor, share(worth.bankedMinor), .solid)
        ]
        if worth.investedMinor != 0 || !worth.holdings.isEmpty {
            parts.append(("Invested", worth.investedMinor, share(worth.investedMinor), .solid))
        }
        if worth.owedMinor > 0 {
            parts.append(("Owed", -worth.owedMinor, share(worth.owedMinor), .striped))
        }
        return parts
    }

    /// "420.5": as many decimals as it takes, four at most.
    static func shares(_ micro: Int) -> String {
        let tenThousandths = (micro + 50) / 100
        let whole = tenThousandths / 10_000
        var fraction = String(format: "%04d", tenThousandths % 10_000)
        while fraction.hasSuffix("0") { fraction.removeLast() }
        let grouped = MoneyText.whole(whole * 100)
        return fraction.isEmpty ? grouped : "\(grouped).\(fraction)"
    }

    /// What a holding is called: its ticker, or its name without one.
    static func title(_ holding: MoneyWorth.Holding) -> String {
        if !holding.symbol.isEmpty { return holding.symbol }
        return holding.name.isEmpty ? "Holding" : holding.name
    }

    /// How a holding stands against what was paid for it: "▲ 20%".
    static func growth(_ holding: MoneyWorth.Holding) -> String? {
        guard let cost = holding.costMinor, cost > 0 else { return nil }
        return moved(from: cost, to: holding.valueMinor)
    }

    /// "▲ 20%", "▼ 4.9%" or "LEVEL".
    static func moved(from: Int, to: Int) -> String {
        let percent = Double(to - from) / Double(from) * 100
        let text = FireText.number(abs(percent))
        if text == "0" { return "LEVEL" }
        return "\(percent < 0 ? "▼" : "▲") \(text)%"
    }

    /// Beside a holding's name: its share of the holdings and how many.
    static func holdingDetail(_ holding: MoneyWorth.Holding, of worth: MoneyWorth) -> String {
        var parts: [String] = []
        if holding.currency == worth.currency, worth.heldMinor > 0, holding.valueMinor > 0 {
            parts.append("\(Int((Double(holding.valueMinor) / Double(worth.heldMinor) * 100).rounded()))%")
        }
        if holding.sharesMicro > 0 {
            parts.append("\(shares(holding.sharesMicro)) \(holding.sharesMicro == 1_000_000 ? "SHARE" : "SHARES")")
        }
        return parts.joined(separator: " · ")
    }

    /// Under it: what it is, where it is held, and how it has done.
    static func holdingLine(_ holding: MoneyWorth.Holding) -> String {
        var parts: [String] = []
        if !holding.symbol.isEmpty, !holding.name.isEmpty { parts.append(holding.name.uppercased()) }
        if holding.accounts.count > 2 {
            parts.append("\(holding.accounts.count) ACCOUNTS")
        } else if !holding.accounts.isEmpty {
            parts.append(holding.accounts.map { $0.uppercased() }.joined(separator: ", "))
        }
        if let growth = growth(holding) { parts.append(growth) }
        return parts.joined(separator: " · ")
    }

    /// A holding's figure, with its currency when that is not the totals'.
    static func value(_ holding: MoneyWorth.Holding, in currency: String) -> String {
        let text = MoneyText.amount(holding.valueMinor)
        return holding.currency == currency ? text : "\(text) \(holding.currency)"
    }

    /// A holding's bar against the largest one; none for a holding in
    /// another currency, which cannot be set beside the rest.
    static func share(_ holding: MoneyWorth.Holding, of worth: MoneyWorth) -> Double {
        let largest = worth.holdings.filter { $0.currency == worth.currency }.map(\.valueMinor).max() ?? 0
        guard holding.currency == worth.currency, largest > 0, holding.valueMinor > 0 else { return 0 }
        return Double(holding.valueMinor) / Double(largest)
    }

    /// The bar of what was paid against what it is worth now: the part
    /// that is paid, 0 to 1, and whether the rest is growth or was lost.
    static func paidBar(_ paid: MoneyWorth.Paid) -> (solid: Double, grew: Bool) {
        let grew = paid.worthMinor >= paid.paidMinor
        let (part, whole) = grew ? (paid.paidMinor, paid.worthMinor) : (paid.worthMinor, paid.paidMinor)
        guard whole > 0 else { return (1, grew) }
        return (min(1, max(0, Double(part) / Double(whole))), grew)
    }

    /// Under that bar: "PAID 17,500 · GREW 3,500 · ▲ 20%".
    static func paidLine(_ paid: MoneyWorth.Paid, of worth: MoneyWorth) -> String {
        let difference = paid.worthMinor - paid.paidMinor
        var parts = ["PAID \(MoneyText.whole(paid.paidMinor))"]
        if paid.paidMinor > 0, abs(difference) >= 100 {
            parts.append("\(difference < 0 ? "LOST" : "GREW") \(MoneyText.whole(abs(difference)))")
            parts.append(moved(from: paid.paidMinor, to: paid.worthMinor))
        } else {
            parts.append("LEVEL")
        }
        let all = worth.holdings.filter { $0.currency == worth.currency }.count
        if paid.holdings < all {
            parts.append("\(paid.holdings) OF \(all) HOLDINGS")
        }
        return parts.joined(separator: " · ")
    }

    /// The range the line spans, top to bottom: "36,100–37,400 CAD".
    static func span(low: Int, high: Int, currency: String) -> String {
        "\(MoneyText.whole(low))–\(MoneyText.whole(high)) \(currency)"
    }

    static func spoken(_ worth: MoneyWorth) -> String {
        var parts = ["Net worth \(MoneyText.whole(worth.worthMinor)) \(worth.currency)"]
        if let change = worth.change, abs(change.minor) >= 100 {
            parts.append("\(change.minor < 0 ? "down" : "up") \(MoneyText.whole(abs(change.minor))) since \(change.since.shortLabel)")
        }
        // With no line to draw yet, what is said in its place is said here too.
        if worth.series.count < 2 { parts.append(lineNote(worth)) }
        return parts.joined(separator: ", ")
    }
}
