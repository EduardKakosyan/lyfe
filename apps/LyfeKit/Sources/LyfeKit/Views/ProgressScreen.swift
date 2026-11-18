import SwiftUI

/// Progress: whether things are improving, apart from whether the owner
/// showed up. For now the weight line: each morning's weight, and the
/// seven-day average drawn through them. The black bar is the weigh-in.
public struct ProgressScreen: View {
    let weight: WeightTrend?
    let today: CalendarDay
    /// Weights typed here that the backend does not have yet.
    var unsent: Int = 0
    var problem: String?
    let onBack: () -> Void
    let onWeighIn: () -> Void

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    PosterRule()
                    if let problem {
                        NoticeRow(text: problem)
                        PosterRule()
                    } else if unsent > 0 {
                        NoticeRow(text: WeightText.unsent(unsent))
                        PosterRule()
                    }
                    WeightSection(weight: weight, today: today)
                    if let weight {
                        WeightRows(rows: WeightText.rows(weight, today: today))
                    }
                }
            }
            let bar = WeightText.bar(weight, today: today)
            Button(action: onWeighIn) {
                BreathBar(small: bar.small, big: bar.big, mark: "→", onDark: false)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the weight entry")
        }
        .foregroundStyle(Poster.ink)
        .background(Poster.paper.ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Text("← Home").posterLabel().padding(.vertical, 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Last 8 weeks").posterLabel()
            }
            Text("PROGRESS")
                .font(.system(size: 38, weight: .heavy))
                .tracking(-1.6)
        }
        .padding(.horizontal, Poster.margin)
        .padding(.bottom, 8)
    }
}

/// The weight figure and its line.
struct WeightSection: View {
    let weight: WeightTrend?
    let today: CalendarDay

    var body: some View {
        let hero = WeightText.hero(weight)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Weight").posterHeading()
                    Text(hero.caption).posterLabel()
                }
                Spacer(minLength: 8)
                Text(Poster.tight(hero.figure, by: -3))
                    .font(.system(size: 66, weight: .heavy))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.numericText())
            }
            Text(WeightText.changeLine(weight)).posterLabel().padding(.top, 8)
            if let weight, !weight.days.isEmpty {
                WeightChart(days: weight.days, today: today)
                    .frame(height: 150)
                    .padding(.top, 16)
                let span = WeightChartLayout(days: weight.days, today: today, size: .zero)
                HStack {
                    Text(WeightText.chartStart(today: today)).posterLabel()
                    Spacer()
                    Text(WeightText.span(low: span.low, high: span.high, unit: weight.unit)).posterLabel().opacity(0.55)
                    Spacer()
                    Text("Today").posterLabel()
                }
                .padding(.top, 6)
            } else {
                Text("Your first weigh-in starts the line.")
                    .posterLabel()
                    .opacity(0.55)
                    .padding(.top, 16)
            }
        }
        .padding(.horizontal, Poster.margin)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WeightText.spoken(weight))
    }
}

/// The weight line: a small square for each morning's weight, and the
/// seven-day average as one heavy line through them.
struct WeightChart: View {
    let days: [WeightTrend.Day]
    let today: CalendarDay

    var body: some View {
        Canvas { context, size in
            let layout = WeightChartLayout(days: days, today: today, size: size)
            var baseline = Path()
            baseline.addRect(CGRect(x: 0, y: size.height - Poster.rule, width: size.width, height: Poster.rule))
            context.fill(baseline, with: .foreground)
            for point in layout.dots {
                let square = CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)
                context.fill(Path(square), with: .foreground)
            }
            for segment in layout.segments {
                var line = Path()
                line.addLines(segment)
                context.stroke(
                    line, with: .foreground, style: StrokeStyle(lineWidth: 4.5, lineCap: .square, lineJoin: .miter))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Where the weight line's marks go. Plain arithmetic, so it can be
/// checked without a screen.
struct WeightChartLayout {
    /// The values at the top and bottom of the chart.
    var low: Double
    var high: Double
    /// Runs of consecutive days with an average, one line each; a gap in
    /// the average breaks the line rather than bridging it.
    var segments: [[CGPoint]]
    /// One per weight typed.
    var dots: [CGPoint]

    /// The chart never spans less than this, so a flat month is drawn
    /// flat instead of every gram looking like a cliff.
    static let minimumSpan = 2.0
    /// Days across the chart, today included.
    static let daysShown = 56

    init(days: [WeightTrend.Day], today: CalendarDay, size: CGSize) {
        let values = days.flatMap { [$0.value, $0.average].compactMap { $0 } }
        var low = values.min() ?? 0
        var high = values.max() ?? 0
        if high - low < Self.minimumSpan {
            let middle = (high + low) / 2
            low = middle - Self.minimumSpan / 2
            high = middle + Self.minimumSpan / 2
        }
        self.low = low
        self.high = high

        // Room for the marks inside the edges, and above the baseline.
        let top: CGFloat = 6
        let bottom = max(top, size.height - Poster.rule - 8)
        let last = today.ordinal
        let first = last - (Self.daysShown - 1)
        func x(_ day: CalendarDay) -> CGFloat {
            CGFloat(day.ordinal - first) / CGFloat(Self.daysShown - 1) * max(0, size.width - 4) + 2
        }
        func y(_ value: Double) -> CGFloat {
            bottom - CGFloat((value - low) / (high - low)) * (bottom - top)
        }

        let shown = days.filter { $0.date.ordinal >= first && $0.date.ordinal <= last }
        dots = shown.compactMap { day in day.value.map { CGPoint(x: x(day.date), y: y($0)) } }
        var segments: [[CGPoint]] = []
        var previous: Int?
        for day in shown {
            guard let average = day.average else {
                previous = nil
                continue
            }
            let point = CGPoint(x: x(day.date), y: y(average))
            if let previous, day.date.ordinal == previous + 1, !segments.isEmpty {
                segments[segments.count - 1].append(point)
            } else {
                segments.append([point])
            }
            previous = day.date.ordinal
        }
        self.segments = segments
    }
}

/// Label and figure rows under the line.
struct WeightRows: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(spacing: 0) {
            PosterRule()
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.0).posterLabel()
                    Spacer()
                    Text(row.1)
                        .font(.system(size: 15, weight: .heavy))
                        .monospacedDigit()
                }
                .padding(.horizontal, Poster.margin)
                .padding(.vertical, 9)
                PosterRule(thickness: 1.5)
            }
        }
    }
}

