import Foundation

/// What the owner assumes when lyfe works out how far off financial
/// independence is. Rates are in hundredths of a percent.
public struct MoneyPlan: Codable, Equatable, Sendable {
    /// The share of what is set aside that can be spent each year for good.
    public var withdrawalBp: Int
    /// Growth a year above inflation.
    public var returnBp: Int
    /// Only for saying an age; missing until the owner gives it.
    public var birthYear: Int?
    /// The age the coast number is worked out for.
    public var coastAge: Int

    public init(withdrawalBp: Int, returnBp: Int, birthYear: Int?, coastAge: Int) {
        self.withdrawalBp = withdrawalBp
        self.returnBp = returnBp
        self.birthYear = birthYear
        self.coastAge = coastAge
    }

    /// What the backend takes, and the steps the entry moves in.
    public static let withdrawal = (range: 200...600, step: 25)
    public static let growth = (range: 0...1000, step: 50)
    public static let coast = (range: 40...80, step: 1)
}

/// How far off financial independence is, as the backend worked it out.
/// What came in and what was spent is measured; everything from the FI
/// number on is worked out from that and from the plan, in today's money.
public struct MoneyFire: Codable, Equatable, Sendable {
    public var currency: String
    /// The whole months counted, oldest first, then the month running.
    public var months: [Month]
    /// How many whole months the averages are from.
    public var counted: Int
    public var monthlyIncomeMinor: Int?
    public var monthlySpentMinor: Int?
    public var monthlyKeptMinor: Int?
    /// What was kept as a share of what came in, in percent.
    public var savingsRatePct: Double?
    public var yearlySpentMinor: Int?
    public var yearlyKeptMinor: Int?
    /// What counts towards independence: every account set aside.
    public var setAsideMinor: Int
    /// A year's spending divided by the withdrawal rate.
    public var fiNumberMinor: Int?
    public var progressPct: Double?
    public var reached: Bool
    /// Missing when it is not reached at this rate, or cannot be told.
    public var yearsToFi: Double?
    public var fiYear: Int?
    public var fiAge: Int?
    public var age: Int?
    public var coast: Coast?
    /// What is in the bank less what is owed.
    public var onHandMinor: Int
    /// How many months of spending that covers.
    public var runwayMonths: Double?
    /// A point a year from this year on.
    public var ahead: [Ahead]
    public var plan: MoneyPlan
    /// What stops the figures from being right: a failed import, a bank
    /// to sign in to again. A month a bank was missing from reads low.
    public var problems: [MoneyMonth.Problem]
    public var source: SourceStatus

    public struct Month: Codable, Equatable, Sendable, Identifiable {
        /// "2026-11"
        public var month: String
        public var spentMinor: Int
        public var incomeMinor: Int
        /// False for the month still running, which no average counts.
        public var whole: Bool

        public var id: String { month }
    }

    /// What would grow to the FI number by itself by a given age.
    public struct Coast: Codable, Equatable, Sendable {
        public var age: Int
        public var years: Int
        public var numberMinor: Int
        public var progressPct: Double
        public var reached: Bool
    }

    /// What is set aside in a year to come.
    public struct Ahead: Codable, Equatable, Sendable {
        public var year: Int
        public var age: Int?
        /// With a year's keeping added each year.
        public var keptMinor: Int
        /// With nothing more added.
        public var coastMinor: Int
    }
}

/// The words and figures on FIRE. Plain functions, so they can be checked
/// without a screen.
public enum FireText {
    /// "33.3", "60", "−20": one decimal where there is one, a real minus.
    static func number(_ value: Double) -> String {
        let tenths = (abs(value) * 10).rounded()
        let text = tenths.truncatingRemainder(dividingBy: 10) == 0 ? String(Int(tenths / 10)) : String(format: "%.1f", tenths / 10)
        return value < 0 && tenths > 0 ? "−" + text : text
    }

    /// "3.5%", "3.25%", "4%": a rate held in hundredths of a percent.
    static func rate(_ bp: Int) -> String {
        var text = String(format: "%.2f", Double(bp) / 100)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "%"
    }

