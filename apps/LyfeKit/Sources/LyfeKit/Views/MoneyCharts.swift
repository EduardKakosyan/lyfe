import SwiftUI

// The pictures on Money. They are drawn the way the rest of lyfe is: ink
// on paper, hard edges, and the three marks. Solid is what is there;
// stripes are what is not to be counted on (owed, or grown and not yet
// sold); an outline is what is still open, as what came in is until it is
// spent. A broken line is what is only worked out and has not happened.
// Where each mark goes is plain arithmetic kept apart from the drawing, so
// it can be checked without a screen.

/// A flat bar in one of the three marks, as wide as its share of the row.
struct PosterBar: View {
    /// 0 to 1.
    var share: Double
    var mark: MarkState = .solid
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { space in
            // Wide enough to see what it is: stripes take more than a sliver.
            let width = share > 0 ? max(mark == .solid ? 3 : 12, space.size.width * min(1, share)) : 0
            ZStack {
                switch mark {
                case .solid: Rectangle().fill(.foreground)
                case .striped: Stripes(spacing: 2).clipped()
                case .outline: EmptyView()
                }
                if mark != .solid {
                    Rectangle().strokeBorder(.foreground, lineWidth: 2)
                }
            }
            .frame(width: width, height: height)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A name, a figure and a bar against the largest of its kind: one part of
/// what everything comes to, or one holding.
struct BarRow: View {
    var title: String
    /// Small capitals beside the title.
    var detail = ""
    /// A second line under it.
    var line = ""
    var figure: String
    /// 0 to 1.
    var share: Double
    var mark: MarkState = .solid

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 15, weight: .heavy))
                    .tracking(-0.3)
                    .textCase(.uppercase)
                    .lineLimit(1)
                Text(detail).posterLabel().opacity(0.6).lineLimit(1)
                Spacer(minLength: 8)
                Text(figure)
                    .font(.system(size: 15, weight: .heavy))
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            if !line.isEmpty {
                Text(line).posterLabel().opacity(0.6).lineLimit(2).multilineTextAlignment(.leading)
            }
            PosterBar(share: share, mark: mark)
        }
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, figure, detail, line].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

/// How far along something is: an outline as long as the whole, filled as
/// far as it has got, with a tick where a mark on the way sits.
struct PosterMeter: View {
    /// 0 to 1.
    var share: Double
    /// 0 to 1, or nil for no tick.
    var mark: Double?
    var height: CGFloat = 24