// MARK: Typing a weight

/// The weight entry: the number as it is typed, giant, and SAVE. For a
/// morning the prompt was missed, switched off, or tapped instead of
/// typed into.
public struct WeighInView: View {
    let unit: String
    let latest: WeightTrend.Reading?
    let today: CalendarDay
    let onSave: (String) async -> WeighInOutcome
    let onClose: () -> Void

    @State private var text = ""
    @State private var note: String?
    @State private var saving = false
    @FocusState private var typing: Bool

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Text("✕ Close").posterLabel().padding(.vertical, 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Weigh-in · \(today.posterLabel)").posterLabel()
            }
            .padding(.horizontal, Poster.margin)

            TextField("", text: $text, prompt: Text("0.0").foregroundStyle(Poster.ink.opacity(0.2)))
                .font(.system(size: 120, weight: .heavy))
                .tracking(-6)
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .focused($typing)
                #if os(iOS)
                    .keyboardType(.decimalPad)
                #endif
                .padding(.horizontal, Poster.margin - 4)
                .padding(.top, 24)
                .accessibilityLabel("Weight in \(unit)")
            Text(unit).posterHeading(34).padding(.horizontal, Poster.margin)
            Text(note ?? WeightText.entryLine(latest: latest, unit: unit, today: today))
                .posterLabel()
                .padding(.horizontal, Poster.margin)
                .padding(.top, 8)
            Spacer(minLength: 0)
            Button {
                Task { await save() }
            } label: {
                BreathBar(
                    small: "Kept on this phone until the server has it", big: saving ? "SAVING" : "SAVE",
                    mark: "→", onDark: false)
            }
            .buttonStyle(.plain)
            .disabled(saving || text.isEmpty)
            .opacity(text.isEmpty ? 0.55 : 1)
        }
        .foregroundStyle(Poster.ink)
        .background(Poster.paper.ignoresSafeArea())
        .onAppear { typing = true }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        switch await onSave(text) {
        case .sent, .saved:
            onClose()
        case .unreadable:
            note = WeightText.notAWeight(text, unit: unit)
        case .refused:
            note = "The server would not take that weight."
        }
    }
}

// MARK: Words

/// The words on the weight screens and prompts. Plain functions, so they
/// can be checked without a screen.
public enum WeightText {
    /// "82.4": one decimal, with a point whatever the phone's region.
    static func number(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// The giant figure on Progress and what it is.
    static func hero(_ weight: WeightTrend?) -> (figure: String, caption: String) {
        guard let weight else { return ("–", "No weigh-ins yet") }
        let unit = weight.unit.uppercased()
        if let average = weight.average {
            return (number(average), "7-day average · \(unit)")
        }
        if let latest = weight.latest {
            return (number(latest.value), "Latest · \(unit)")
        }
        return ("–", "No weigh-ins yet")
    }

    /// The line under the figure: how the average moved in a week.
    static func changeLine(_ weight: WeightTrend?) -> String {
        guard let weight else { return "Reply to the morning prompt to start" }
        let unit = weight.unit.uppercased()
        if let change = weight.change, let percent = weight.changePct {
            if abs(change) < 0.05 {
                return "Level with last week"
            }
            let arrow = change < 0 ? "▼" : "▲"
            return "\(arrow) \(number(abs(change))) \(unit) · \(signed(percent, decimals: 2))% on last week"
        }
        if weight.average != nil {
            return "The change shows after two weeks of weigh-ins"
        }
        if weight.latest == nil {
            return "Reply to the morning prompt to start"
        }
        return "Average after 3 weigh-ins in 7 days · \(weight.daysWeighed) so far"
    }

    /// "−0.84", "+0.30", with a real minus sign.
    static func signed(_ value: Double, decimals: Int) -> String {
        let text = String(format: "%.\(decimals)f", abs(value))
        if Double(text) == 0 { return text }
        return (value < 0 ? "−" : "+") + text
    }

    static func rows(_ weight: WeightTrend, today: CalendarDay) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let latest = weight.latest {
            let day = latest.date == today ? "TODAY" : latest.date.posterLabel
            rows.append(("Latest", "\(day) · \(number(latest.value)) \(weight.unit.uppercased())"))
        }
        rows.append(("Last 7 days", "\(weight.daysWeighed) OF 7 WEIGHED"))
        rows.append(("Morning prompt", weight.promptAt ?? "OFF"))
        return rows
    }

