import SwiftUI

/// Food: what is logged today against the calorie and protein targets,
/// measured apart from estimated, each meal of the day as logged or still
/// unknown, and the saved meals, each logged with one tap. The black bar
/// logs the next open meal; anything else is a photo or a barcode.
public struct FoodScreen: View {
    let food: FoodDay
    /// Meals tapped here that the backend does not have yet.
    var unsent: [MealTap] = []
    /// Photo and barcode meals logged here that the backend does not have yet.
    var captures: [FoodCapture] = []
    var problem: String?
    let onBack: () -> Void
    /// Logs this many portions of a saved meal.
    let onLog: (SavedMeal, Double) async -> Void
    /// Takes a logged meal back; answers with what went wrong, if anything.
    let onTakeBack: (UUID) async -> String?
    /// Opens the editor on a saved meal, or on a new one.
    let onEditMeal: (SavedMeal?) -> Void
    let onTargets: () -> Void
    var onPhoto: () -> Void = {}
    var onScan: () -> Void = {}
    /// Opens a photo meal's estimate.
    var onEstimate: (UUID) -> Void = { _ in }
    /// Opens the label entry for a code lyfe does not know.
    var onLabel: (String) -> Void = { _ in }

    @State private var takingBack: FoodText.Row?
    @State private var note: String?
    /// True for a moment after a tap, so a second one cannot land on
    /// whatever the bar has turned into.
    @State private var busy = false