    /// "LAST 12 MONTHS": what the averages are from.
    static func basis(_ fire: MoneyFire) -> String {
        switch fire.counted {
        case 0: "NO WHOLE MONTH YET"
        case 1: "FROM LAST MONTH"
        default: "FROM THE LAST \(fire.counted) MONTHS"
        }
    }

    /// The giant figure: what was kept of what came in.
    static func hero(_ fire: MoneyFire) -> (figure: String, caption: String) {
        guard fire.counted > 0 else { return ("–", "KEPT · NEEDS A WHOLE MONTH OF ENTRIES") }
        guard let rate = fire.savingsRatePct else { return ("–", "KEPT · NOTHING CAME IN") }
        return ("\(number(rate.rounded()))%", "OF WHAT CAME IN, KEPT")
    }

    /// Beside the heading: how far off independence is.
    static func headline(_ fire: MoneyFire) -> String {
        if fire.reached { return "INDEPENDENT" }
        if let years = fire.yearsToFi {
            // A cent short of it is not nought years off.
            if years < 0.1 { return "FI THIS YEAR" }
            return "FI IN \(number(years)) \(years == 1 ? "YEAR" : "YEARS")"
        }
        return fire.fiNumberMinor == nil ? "" : "NOT AT THIS RATE"
    }

    /// "2040 · AGE 38": when it is reached.
    static func when(_ fire: MoneyFire) -> String {
        guard !fire.reached, let year = fire.fiYear else { return "" }
        return fire.fiAge.map { "\(year) · AGE \($0)" } ?? "\(year)"
    }

    /// The whole months as a label and a figure each.
    static func flowRows(_ fire: MoneyFire) -> [(String, String)] {
        guard let income = fire.monthlyIncomeMinor, let spent = fire.monthlySpentMinor, let kept = fire.monthlyKeptMinor
        else { return [] }
        return [
            ("In, a month", MoneyText.amount(income)),
            ("Spent", MoneyText.amount(spent)),
            (kept < 0 ? "Short" : "Kept", MoneyText.amount(abs(kept))),
        ]
    }

    /// One letter under a bar where there are many, three where they fit.
    static func monthLabel(_ month: String, of count: Int) -> String {
        let short = MoneyText.short(month)
        return count > 7 ? String(short.prefix(1)) : short
    }

    /// What the plan assumes, in a line.
    static func assumed(_ plan: MoneyPlan) -> String {
        "\(rate(plan.withdrawalBp)) DRAWN A YEAR · \(rate(plan.returnBp)) GROWTH"
    }

    /// "× 28.6": how many years' spending the FI number is.
    static func multiple(_ plan: MoneyPlan) -> String {
        guard plan.withdrawalBp > 0 else { return "" }
        return "× \(number(10_000 / Double(plan.withdrawalBp)))"
    }

    /// How full the bar towards the FI number is, 0 to 1.
    static func progress(_ fire: MoneyFire) -> Double {
        guard let number = fire.fiNumberMinor, number > 0 else { return 0 }
        return min(1, max(0, Double(fire.setAsideMinor) / Double(number)))
    }

    /// Where on that bar the coast number sits, 0 to 1.
    static func coastMark(_ fire: MoneyFire) -> Double? {
        guard let coast = fire.coast, let number = fire.fiNumberMinor, number > 0 else { return nil }
        return min(1, max(0, Double(coast.numberMinor) / Double(number)))
    }

    /// Under the bar: how far along, in words.
    static func progressLine(_ fire: MoneyFire) -> String {
        guard let percent = fire.progressPct else { return "" }
        if fire.reached { return "ALL OF IT IS SET ASIDE" }
        return "\(number(percent))% OF THE WAY"
    }

    /// What the tick on the bar is: the coast number, and how far along
    /// to it what is set aside is.
    static func coastLine(_ coast: MoneyFire.Coast) -> String {
        let number = "COAST NUMBER \(MoneyText.whole(coast.numberMinor))"
        return coast.reached
            ? "\(number) · PASSED: IT GROWS THERE BY \(coast.age) WITH NOTHING ADDED"
            : "\(number) GROWS THERE BY \(coast.age) WITH NOTHING ADDED · \(self.number(coast.progressPct))% OF IT SET ASIDE"
    }

