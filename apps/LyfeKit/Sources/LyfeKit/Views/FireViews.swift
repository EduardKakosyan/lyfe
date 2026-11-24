import SwiftUI

/// FIRE: how far off financial independence is. First what is measured,
/// what came in and what was spent a month at a time; then what is worked
/// out from it and from what the owner assumes: the FI number, the years
/// to it, and what would get there with nothing more added. Last, how long
/// the money on hand would cover the spending.
struct FireSection: View {
    let fire: MoneyFire
    /// Opens what it assumes, to change it.
    let onPlan: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            flows
            PosterRule()
            wayThere
            PosterRule()
            runway
            PosterRule()
            Text(FireText.footnote)
                .posterLabel()
                .opacity(0.55)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Poster.margin)
                .padding(.vertical, 14)
        }
    }

    // MARK: What is measured

    @ViewBuilder private var flows: some View {
        StripRow(left: "In and spent, a month", right: FireText.basis(fire))
        PosterRule(thickness: 1.5)
        if fire.months.contains(where: { $0.incomeMinor != 0 || $0.spentMinor != 0 }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    PosterSquare(state: .outline, size: 10)
                    Text("In").posterLabel()
                    PosterSquare(state: .solid, size: 10).padding(.leading, 8)
                    Text("Spent").posterLabel()
                    Spacer()
                    Text("This month so far is dim").posterLabel().opacity(0.55)
                }
                FlowBars(months: fire.months).frame(height: 150)
            }
            .padding(.horizontal, Poster.margin)
            .padding(.top, 11)
            .padding(.bottom, 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(FireText.flowsSpoken(fire))
        }
        let rows = FireText.flowRows(fire)
        if rows.isEmpty {
            note("The averages are taken over months lyfe holds whole, and there is none yet: the first is the first month it holds from its first day.")
        } else {
            WeightRows(rows: rows)
        }
    }

    // MARK: What is worked out

    @ViewBuilder private var wayThere: some View {
        StripRow(left: "The way there", right: FireText.assumed(fire.plan))
        PosterRule(thickness: 1.5)
        if let number = fire.fiNumberMinor {
            VStack(alignment: .leading, spacing: 6) {
                PosterMeter(share: FireText.progress(fire), mark: FireText.coastMark(fire))
                HStack(alignment: .firstTextBaseline) {
                    Text("Set aside \(MoneyText.whole(fire.setAsideMinor))").posterLabel()
                    Spacer(minLength: 6)
                    Text("FI number \(MoneyText.whole(number))").posterLabel()
                }
                Text(FireText.progressLine(fire)).posterLabel()
                if let coast = fire.coast {
                    Text("Tick · \(FireText.coastLine(coast))").posterLabel().opacity(0.6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Poster.margin)
            .padding(.top, 12)
            .padding(.bottom, 12)
            if fire.ahead.count > 1, !fire.reached {
                PosterRule(thickness: 1.5)
                ahead(number)
            }
        } else {
            note(
                fire.counted == 0
                    ? "The FI number is a year's spending divided by what can be drawn a year. It needs a whole month of spending to start from."
                    : "The FI number is a year's spending divided by what can be drawn a year, and these months came to no spending.")
        }
        WeightRows(rows: FireText.numberRows(fire))
        Button(action: onPlan) {
            StripRow(left: "What this assumes", right: "Change →")
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the withdrawal rate, the growth, your birth year and the coast age")
    }

    private func ahead(_ number: Int) -> some View {
        let ends = FireText.aheadEnds(fire)
        let legend = FireText.aheadLegend(fire)
        return VStack(alignment: .leading, spacing: 6) {
            AheadChart(ahead: fire.ahead, numberMinor: number, reachedLabel: FireText.when(fire))
                .frame(height: 170)
            HStack {
                Text(ends.from).posterLabel()
                Spacer()
                Text(ends.to).posterLabel()
            }
            HStack(spacing: 6) {
                LineSample(heavy: true)
                Text(legend.kept).posterLabel()
                LineSample(heavy: false).padding(.leading, 8)
                Text(legend.coast).posterLabel()
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.top, 2)
        }
        .padding(.horizontal, Poster.margin)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(FireText.spoken(fire))
    }

    // MARK: Runway

    @ViewBuilder private var runway: some View {
        StripRow(left: "Runway", right: FireText.runway(fire))
        PosterRule(thickness: 1.5)
        if fire.runwayMonths != nil {
            VStack(alignment: .leading, spacing: 6) {
                PosterMeter(share: FireText.runwayShare(fire), mark: FireText.runwayMark / FireText.runwayFull)
                HStack {
                    Text("0").posterLabel()
                    Spacer()
                    Text("3 months").posterLabel()
                    Spacer()
                    Text("6 +").posterLabel()
                }
                Text(FireText.runwayLine(fire)).posterLabel().opacity(0.6)
            }
            .padding(.horizontal, Poster.margin)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Runway: \(FireText.runway(fire).lowercased()) of spending on hand")
        } else {
            note("How many months of spending the money on hand covers. It needs a whole month of spending to go by.")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .posterLabel()
            .opacity(0.55)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Poster.margin)
            .padding(.vertical, 14)
    }
}

/// A short piece of one of the lines ahead, for its legend.
struct LineSample: View {
    var heavy: Bool

    var body: some View {
        Canvas { context, size in
            var line = Path()
            line.move(to: CGPoint(x: 0, y: size.height / 2))
            line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(
                line, with: .foreground,
                style: heavy ? StrokeStyle(lineWidth: 4.5, dash: [8, 5]) : StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
        }
        .frame(width: 21, height: 10)
        .accessibilityHidden(true)
    }
}

// MARK: What it assumes

/// The plan: the four things the way to independence is worked out from,
/// each the owner's to set. Nothing here is measured, so nothing here is
/// right or wrong; it says what each does to the number.
public struct PlanView: View {
    let plan: MoneyPlan
    /// For holding a birth year to one that has begun.
    let thisYear: Int
    /// Answers with what went wrong, or nil.
    let onSave: (MoneyPlan) async -> String?
    let onClose: () -> Void

    @State private var draft: MoneyPlan
    @State private var born: String
    @State private var note: String?
    @State private var saving = false
    @FocusState private var typing: Bool

    init(plan: MoneyPlan, thisYear: Int, onSave: @escaping (MoneyPlan) async -> String?, onClose: @escaping () -> Void) {
        self.plan = plan
        self.thisYear = thisYear
        self.onSave = onSave
        self.onClose = onClose
        _draft = State(initialValue: plan)
        _born = State(initialValue: plan.birthYear.map(String.init) ?? "")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button(action: onClose) {
                        Text("✕ Close").posterLabel().padding(.vertical, 12).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("In today's money").posterLabel()
                }
                Text("What this assumes").posterHeading(30).padding(.bottom, 12)
            }
            .padding(.horizontal, Poster.margin)
            .foregroundStyle(Poster.paper)
            .background(Poster.ink.ignoresSafeArea(edges: .top))

            ScrollView {
                VStack(spacing: 0) {
                    if let note {
                        NoticeRow(text: note)
                        PosterRule(thickness: 1.5)
                    }
                    StepRow(
                        title: "Drawn a year", value: FireText.rate(draft.withdrawalBp),
                        detail: "The share of what is set aside you could spend each year for good. The FI number is a year's spending \(FireText.multiple(draft)). Lower is safer and further off: 4% held over thirty years, 3.5% and under over fifty and more.",
                        onLess: { step(\.withdrawalBp, -MoneyPlan.withdrawal.step, in: MoneyPlan.withdrawal.range) },
                        onMore: { step(\.withdrawalBp, MoneyPlan.withdrawal.step, in: MoneyPlan.withdrawal.range) })
                    PosterRule(thickness: 1.5)
                    StepRow(
                        title: "Growth a year", value: FireText.rate(draft.returnBp),
                        detail: "What the investments grow by above inflation, after their fees. Planners assume about 4% for shares held for decades; 5% is the long history, and 7% is hopeful.",
                        onLess: { step(\.returnBp, -MoneyPlan.growth.step, in: MoneyPlan.growth.range) },
                        onMore: { step(\.returnBp, MoneyPlan.growth.step, in: MoneyPlan.growth.range) })
                    PosterRule(thickness: 1.5)
                    StepRow(
                        title: "Coast by age", value: "\(draft.coastAge)",
                        detail: "The coast number is what would grow to the FI number by this age with nothing more added.",
                        onLess: { step(\.coastAge, -MoneyPlan.coast.step, in: MoneyPlan.coast.range) },
                        onMore: { step(\.coastAge, MoneyPlan.coast.step, in: MoneyPlan.coast.range) })
                    PosterRule(thickness: 1.5)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Born in").posterHeading(18)
                            Spacer(minLength: 12)
                            TextField("", text: $born, prompt: Text("YEAR").foregroundStyle(Poster.ink.opacity(0.25)))
                                .font(.system(size: 30, weight: .heavy))
                                .monospacedDigit()
                                .multilineTextAlignment(.trailing)
                                .focused($typing)
                                #if os(iOS)
                                    .keyboardType(.numberPad)
                                #endif
                                .frame(maxWidth: 140)
                                .accessibilityLabel("Birth year")
                                // A year is four digits, and nothing else is one.
                                .onChange(of: born) { _, typed in
                                    let year = String(typed.filter(\.isNumber).prefix(4))
                                    if year != typed { born = year }
                                }
                        }
                        Text("Only to say an age beside a year, and to know how long there is to coast. Leave it empty and lyfe says years alone.")
                            .posterLabel().opacity(0.6)
                    }
                    .padding(.horizontal, Poster.margin)
                    .padding(.vertical, 12)
                    PosterRule(thickness: 1.5)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            Button {
                Task { await save() }
            } label: {
                BreathBar(
                    small: FireText.assumed(draft), big: saving ? "SAVING" : "SAVE", mark: "→", onDark: false)
            }
            .buttonStyle(.plain)
            .disabled(saving)
        }
        .foregroundStyle(Poster.ink)
        .background(Poster.paper.ignoresSafeArea())
    }

    private func step(_ rate: WritableKeyPath<MoneyPlan, Int>, _ by: Int, in range: ClosedRange<Int>) {
        draft[keyPath: rate] = min(range.upperBound, max(range.lowerBound, draft[keyPath: rate] + by))
    }

    private func save() async {
        guard let year = FireText.birthYear(born, thisYear: thisYear) else {
            note = "“\(born.trimmingCharacters(in: .whitespacesAndNewlines))” is not a birth year. Type it like 1998, or leave it empty."
            return
        }
        typing = false
        saving = true
        defer { saving = false }
        draft.birthYear = year
        note = await onSave(draft)
    }
}

/// One thing assumed: its name, its value between a less and a more, and
/// what it does.
struct StepRow: View {
    var title: String
    var value: String
    var detail: String
    let onLess: () -> Void
    let onMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Text(title).posterHeading(18).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                key("−", "Less", onLess)
                Text(value)
                    .font(.system(size: 30, weight: .heavy))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(minWidth: 92)
                    .contentTransition(.numericText())
                key("+", "More", onMore)
            }
            Text(detail).posterLabel().opacity(0.6)
        }
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    private func key(_ sign: String, _ spoken: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(sign)
                .font(.system(size: 26, weight: .heavy))
                .frame(width: 44, height: 44)
                .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 2.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(spoken) \(title.lowercased())")
    }
}