    var body: some View {
        GeometryReader { space in
            let width = space.size.width
            ZStack(alignment: .leading) {
                Rectangle().strokeBorder(.foreground, lineWidth: 2.5)
                Rectangle().fill(.foreground).frame(width: MeterLayout.filled(share, of: width))
            }
            .frame(height: height)
            // Laid over the bar, not in it, so it can be longer than the
            // bar is tall and show against the fill as well.
            .overlay(alignment: .leading) {
                if let mark {
                    Rectangle().fill(.foreground)
                        .frame(width: 2.5, height: height + 12)
                        .offset(x: MeterLayout.tick(mark, of: width))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: height + 12)
        .accessibilityHidden(true)
    }
}

enum MeterLayout {
    /// The filled width: something to see as soon as there is anything.
    static func filled(_ share: Double, of width: CGFloat) -> CGFloat {
        guard share > 0 else { return 0 }
        return max(4, width * CGFloat(min(1, share)))
    }

    /// Where a tick starts, kept inside the bar.
    static func tick(_ mark: Double, of width: CGFloat) -> CGFloat {
        min(max(0, width * CGFloat(min(1, max(0, mark))) - 1.25), max(0, width - 2.5))
    }
}

// MARK: Net worth over time

/// What everything came to, a day at a time: one heavy line, and a square
/// on today.
struct WorthChart: View {
    let points: [MoneyWorth.Point]

    var body: some View {
        Canvas { context, size in
            let layout = WorthChartLayout(points: points, size: size)
            context.fill(
                Path(CGRect(x: 0, y: size.height - Poster.rule, width: size.width, height: Poster.rule)),
                with: .foreground)
            var line = Path()
            line.addLines(layout.line)
            // A sharp turn is cut square: a mitre on a one-day dip would
            // carry the line well past the day's own point.
            context.stroke(
                line, with: .foreground,
                style: StrokeStyle(lineWidth: 4.5, lineCap: .square, lineJoin: .miter, miterLimit: 2))
            if let today = layout.line.last {
                context.fill(Path(CGRect(x: today.x - 5, y: today.y - 5, width: 10, height: 10)), with: .foreground)
            }
        }
        .accessibilityHidden(true)
    }
}

struct WorthChartLayout {
    /// The amounts at the bottom and the top of the chart, in minor units.
    var low: Int
    var high: Int
    var line: [CGPoint]

    /// The chart never spans less than this share of what it shows, so a
    /// quiet month is drawn flat instead of every cent looking like a cliff.
    static let leastSpan = 0.02

    init(points: [MoneyWorth.Point], size: CGSize) {
        var low = points.map(\.worthMinor).min() ?? 0
        var high = points.map(\.worthMinor).max() ?? 0
        let least = max(10_000, Int(Double(max(abs(low), abs(high))) * Self.leastSpan))
        if high - low < least {
            let middle = (high + low) / 2
            low = middle - least / 2
            high = low + least
        }
        self.low = low
        self.high = high

        // Room for the square on today inside the edges, and above the baseline.
        let top: CGFloat = 8
        let bottom = max(top, size.height - Poster.rule - 8)
        let first = points.first?.day.ordinal ?? 0
        let days = max(1, (points.last?.day.ordinal ?? 0) - first)
        line = points.map { point in
            CGPoint(
                x: CGFloat(point.day.ordinal - first) / CGFloat(days) * max(0, size.width - 12) + 6,
                y: bottom - CGFloat(point.worthMinor - low) / CGFloat(high - low) * (bottom - top))
        }
    }
}

// MARK: In and spent, a month at a time

/// Two bars a month, side by side: what came in as an outline, what was
/// spent solid. The gap between their tops is what was kept. The month
/// still running is drawn dim: no average counts it.
struct FlowBars: View {
    let months: [MoneyFire.Month]

    var body: some View {
        VStack(spacing: 4) {
            Canvas { context, size in
                let layout = FlowBarsLayout(months: months, size: size)
                context.fill(
                    Path(CGRect(x: 0, y: size.height - Poster.rule, width: size.width, height: Poster.rule)),
                    with: .foreground)
                for pair in layout.pairs {
                    context.opacity = pair.whole ? 1 : 0.4
                    if pair.income.height > 5 {
                        // Stroked inside its edge, so both bars are as wide.
                        context.stroke(Path(pair.income.insetBy(dx: 1.25, dy: 1.25)), with: .foreground, lineWidth: 2.5)
                    } else if pair.income.height > 0 {
                        // Too short for an outline to have an inside: a sliver, so it is not nothing.
                        let sliver = max(2.5, pair.income.height)
                        context.fill(
                            Path(CGRect(x: pair.income.minX, y: pair.income.maxY - sliver, width: pair.income.width, height: sliver)),
                            with: .foreground)
                    }
                    context.fill(Path(pair.spent), with: .foreground)
                }
            }
            HStack(spacing: 0) {
                ForEach(months) { month in
                    Text(FireText.monthLabel(month.month, of: months.count))
                        .posterLabel()
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                        .opacity(month.whole ? 1 : 0.4)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct FlowBarsLayout {
    struct Pair: Equatable {
        var income: CGRect
        var spent: CGRect
        var whole: Bool
    }

    var pairs: [Pair]

    /// The widest a bar gets, and the surface left between the two of a month.
    static let widest: CGFloat = 22
    static let gap: CGFloat = 2

    init(months: [MoneyFire.Month], size: CGSize) {
        let most = max(months.flatMap { [$0.incomeMinor, $0.spentMinor] }.max() ?? 0, 1)
        let slot = size.width / CGFloat(max(months.count, 1))
        let bar = max(2, min(Self.widest, (slot - Self.gap) * 0.36))
        let bottom = size.height - Poster.rule
        let tallest = max(0, bottom - 4)
        func rect(_ x: CGFloat, _ minor: Int) -> CGRect {
            // Money back can outrun a month's spending: that draws as nothing.
            let height = (CGFloat(max(0, minor)) / CGFloat(most) * tallest).rounded()
            return CGRect(x: x, y: bottom - height, width: bar, height: height)
        }
        pairs = months.enumerated().map { index, month in
            let left = slot * CGFloat(index) + (slot - bar * 2 - Self.gap) / 2
            return Pair(
                income: rect(left, month.incomeMinor), spent: rect(left + bar + Self.gap, month.spentMinor),
                whole: month.whole)
        }
    }
}

// MARK: The years ahead

/// What is set aside in the years to come, against the FI number: a heavy
/// broken line with a year's keeping added each year, a thin one with
/// nothing added, and the number as a rule across. Broken, because none of
/// it has happened. Where the heavy line reaches the number it stops, on a
/// square.
struct AheadChart: View {
    let ahead: [MoneyFire.Ahead]
    let numberMinor: Int
    /// What to say beside the square: the year it is reached.
    var reachedLabel = ""

    var body: some View {
        GeometryReader { space in
            let layout = AheadChartLayout(ahead: ahead, numberMinor: numberMinor, size: space.size)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    context.fill(
                        Path(CGRect(x: 0, y: size.height - Poster.rule, width: size.width, height: Poster.rule)),
                        with: .foreground)
                    context.fill(Path(CGRect(x: 0, y: layout.numberY - 0.75, width: size.width, height: 1.5)), with: .foreground)
                    var coast = Path()
                    coast.addLines(layout.coast)
                    context.stroke(coast, with: .foreground, style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
                    var kept = Path()
                    kept.addLines(layout.kept)
                    context.stroke(kept, with: .foreground, style: StrokeStyle(lineWidth: 4.5, lineJoin: .miter, dash: [8, 5]))
                    if let reached = layout.reached {
                        context.fill(
                            Path(CGRect(x: reached.x - 0.75, y: reached.y, width: 1.5, height: size.height - reached.y)),
                            with: .foreground)
                        context.fill(Path(CGRect(x: reached.x - 6, y: reached.y - 6, width: 12, height: 12)), with: .foreground)
                    }
                }
                Text("FI number").posterLabel().offset(x: 0, y: layout.numberY - 17)
                if let reached = layout.reached, !reachedLabel.isEmpty {
                    // Over the rule, where no line is drawn, and clear of
                    // the rule's own label at its left end.
                    let width = AheadChartLayout.labelWidth
                    Text(reachedLabel).posterLabel().fixedSize()
                        .frame(width: width, alignment: .trailing)
                        .offset(
                            x: AheadChartLayout.labelLeft(reachedAt: reached.x, in: space.size.width),
                            y: layout.numberY - 17)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct AheadChartLayout {
    /// The line with a year's keeping added, up to where it reaches the number.
    var kept: [CGPoint]
    /// The line with nothing added, likewise.
    var coast: [CGPoint]
    /// How far down the FI number's rule is.
    var numberY: CGFloat
    /// Where the kept line reaches the number, when it does.
    var reached: CGPoint?

    /// The chart is this much taller than the number, to leave room for
    /// its label above the rule.
    static let headroom = 1.18

    /// The room the year it is reached is set in, ending just short of
    /// the square it belongs to.
    static let labelWidth: CGFloat = 120

    /// Where that room starts: it ends before the square, and never
    /// starts on top of the rule's own label at the left.
    static func labelLeft(reachedAt x: CGFloat, in width: CGFloat) -> CGFloat {
        let wanted = x - 10 - labelWidth
        return min(max(wanted, 78), max(78, width - labelWidth))
    }

    init(ahead: [MoneyFire.Ahead], numberMinor: Int, size: CGSize) {
        let number = Double(max(numberMinor, 1))
        let top: CGFloat = 4
        let bottom = max(top, size.height - Poster.rule - 2)
        let last = max(1, ahead.count - 1)
        func x(_ index: Double) -> CGFloat {
            CGFloat(index / Double(last)) * max(0, size.width - 12) + 6
        }
        func y(_ minor: Double) -> CGFloat {
            bottom - CGFloat(min(minor, number) / (number * Self.headroom)) * (bottom - top)
        }
        numberY = y(number)

        // A line stops where it reaches the number: past it there is
        // nothing more to wait for. It stops where it runs out, too.
        func clipped(_ values: [Double]) -> (line: [CGPoint], reached: CGPoint?) {
            var line: [CGPoint] = []
            for (index, value) in values.enumerated() {
                if value <= 0, index > 0 {
                    let before = values[index - 1]
                    if before > 0 {
                        line.append(CGPoint(x: x(Double(index - 1) + before / (before - value)), y: y(0)))
                    }
                    return (line, nil)
                }
                if value >= number {
                    guard index > 0, values[index - 1] < value else {
                        let point = CGPoint(x: x(Double(index)), y: y(number))
                        return (line + [point], point)
                    }
                    let before = values[index - 1]
                    let part = (number - before) / (value - before)
                    let point = CGPoint(x: x(Double(index - 1) + part), y: y(number))
                    return (line + [point], point)
                }
                line.append(CGPoint(x: x(Double(index)), y: y(value)))
            }
            return (line, nil)
        }
        let kept = clipped(ahead.map { Double($0.keptMinor) })
        self.kept = kept.line
        reached = kept.reached
        coast = clipped(ahead.map { Double($0.coastMinor) }).line
    }
}