    /// Everything the number is worked out from, a label and a figure each.
    static func numberRows(_ fire: MoneyFire) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let spent = fire.yearlySpentMinor {
            rows.append(("Spending a year", MoneyText.amount(spent)))
        }
        if let number = fire.fiNumberMinor {
            rows.append(("FI number · \(multiple(fire.plan))", MoneyText.amount(number)))
        }
        rows.append(("Set aside", MoneyText.amount(fire.setAsideMinor)))
        if let kept = fire.yearlyKeptMinor {
            rows.append((kept < 0 ? "Short a year" : "Kept a year", MoneyText.amount(abs(kept))))
        }
        if fire.fiNumberMinor != nil {
            let reached = fire.reached ? "NOW" : (when(fire).isEmpty ? "NOT AT THIS RATE" : when(fire))
            rows.append(("Reached", reached))
        }
        if let coast = fire.coast {
            rows.append(("Coast number · by \(coast.age)", MoneyText.amount(coast.numberMinor)))
        }
        return rows
    }

    /// The legend of the line ahead.
    static func aheadLegend(_ fire: MoneyFire) -> (kept: String, coast: String) {
        let kept = fire.yearlyKeptMinor ?? 0
        return (
            kept < 0 ? "SHORT \(MoneyText.whole(-kept)) A YEAR" : "KEEPING \(MoneyText.whole(kept)) A YEAR",
            "ADDING NOTHING"
        )
    }

    /// The ends of the line ahead: now, and the last year drawn.
    static func aheadEnds(_ fire: MoneyFire) -> (from: String, to: String) {
        guard let first = fire.ahead.first, let last = fire.ahead.last else { return ("", "") }
        if let from = first.age, let to = last.age { return ("NOW · AGE \(from)", "AGE \(to)") }
        return ("NOW · \(first.year)", "\(last.year)")
    }

    /// "2 MONTHS", "7.5 MONTHS".
    static func runway(_ fire: MoneyFire) -> String {
        guard let months = fire.runwayMonths else { return "–" }
        return "\(number(months)) \(months == 1 ? "MONTH" : "MONTHS")"
    }

    /// How full the runway bar is: six months fills it.
    static func runwayShare(_ fire: MoneyFire) -> Double {
        min(1, max(0, (fire.runwayMonths ?? 0) / runwayFull))
    }

    /// The months of spending that fill the runway bar, and the mark on it:
    /// three to six months is the cushion usually advised.
    static let runwayFull = 6.0
    static let runwayMark = 3.0

    static func runwayLine(_ fire: MoneyFire) -> String {
        "\(MoneyText.amount(fire.onHandMinor)) ON HAND · 3 TO 6 MONTHS IS THE USUAL CUSHION"
    }

    /// What the figures leave out, said once at the foot.
    static let footnote =
        "Worked out from what the banks show: pay as it lands, so what is taken off before it for tax or a plan at work is in neither figure. Everything ahead is in today's money."

    /// The bars of what came in and was spent, in words.
    static func flowsSpoken(_ fire: MoneyFire) -> String {
        let rows = flowRows(fire)
        guard !rows.isEmpty else { return "What came in and was spent a month: no whole month yet" }
        return rows.map { "\($0.0) \($0.1)" }.joined(separator: ", ") + ", \(basis(fire).lowercased())"
    }

    static func spoken(_ fire: MoneyFire) -> String {
        var parts: [String] = []
        if let rate = fire.savingsRatePct {
            parts.append("\(number(rate.rounded())) percent of what came in was kept")
        } else {
            parts.append("No savings rate yet")
        }
        if fire.reached {
            parts.append("financially independent")
        } else if let years = fire.yearsToFi {
            parts.append("financial independence in \(number(years)) years")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: The plan entry

    /// A year typed as the owner's birth year, or nil when it is not one.
    /// Empty means none, which is allowed.
    static func birthYear(_ typed: String, thisYear: Int) -> Int?? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .some(nil) }
        guard let year = Int(text), (1900...thisYear).contains(year) else { return nil }
        return .some(year)
    }
}