    public var body: some View {
        VStack(spacing: 0) {
            FuelHeader(food: food, onBack: onBack, onTargets: onTargets)
            PosterRule()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(notices, id: \.self) { notice in
                        NoticeRow(text: notice)
                        PosterRule(thickness: 1.5)
                    }
                    ForEach(FoodText.rows(food, unsent: unsent, captures: captures)) { row in
                        switch row.tap {
                        case .none:
                            FoodRow(row: row)
                        case .takeBack:
                            Button {
                                takingBack = row
                            } label: {
                                FoodRow(row: row)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Takes it off today")
                        case .estimate(let id):
                            Button {
                                onEstimate(id)
                            } label: {
                                FoodRow(row: row)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Shows the estimate, to correct it")
                        case .label(let code):
                            Button {
                                onLabel(code)
                            } label: {
                                FoodRow(row: row)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Type the figures from its label")
                        }
                        PosterRule(thickness: 1.5)
                    }
                    savedMeals
                    PosterRule()
                    Button(action: onTargets) {
                        StripRow(left: FoodText.targetsLine(food.target), right: food.target == nil ? "Set →" : "Change →")
                    }
                    .buttonStyle(.plain)
                    PosterRule(thickness: 1.5)
                    StreakDays(streak: food.streak)
                }
            }
            captureButtons
            bar
        }
        .foregroundStyle(Poster.ink)
        .background(Poster.paper.ignoresSafeArea())
        .confirmationDialog(
            takingBack.map { "Take \($0.title) off today?" } ?? "", isPresented: takingBackShown, titleVisibility: .visible
        ) {
            Button("Take it off", role: .destructive) {
                guard let id = takingBack?.entry else { return }
                Task { note = await onTakeBack(id) }
            }
        }
    }

    private var takingBackShown: Binding<Bool> {
        Binding(get: { takingBack != nil }, set: { if !$0 { takingBack = nil } })
    }

    private var notices: [String] {
        var notices: [String] = []
        if let note { notices.append(note) }
        if let problem {
            notices.append(problem)
        } else if !unsent.isEmpty || !captures.isEmpty {
            notices.append(FoodText.unsent(unsent.count + captures.count))
        }
        if let unknown = FoodText.unknownNotice(food) {
            notices.append(unknown)
        }
        return notices
    }

    /// Anything that is not a saved meal: a barcode, or a photo and a line.
    private var captureButtons: some View {
        HStack(spacing: 0) {
            Button(action: onScan) {
                CaptureButton(mark: "▥", title: "Scan", detail: "Barcode")
            }
            .accessibilityLabel("Scan a barcode")
            Rectangle().fill(Poster.ink).frame(width: Poster.rule)
            Button(action: onPhoto) {
                CaptureButton(mark: "◉", title: "Photo", detail: "And one line")
            }
            .accessibilityLabel("Log a meal with a photo")
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .top) { PosterRule() }
    }

    /// The saved meals: a tap logs one portion, holding offers others.
    private var savedMeals: some View {
        VStack(spacing: 0) {
            PosterRule(thickness: 1.5)
            StripRow(
                left: food.meals.isEmpty ? "No saved meals yet" : "Saved meals",
                right: food.meals.isEmpty ? "" : "Tap logs one · hold for others")
            PosterRule(thickness: 1.5)
            ForEach(food.meals) { meal in
                Button {
                    log(meal, 1)
                } label: {
                    FoodRow(row: FoodText.mealRow(meal), plus: true)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    ForEach(FoodText.otherPortions, id: \.self) { servings in
                        Button(FoodText.portions(servings).capitalized) { log(meal, servings) }
                    }
                    Button("Change the recipe") { onEditMeal(meal) }
                }
                .accessibilityHint("Logs one portion")
                PosterRule(thickness: 1.5)
            }
            Button {
                onEditMeal(nil)
            } label: {
                StripRow(left: "New saved meal", right: "Weigh it once →")
            }
            .buttonStyle(.plain)
        }
    }

    private var bar: some View {
        let bar = FoodText.bar(food, unsent: unsent, captures: captures)
        return Button {
            switch bar.action {
            case .log(let meal): log(meal, 1)
            case .newMeal: onEditMeal(nil)
            case .setTargets: onTargets()
            case .none: break
            }
        } label: {
            BreathBar(small: bar.small, big: bar.big, mark: bar.mark, onDark: false)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(bar.action != .none)
    }

    private func log(_ meal: SavedMeal, _ servings: Double) {
        guard !busy else { return }
        busy = true
        note = nil
        Task {
            await onLog(meal, servings)
            try? await Task.sleep(for: .milliseconds(700))
            busy = false
        }
    }
}

/// The top of the Food screen, in yellow: today's calories as the giant
/// figure, and calories and protein as bars filling toward their targets.
struct FuelHeader: View {
    let food: FoodDay
    let onBack: () -> Void
    let onTargets: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Text("← Home").posterLabel().padding(.vertical, 12).contentShape(Rectangle())
                }
                Spacer()
                Button(action: onTargets) {
                    Text(FoodText.targetLabel(food)).posterLabel().padding(.vertical, 12).contentShape(Rectangle())
                }
                .accessibilityHint("Opens the targets")
            }
            .buttonStyle(.plain)
            HStack(alignment: .lastTextBaseline) {
                Text("Fuel").posterHeading()
                Spacer()
                Text(FoodText.leftLine(food)).posterLabel()
            }
            Text(Poster.tight(FoodText.kcal(food.kcal), by: -5))
                .font(.system(size: 92, weight: .heavy))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .padding(.top, -6)
                .padding(.bottom, -4)
            if let target = food.target {
                HStack {
                    Text(FoodText.estimateLine(food) ?? "").posterLabel()
                    Spacer(minLength: 6)
                    Text(FoodText.openLine(food)).posterLabel()
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.bottom, 6)
                let kcal = FoodText.split(food, kcal: true)
                let protein = FoodText.split(food, kcal: false)
                TargetBar(
                    fraction: FoodText.fraction(kcal.measured, of: Double(target.kcal)),
                    estimated: FoodText.fraction(kcal.estimated, of: Double(target.kcal)), height: 22)
                HStack {
                    Text("Protein").posterLabel()
                    Spacer()
                    Text(FoodText.proteinLine(food)).posterLabel()
                }
                .padding(.top, 9)
                TargetBar(
                    fraction: FoodText.fraction(protein.measured, of: Double(target.proteinG)),
                    estimated: FoodText.fraction(protein.estimated, of: Double(target.proteinG)), height: 14
                )
                .padding(.top, 5)
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        PosterSquare(state: .solid, size: 11)
                        Text("Measured").posterLabel()
                    }
                    HStack(spacing: 4) {
                        PosterSquare(state: .striped, size: 11)
                        Text("Estimated").posterLabel()
                    }
                    HStack(spacing: 4) {
                        PosterSquare(state: .outline, size: 11)
                        Text("Left").posterLabel()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
            } else {
                if let estimate = FoodText.estimateLine(food) {
                    Text(estimate).posterLabel().padding(.bottom, 6)
                }
                HStack {
                    Text("Protein").posterLabel()
                    Spacer()
                    Text(FoodText.proteinLine(food)).posterLabel()
                }
                Button(action: onTargets) {
                    Text("No targets yet · set them to see the day against them →")
                        .posterLabel()
                        .multilineTextAlignment(.leading)
                        .padding(.top, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Poster.margin)
        .padding(.bottom, 12)
        .background(Poster.yellow.ignoresSafeArea(edges: .top))
        .animation(.snappy, value: food.kcal)
        .accessibilityElement(children: .contain)
    }
}

/// A bar that fills with ink toward a target: solid is what was
/// measured, stripes what was estimated, the empty part is what is left.
struct TargetBar: View {
    /// From 0 to 1.
    var fraction: Double
    /// From 0 to 1, after the solid part; the two never pass the end.
    var estimated: Double = 0
    var height: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let solid = geometry.size.width * fraction
            let striped = geometry.size.width * min(estimated, max(0, 1 - fraction))
            HStack(spacing: 0) {
                Rectangle().fill(Poster.ink).frame(width: solid)
                if striped > 0 {
                    Stripes(spacing: 4)
                        .foregroundStyle(Poster.ink)
                        .frame(width: striped)
                        .clipped()
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Poster.ink).frame(width: Poster.rule)
                        }
                }
            }
        }
        .frame(height: height)
        .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: Poster.rule))
        .accessibilityHidden(true)
    }
}