    /// "8 weeks ago" under the left end of the line, as a date.
    static func chartStart(today: CalendarDay) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: today.year, month: today.month, day: today.day, hour: 12)),
            let start = calendar.date(byAdding: .day, value: -(WeightChartLayout.daysShown - 1), to: date)
        else { return "" }
        let parts = calendar.dateComponents([.year, .month, .day], from: start)
        return CalendarDay(year: parts.year!, month: parts.month!, day: parts.day!).shortLabel
    }

    /// The range the chart spans, top to bottom: "82.0–85.6 KG".
    static func span(low: Double, high: Double, unit: String) -> String {
        "\(number(low))–\(number(high)) \(unit.uppercased())"
    }

    /// The black bar on Progress.
    static func bar(_ weight: WeightTrend?, today: CalendarDay) -> (small: String, big: String) {
        if let weight, let latest = weight.latest, latest.date == today {
            return ("TODAY \(number(latest.value)) \(weight.unit.uppercased()) · TAP TO CORRECT", "WEIGHED IN")
        }
        if let at = weight?.promptAt {
            return ("PROMPT AT \(at) · OR TYPE IT HERE", "WEIGH IN")
        }
        return ("TYPE TODAY'S WEIGHT", "WEIGH IN")
    }

    /// Under the number being typed.
    static func entryLine(latest: WeightTrend.Reading?, unit: String, today: CalendarDay) -> String {
        guard let latest else { return "First weigh-in" }
        if latest.date == today {
            return "Today so far \(number(latest.value)) \(unit.uppercased()) · this replaces it"
        }
        return "Last \(number(latest.value)) \(unit.uppercased()) · \(latest.date.posterLabel)"
    }

    static func notAWeight(_ typed: String, unit: String) -> String {
        "“\(typed.trimmingCharacters(in: .whitespacesAndNewlines))” is not a weight. Type it like \(example(unit))."
    }

    static func example(_ unit: String) -> String {
        unit == "lb" ? "181.4" : "82.4"
    }

    /// The strip on Home that leads to Progress.
    static func homeLine(_ weight: WeightTrend?) -> String {
        guard let weight else { return "Weight · not weighed yet" }
        let unit = weight.unit.uppercased()
        if let average = weight.average {
            return "Weight · 7-day \(number(average)) \(unit)"
        }
        if let latest = weight.latest {
            return "Weight · latest \(number(latest.value)) \(unit)"
        }
        return "Weight · not weighed yet"
    }

    static func unsent(_ count: Int) -> String {
        count == 1
            ? "1 weigh-in is saved on this phone. It is sent when the server can be reached."
            : "\(count) weigh-ins are saved on this phone. They are sent when the server can be reached."
    }

    static func spoken(_ weight: WeightTrend?) -> String {
        guard let weight else { return "Weight: no weigh-ins yet" }
        var parts: [String] = []
        if let average = weight.average {
            parts.append("Seven-day average \(number(average)) \(weight.unit)")
        } else if let latest = weight.latest {
            parts.append("Latest \(number(latest.value)) \(weight.unit)")
        } else {
            parts.append("No weigh-ins yet")
        }
        if let change = weight.change {
            parts.append("\(change < 0 ? "down" : "up") \(number(abs(change))) on last week")
        }
        return "Weight: " + parts.joined(separator: ", ")
    }

    /// The notification that asks again when a weight typed into the
    /// prompt was not taken. Nil when it was, or is waiting to be sent.
    public static func retry(after outcome: WeighInOutcome, typed: String, unit: String) -> (title: String, body: String)? {
        let shown = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        switch outcome {
        case .sent, .saved:
            return nil
        case .unreadable:
            return (
                "Weigh-in not saved",
                "“\(shown)” is not a weight. Hold this and type it again, like \(example(unit))."
            )
        case .refused:
            return ("Weigh-in not saved", "The server would not take “\(shown)”. Hold this and type it again.")
        }
    }
}