/// One line of the day or of the saved meals: a mark, a name with a line
/// under it, and its calories.
struct FoodRow: View {
    let row: FoodText.Row
    /// A saved meal waiting to be tapped, marked with a plus.
    var plus = false

    var body: some View {
        HStack(spacing: 10) {
            PosterSquare(state: row.mark, size: 26)
                .overlay {
                    if plus {
                        Text("+").font(.system(size: 19, weight: .heavy)).offset(y: -1)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 15, weight: .heavy))
                    .tracking(-0.3)
                    .textCase(.uppercase)
                    .lineLimit(1)
                // A long line wraps rather than losing its end.
                Text(row.label).posterLabel().lineLimit(2).multilineTextAlignment(.leading)
            }
            Spacer(minLength: 8)
            Text(row.value)
                .font(.system(size: 15, weight: .heavy))
                .monospacedDigit()
        }
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 9)
        .opacity(row.dim ? 0.45 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spoken)
    }
}

/// One of the two ways to log a meal that is not saved.
struct CaptureButton: View {
    var mark: String
    var title: String
    var detail: String

    var body: some View {
        HStack(spacing: 10) {
            Text(mark).font(.system(size: 22, weight: .heavy))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).posterHeading(20)
                Text(detail).posterLabel().opacity(0.6)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Poster.paper)
        .contentShape(Rectangle())
    }
}

/// A line of small capitals with something at each end.
struct StripRow: View {
    var left: String
    var right: String

    var body: some View {
        HStack {
            Text(left).posterLabel()
            Spacer(minLength: 8)
            Text(right).posterLabel()
        }
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

/// The last seven days of logging as squares, today last.
struct StreakDays: View {
    let streak: FoodDay.DayStreak

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(streak.lastDays) { day in
                    PosterSquare(state: FoodText.mark(for: day.state), size: 12)
                }
            }
            Text("Last 7 days").posterLabel()
            Spacer(minLength: 0)
            if streak.previousBest > 0 {
                Text("Best \(streak.previousBest)").posterLabel()
            }
        }
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(FoodText.daysSpoken(streak))
    }
}

// MARK: Words

/// The words on the food screens. Plain functions, so they can be checked
/// without a screen.
public enum FoodText {
    /// "1,640": thousands marked with a comma whatever the phone's region.
    static func kcal(_ value: Int) -> String {
        let digits = Array(String(abs(value)))
        var text = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 {
                text.append(",")
            }
            text.append(digit)
        }
        return (value < 0 ? "−" : "") + text
    }

    /// Whole grams: "43".
    static func grams(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    /// A figure as it was typed: "80", "13.2".
    static func plain(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static func slotName(_ slot: MealSlot) -> String {
        switch slot {
        case .breakfast: "BREAKFAST"
        case .lunch: "LUNCH"
        case .dinner: "DINNER"
        case .snack: "SNACK"
        }
    }

    /// "½ PORTION", "1½ PORTIONS", "2 PORTIONS".
    static func portions(_ servings: Double) -> String {
        let whole = Int(servings.rounded(.down))
        let half = abs(servings - Double(whole) - 0.5) < 0.001
        let count = half ? (whole == 0 ? "½" : "\(whole)½") : plain(servings)
        return "\(count) \(servings <= 1 ? "PORTION" : "PORTIONS")"
    }

    /// The portions offered when a saved meal is held instead of tapped.
    static let otherPortions: [Double] = [0.5, 1.5, 2]

    // MARK: The header

    /// "TUE · TARGET 2,500"
    static func targetLabel(_ food: FoodDay) -> String {
        guard let target = food.target else { return "\(food.day.weekdayLabel) · NO TARGET YET" }
        return "\(food.day.weekdayLabel) · TARGET \(kcal(target.kcal))"
    }

    /// Beside the heading: how far today is from the calorie target.
    static func leftLine(_ food: FoodDay) -> String {
        guard let left = food.kcalLeft else { return "KCAL LOGGED TODAY" }
        if left > 0 { return "\(kcal(left)) KCAL LEFT" }
        if left < 0 { return "\(kcal(-left)) KCAL OVER" }
        return "KCAL · ON TARGET"
    }

    /// "92 OF 170 G", with how far over once it is.
    static func proteinLine(_ food: FoodDay) -> String {
        guard let target = food.target else { return "\(grams(food.proteinG)) G" }
        return "\(grams(food.proteinG)) OF \(target.proteinG) G"
    }

    /// How full a bar is, from 0 to 1.
    static func fraction(_ actual: Double, of target: Double) -> Double {
        target > 0 ? min(1, max(0, actual / target)) : 0
    }

    /// Under the bars: the main meals still unknown, so the figure is not
    /// read as the whole day.
    static func openLine(_ food: FoodDay) -> String {
        let open = food.openSlots.map(slotName)
        switch open.count {
        case 0: return "ALL MEALS LOGGED"
        case 3: return "NOTHING LOGGED YET"
        default: return "\(open.joined(separator: ", ")) OPEN"
        }
    }

    // MARK: The day's rows

    struct Row: Identifiable, Equatable {
        var id: String
        /// The logged meal this row is; nil for a meal that is still open.
        var entry: UUID?
        var mark: MarkState
        var title: String
        var label: String
        var value: String
        var dim = false
        /// What tapping it does.
        var tap: RowTap = .none

        var spoken: String {
            let figure =
                switch value {
                case "?": "unknown"
                case "…": "being estimated"
                default: "\(value) kilocalories"
                }
            return "\(title), \(label), \(figure)"
        }
    }

    enum RowTap: Equatable {
        case none
        /// Asks to take the meal off today.
        case takeBack
        /// Opens a photo meal's estimate.
        case estimate(UUID)
        /// Opens the label entry for this code.
        case label(String)
    }

    /// The day by slot: what was logged, what was logged here and is still
    /// to be sent, and a question mark for each meal with nothing. A meal
    /// that is not logged is unknown, never zero.
    static func rows(_ food: FoodDay, unsent: [MealTap], captures: [FoodCapture] = []) -> [Row] {
        MealSlot.allCases.flatMap { slot -> [Row] in
            let logged = food.entries.filter { $0.slot == slot }.map(entryRow)
            let waiting = unsent.filter { $0.slot == slot }.map { tap in
                Row(
                    id: "tap-\(tap.id)", entry: tap.id, mark: .solid, title: tap.name,
                    label: "ON THIS PHONE · NOT COUNTED YET", value: kcal(tap.kcal), dim: true, tap: .takeBack)
            }
            let captured = captures.filter { $0.slot == slot }.map(captureRow)
            let waitingAll = waiting + captured
            if logged.isEmpty, waitingAll.isEmpty {
                return [
                    Row(
                        id: "open-\(slot.rawValue)", entry: nil, mark: .outline,
                        title: slot == .snack ? "SNACKS" : slotName(slot), label: "NOTHING LOGGED", value: "?", dim: true)
                ]
            }
            return logged + waitingAll
        }
    }

    /// A logged meal as its row: solid when measured, striped when
    /// estimated, outlined with a question mark while its figures are not
    /// known.
    static func entryRow(_ entry: FoodDay.Entry) -> Row {
        let id = "entry-\(entry.id)"
        switch (entry.from, entry.figures ?? .known) {
        case (.photo, .estimating):
            return Row(
                id: id, entry: entry.id, mark: .striped, title: entry.name,
                label: entry.photo?.problem == nil ? "PHOTO · ESTIMATING ON THE SPARK" : "PHOTO · WAITING FOR THE SPARK",
                value: "…", tap: .estimate(entry.id))
        case (.photo, _) where !entry.isKnown:
            return Row(
                id: id, entry: entry.id, mark: .outline, title: entry.name, label: "PHOTO · NO ESTIMATE · TAP TO TYPE IT",
                value: "?", tap: .estimate(entry.id))
        case (.photo, _):
            return Row(
                id: id, entry: entry.id, mark: .striped, title: entry.name, label: photoLabel(entry),
                value: kcal(entry.kcal), tap: .estimate(entry.id))
        case (.barcode, _) where !entry.isKnown:
            return Row(
                id: id, entry: entry.id, mark: .outline, title: entry.name,
                label: "NOT IN THE FOOD DATABASE · TAP TO TYPE ITS LABEL", value: "?",
                tap: .label(entry.barcode?.code ?? ""))
        case (.barcode, _):
            return Row(
                id: id, entry: entry.id, mark: .solid, title: entry.name,
                label: "LABEL · \(grams(entry.barcode?.grams ?? 0)) G · \(grams(entry.proteinG)) G PROTEIN",
                value: kcal(entry.kcal), tap: .takeBack)
        case (.saved, _):
            return Row(
                id: id, entry: entry.id, mark: .solid, title: entry.name,
                label: entryLabel(servings: entry.servings, proteinG: entry.proteinG), value: kcal(entry.kcal),
                tap: .takeBack)
        }
    }

    /// "PHOTO · 380–780 · 33 G", or "TYPED" once the owner typed it.
    static func photoLabel(_ entry: FoodDay.Entry) -> String {
        if entry.photo?.typed == true {
            return "PHOTO · TYPED · \(grams(entry.proteinG)) G PROTEIN"
        }
        guard let low = entry.kcalLow, let high = entry.kcalHigh else {
            return "PHOTO · \(grams(entry.proteinG)) G PROTEIN"
        }
        return "PHOTO · \(kcal(low))–\(kcal(high)) · \(grams(entry.proteinG)) G"
    }

    /// A photo or barcode meal still on this phone.
    static func captureRow(_ capture: FoodCapture) -> Row {
        let id = "capture-\(capture.id)"
        switch capture.kind {
        case .photo:
            return Row(
                id: id, entry: capture.id, mark: .striped, title: capture.name,
                label: "ON THIS PHONE · ESTIMATED ONCE SENT", value: "…", dim: true, tap: .takeBack)
        case .barcode(_, let weight, let product?):
            return Row(
                id: id, entry: capture.id, mark: .solid, title: capture.name,
                label: "ON THIS PHONE · NOT COUNTED YET", value: kcal(product.amount(grams: weight).kcal), dim: true,
                tap: .takeBack)
        case .barcode(_, let weight, nil):
            return Row(
                id: id, entry: capture.id, mark: .outline, title: capture.name,
                label: "ON THIS PHONE · \(grams(weight)) G · LOOKED UP ONCE SENT", value: "?", dim: true, tap: .takeBack)
        }
    }

    /// The day's calories or protein, measured and estimated.
    static func split(_ food: FoodDay, kcal: Bool) -> (measured: Double, estimated: Double) {
        if kcal {
            let estimated = Double(food.kcalEstimated ?? 0)
            return (Double(food.kcalMeasured ?? food.kcal), estimated)
        }
        let estimated = food.proteinEstimatedG ?? 0
        return (food.proteinMeasuredG ?? food.proteinG, estimated)
    }

    /// Under the giant figure, once part of it is estimated: how much, and
    /// what the day may really be.
    static func estimateLine(_ food: FoodDay) -> String? {
        guard let estimated = food.kcalEstimated, estimated > 0, let low = food.kcalLow, let high = food.kcalHigh else {
            return nil
        }
        return "\(kcal(estimated)) ESTIMATED · DAY \(kcal(low))–\(kcal(high))"
    }

    /// Said above the day when a logged meal's figures are still to come.
    static func unknownNotice(_ food: FoodDay) -> String? {
        let pending = food.entries.filter { !$0.isKnown }
        guard !pending.isEmpty else { return nil }
        let estimating = pending.filter { $0.figures == .estimating }.count
        let rest = pending.count - estimating
        var parts: [String] = []
        if estimating == 1 { parts.append("1 photo meal is being estimated") }
        if estimating > 1 { parts.append("\(estimating) photo meals are being estimated") }
        if rest == 1 { parts.append("1 meal needs its figures typed") }
        if rest > 1 { parts.append("\(rest) meals need their figures typed") }
        return parts.joined(separator: "; ") + ". Not in the total until then."
    }

    /// "WEIGHED · 43 G PROTEIN", with the portions when not one.
    static func entryLabel(servings: Double, proteinG: Double) -> String {
        let portion = abs(servings - 1) < 0.001 ? "" : " · \(portions(servings))"
        return "WEIGHED\(portion) · \(grams(proteinG)) G PROTEIN"
    }

    /// A saved meal, as the row that logs it.
    static func mealRow(_ meal: SavedMeal) -> Row {
        let batch = meal.portions > 1 ? " · 1 OF \(meal.portions)" : ""
        return Row(
            id: "meal-\(meal.id)", entry: nil, mark: .outline, title: meal.name,
            label: "\(slotName(meal.slot))\(batch) · \(grams(meal.proteinG)) G PROTEIN", value: kcal(meal.kcal))
    }

    /// The row that leads to the targets entry.
    static func targetsLine(_ target: FoodDay.Target?) -> String {
        guard let target else { return "Targets · none yet" }
        return "Targets · \(kcal(target.kcal)) KCAL · \(target.proteinG) G PROTEIN"
    }

    static func unsent(_ count: Int) -> String {
        count == 1
            ? "1 meal is saved on this phone. It is sent when the server can be reached."
            : "\(count) meals are saved on this phone. They are sent when the server can be reached."
    }

    // MARK: The black bar

    enum BarAction: Equatable {
        /// One tap logs one portion of this meal.
        case log(SavedMeal)
        case newMeal
        case setTargets
        case none
    }

    struct Bar: Equatable {
        var small: String
        var big: String
        var action: BarAction

        var mark: String {
            switch action {
            case .log: "+"
            case .newMeal, .setTargets: "→"
            case .none: ""
            }
        }
    }

    /// The next thing to do about food: log the first main meal that is
    /// still open and has a saved meal, the one logged most recently for
    /// it. With nothing to tap it says where the day stands.
    static func bar(_ food: FoodDay, unsent: [MealTap], captures: [FoodCapture] = []) -> Bar {
        if food.meals.isEmpty {
            return Bar(small: "WEIGH IT ONCE · LOG IT WITH ONE TAP", big: "ADD A SAVED MEAL", action: .newMeal)
        }
        let open = food.openSlots.filter { slot in
            !unsent.contains { $0.slot == slot } && !captures.contains { $0.slot == slot }
        }
        for slot in open {
            if let meal = food.meals.first(where: { $0.slot == slot }) {
                return Bar(
                    small: "LOG \(slotName(slot)) · \(kcal(meal.kcal)) KCAL · \(grams(meal.proteinG)) G · ONE TAP",
                    big: meal.name.uppercased(), action: .log(meal))
            }
        }
        if food.target == nil {
            return Bar(small: "TO SEE THE DAY AGAINST THEM", big: "SET YOUR TARGETS", action: .setTargets)
        }
        let standing = "\(kcal(food.kcal)) KCAL · \(leftLine(food))"
        if open.isEmpty {
            return Bar(small: standing, big: unsent.isEmpty ? "DAY LOGGED" : "DAY TAPPED IN", action: .none)
        }
        return Bar(
            small: "\(open.map(slotName).joined(separator: ", ")) OPEN · \(leftLine(food))", big: "LOGGED SO FAR",
            action: .none)
    }

    // MARK: Home

    static func daysInARow(_ days: Int) -> String {
        days == 1 ? "DAY IN A ROW" : "DAYS IN A ROW"
    }

    /// The two lines under "FUEL" in the band on Home.
    static func bandLines(_ food: FoodDay) -> (headline: String, detail: String?) {
        let streak = food.streak
        switch streak.state {
        case .kept:
            return (daysInARow(streak.days), "TODAY LOGGED")
        case .onTrack:
            return (daysInARow(streak.days), "LOG TODAY")
        case .recovering:
            return ("RECOVERING", "ONE MEAL TODAY KEEPS IT")
        case .notStarted:
            return (streak.previousBest > 0 ? "STARTING AGAIN" : "NO STREAK YET", "ONE MEAL LOGGED STARTS ONE")
        }
    }

    /// The seven squares in the band: the last seven days, today last.
    static func squares(_ streak: FoodDay.DayStreak) -> [MarkState] {
        streak.lastDays.map { mark(for: $0.state) }
    }

    static func mark(for state: FoodDay.DayState) -> MarkState {
        switch state {
        case .kept: .solid
        case .recovered, .awaitingRecovery: .striped
        case .missed, .open, .before: .outline
        }
    }

    /// Under the band: today against the targets, and the way in.
    static func homeLine(_ food: FoodDay) -> String {
        guard let target = food.target else {
            return "\(kcal(food.kcal)) KCAL · \(grams(food.proteinG)) G LOGGED"
        }
        return "\(kcal(food.kcal)) OF \(kcal(target.kcal)) KCAL · \(grams(food.proteinG)) OF \(target.proteinG) G"
    }

    /// The band read aloud.
    static func bandSpoken(_ food: FoodDay) -> String {
        let streak = food.streak
        let days = "\(streak.days) \(streak.days == 1 ? "day" : "days") in a row"
        let today = streak.loggedToday ? "Today is logged" : "Nothing logged today"
        switch streak.state {
        case .notStarted: return "Fuel: no streak yet. \(today)."
        case .recovering: return "Fuel: \(days), recovering. \(today)."
        case .onTrack, .kept: return "Fuel: \(days). \(today)."
        }
    }

    static func daysSpoken(_ streak: FoodDay.DayStreak) -> String {
        let logged = streak.lastDays.filter { $0.state == .kept }.count
        var parts = ["Last 7 days: \(logged) logged"]
        if streak.previousBest > 0 {
            parts.append("Previous best \(streak.previousBest) days")
        }
        return parts.joined(separator: ". ")
    }

    // MARK: The meal editor

    /// "80 G · 379 KCAL · 13.2 G PER 100 G": the weight, then the label's
    /// calories and protein, in the order of the fields below it.
    static func ingredientLabel(_ ingredient: Ingredient) -> String {
        "\(plain(ingredient.grams)) G · \(plain(ingredient.kcalPer100g)) KCAL · \(plain(ingredient.proteinPer100g)) G PER 100 G"
    }

    /// The editor's bar: what one portion comes to, or what is missing.
    static func editorBar(_ draft: MealDraft, saving: Bool) -> (small: String, big: String) {
        let big = saving ? "SAVING" : "SAVE MEAL"
        if let missing = draft.missing {
            return (missing.uppercased(), big)
        }
        let portion = draft.portion
        let each = draft.portions > 1 ? "EACH OF \(draft.portions) PORTIONS" : "THE PORTION"
        return ("\(each) · \(kcal(portion.kcal)) KCAL · \(grams(portion.proteinG)) G PROTEIN", big)
    }

    // MARK: The targets entry

    /// Under the two figures: what is in force now.
    static func targetsNow(_ target: FoodDay.Target?) -> String {
        guard let target else { return "No targets yet" }
        return "Now \(kcal(target.kcal)) KCAL · \(target.proteinG) G · since \(target.since.shortLabel)"
    }
}
