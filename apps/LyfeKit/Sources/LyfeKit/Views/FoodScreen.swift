import SwiftUI

/// Food: what is logged today against the calorie and protein targets,
/// measured apart from estimated, each meal of the day as logged or still
/// unknown, and the saved meals, each logged with one tap. The black bar
/// logs the next open meal; anything else is built from parts: scanned,
/// photographed or typed.
public struct FoodScreen: View {
    let food: FoodDay
    var receipt: AppModel.MealReceipt?
    var onDismiss: (UUID) -> Void = { _ in }
    @State private var undoing = false
    /// Meals tapped here that the backend does not have yet.
    var unsent: [MealTap] = []
    /// Meals built or parts added here that the backend does not have yet.
    var captures: [FoodCapture] = []
    /// A meal left half built, to carry on with.
    var building: Building?
    var problem: String?
    let onBack: () -> Void
    /// Logs this many portions of a saved meal.
    let onLog: (SavedMeal, Double) async -> Void
    /// Takes a logged meal back; answers with what went wrong, if anything.
    let onTakeBack: (UUID) async -> String?
    /// Opens the editor on a saved meal, or on a new one.
    let onEditMeal: (SavedMeal?) -> Void
    let onTargets: () -> Void
    /// Each starts a meal, or carries on with the one being built, with
    /// that kind of part.
    var onPhoto: () -> Void = {}
    var onScan: () -> Void = {}
    /// Opens the builder; true to open it at its typing form.
    var onBuild: (Bool) -> Void = { _ in }
    /// Opens a meal logged from parts.
    var onMeal: (UUID) -> Void = { _ in }
    /// Opens a photo meal's estimate.
    var onEstimate: (UUID) -> Void = { _ in }
    /// Opens the label entry for a code lyfe does not know.
    var onLabel: (String) -> Void = { _ in }
    /// Fetches the day again, to follow photos being estimated and drawn.
    var onReload: () async -> Void = {}

    /// What a meal left half built comes to so far.
    public struct Building: Equatable, Sendable {
        public var parts: Int
        public var kcal: Int

        public init(parts: Int, kcal: Int) {
            self.parts = parts
            self.kcal = kcal
        }
    }

    @State private var takingBack: FoodText.Row?
    @State private var note: String?
    /// True for a moment after a tap, so a second one cannot land on
    /// whatever the bar has turned into.
    @State private var busy = false

    public var body: some View {
        day.followingTheSpark(SparkWait(food.entries), reload: onReload)
    }

    @State private var showSaved = false

    private var day: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    FuelHeader(food: food, onBack: onBack, onTargets: onTargets)
                    PosterRule()
                    Button {
                        onBuild(false)
                    } label: {
                        StripRow(
                            left: building == nil ? "Log a meal" : "Continue meal",
                            right: building.map { FoodText.buildingLine($0) } ?? "+"
                        )
                        .frame(minHeight: 48).padding(.vertical, 2)
                        .foregroundStyle(Poster.paper).background(Poster.ink)
                    }.buttonStyle(.plain)
                    if !showSaved,
                        case .log(let meal) = FoodText.bar(food, unsent: unsent, captures: captures).action
                    {
                        Button {
                            log(meal, 1)
                        } label: {
                            StripRow(left: meal.name, right: "+ Log 1 portion").frame(minHeight: 44)
                        }.buttonStyle(.plain).disabled(busy)
                        PosterRule(thickness: 1.5)
                    }
                    Picker("Food view", selection: $showSaved) {
                        Text("Today").tag(false)
                        Text("Saved meals").tag(true)
                    }.pickerStyle(.segmented).padding(Poster.margin)
                    ForEach(notices, id: \.self) { notice in
                        NoticeRow(text: notice)
                        PosterRule(thickness: 1.5)
                    }
                    if showSaved {
                        savedMeals
                    } else {
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
                            case .meal(let id):
                                Button {
                                    onMeal(id)
                                } label: {
                                    FoodRow(row: row)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Shows its parts")
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
                        DisclosureGroup("Food streak") { StreakDays(streak: food.streak) }
                            .padding(Poster.margin).tint(Poster.ink)
                    }
                }
            }
            if let receipt {
                HStack {
                    Text("Logged · \(receipt.name)").font(.headline)
                    Spacer()
                    Button("Undo") {
                        undoing = true
                        Task { note = await onTakeBack(receipt.id); undoing = false }
                    }.disabled(undoing)
                    Button { onDismiss(receipt.id) } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }.accessibilityLabel("Dismiss confirmation")
                }.padding(.leading, Poster.margin).foregroundStyle(Poster.paper).background(Poster.ink)
            }
        }
        .foregroundStyle(Poster.ink)
        .background(Poster.paper.ignoresSafeArea())
        .confirmationDialog(
            takingBack.map { "Take \($0.title) off today?" } ?? "", isPresented: takingBackShown,
            titleVisibility: .visible
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
        if let pending = FoodText.unknownNotice(food) { notices.append(pending) }
        return notices
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
                Text("Food").posterHeading(24).padding(.vertical, 12)
                Spacer()
                Button(action: onTargets) {
                    Text("Targets →").posterLabel().padding(.vertical, 12).contentShape(Rectangle())
                }
                .accessibilityHint("Opens the targets")
            }
            .buttonStyle(.plain)
            Text("\(FoodText.kcal(food.kcal)) kcal").font(.system(size: 46, weight: .heavy))
                .monospacedDigit()
            Text("Logged today · \(FoodText.proteinLine(food)) protein").posterLabel()
            DisclosureGroup("Nutrition details") {
                Text(FoodText.macros(food.entries.flatMap(\.counted))).posterLabel().padding(.bottom, 6)
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
            }.padding(.top, 8).tint(Poster.ink)
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
/// under it, and its calories, with the meal's illustration beside them
/// once it has been drawn.
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
            // Left of the figure, so figures line up with or without one.
            if let picture = row.picture {
                MealIllustration(illustration: picture)
                    .frame(width: 40, height: 40)
                    .padding(.vertical, -6)
            }
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
    /// Three across rather than two.
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 7 : 10) {
            Text(mark).font(.system(size: compact ? 19 : 22, weight: .heavy))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).posterHeading(compact ? 17 : 20)
                Text(detail).posterLabel().opacity(0.6).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 11 : Poster.margin)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Poster.paper)
        .contentShape(Rectangle())
    }
}

/// The three ways to add a part to a meal: scan its barcode, photograph
/// it, or type it.
struct AddPartButtons: View {
    var onScan: () -> Void
    var onPhoto: () -> Void
    var onType: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onScan) {
                CaptureButton(mark: "▥", title: "Scan", detail: "Barcode", compact: true)
            }
            .accessibilityLabel("Scan a barcode")
            Rectangle().fill(Poster.ink).frame(width: Poster.rule)
            Button(action: onPhoto) {
                CaptureButton(mark: "◉", title: "Photo", detail: "One line", compact: true)
            }
            .accessibilityLabel("Add a photo and one line")
            Rectangle().fill(Poster.ink).frame(width: Poster.rule)
            Button(action: onType) {
                CaptureButton(mark: "+", title: "Type", detail: "By hand", compact: true)
            }
            .accessibilityLabel("Type a food by hand")
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
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

    static func macros(_ entries: [FoodDay.Entry]) -> String {
        macros(carbs: entries.map(\.carbsG), fat: entries.map(\.fatG))
    }

    static func macros(carbs: [Double?], fat: [Double?]) -> String {
        func figure(_ values: [Double?]) -> String {
            let known = values.compactMap { $0 }
            if values.isEmpty { return "0 g" }
            if known.isEmpty { return "—" }
            return "\(plain(known.reduce(0, +))) g" + (known.count < values.count ? " recorded" : "")
        }
        return "Carbs \(figure(carbs)) · Fat \(figure(fat))"
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
        /// The illustration shown on the row, once the meal is drawn.
        var picture: Illustration? = nil

        var spoken: String {
            let figure =
                switch value {
                case "?": "unknown"
                case "…": "being estimated"
                case _ where value.hasSuffix(" G"): "\(value.dropLast(2)) grams"
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
        /// Opens a meal logged from parts.
        case meal(UUID)
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
                    label: "ON THIS PHONE · NOT COUNTED YET", value: kcal(tap.kcal), dim: true, tap: .takeBack
                )
            }
            let captured = captures.filter { $0.slot == slot }.map { captureRow($0) }
            let waitingAll = waiting + captured
            if logged.isEmpty, waitingAll.isEmpty {
                return [
                    Row(
                        id: "open-\(slot.rawValue)", entry: nil, mark: .outline,
                        title: slot == .snack ? "SNACKS" : slotName(slot), label: "NOTHING LOGGED", value: "?",
                        dim: true)
                ]
            }
            return logged + waitingAll
        }
    }

    /// A logged meal as its row: solid when measured, striped when
    /// estimated, outlined with a question mark while its figures are not
    /// known.
    static func entryRow(_ entry: FoodDay.Entry) -> Row {
        var row = figuresRow(entry)
        row.picture = entry.illustration
        return row
    }

    private static func figuresRow(_ entry: FoodDay.Entry) -> Row {
        let id = "entry-\(entry.id)"
        switch (entry.from, entry.figures ?? .known) {
        case (.photo, .estimating):
            return Row(
                id: id, entry: entry.id, mark: .striped, title: entry.name,
                label: entry.photo?.problem == nil
                    ? "PHOTO · ESTIMATING ON THE SPARK" : "PHOTO · WAITING FOR THE SPARK",
                value: "…", tap: .estimate(entry.id))
        case (.photo, _) where !entry.isKnown:
            return Row(
                id: id, entry: entry.id, mark: .outline, title: entry.name,
                label: "PHOTO · NO ESTIMATE · TAP TO TYPE IT",
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
        case (.typed, _):
            let weight = entry.weighed.map { " · \(grams($0.grams)) G" } ?? ""
            return Row(
                id: id, entry: entry.id, mark: .solid, title: entry.name,
                label: "TYPED\(weight) · \(grams(entry.proteinG)) G PROTEIN", value: kcal(entry.kcal),
                tap: .takeBack)
        case (.built, _):
            return builtRow(entry)
        case (.saved, _):
            // A photo's estimate among the ingredients keeps it striped.
            let estimated = entry.kcalEstimated ?? 0
            return Row(
                id: id, entry: entry.id, mark: estimated > 0 ? .striped : .solid, title: entry.name,
                label: entryLabel(
                    servings: entry.servings, proteinG: entry.proteinG, kcalEstimated: estimated),
                value: kcal(entry.kcal), tap: .takeBack)
        }
    }

    /// "4 PARTS", "1 PART".
    static func partsCount(_ count: Int) -> String {
        count == 1 ? "1 PART" : "\(count) PARTS"
    }

    /// A meal built from parts, as one row: what its known parts add up
    /// to, striped once a photo is among them. Tapping it shows the parts.
    static func builtRow(_ entry: FoodDay.Entry) -> Row {
        let parts = entry.parts ?? []
        let unknown = parts.filter { !$0.isKnown }.count
        var label = [partsCount(parts.count)]
        if unknown > 0 {
            label.append("\(unknown) STILL UNKNOWN")
            label.append("\(grams(entry.proteinG)) G")
        } else if let low = entry.kcalLow, let high = entry.kcalHigh {
            label.append("\(kcal(low))–\(kcal(high))")
            label.append("\(grams(entry.proteinG)) G")
        } else {
            label.append("\(grams(entry.proteinG)) G PROTEIN")
        }
        let nothingKnown = !parts.isEmpty && unknown == parts.count
        return Row(
            id: "entry-\(entry.id)", entry: entry.id, mark: entry.estimated == true ? .striped : .solid,
            title: entry.name, label: label.joined(separator: " · "),
            value: nothingKnown ? (entry.figures == .estimating ? "…" : "?") : kcal(entry.kcal),
            tap: .meal(entry.id))
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

    /// A meal, or a part joining one, still on this phone.
    static func captureRow(_ capture: FoodCapture) -> Row {
        let id = "capture-\(capture.id)"
        // A part added to a meal already logged says where it is going.
        let waiting = capture.partOf == nil ? "NOT COUNTED YET" : "JOINS ITS MEAL ONCE SENT"
        switch capture.kind {
        case .photo:
            return Row(
                id: id, entry: capture.id, mark: .striped, title: capture.name,
                label: "ON THIS PHONE · ESTIMATED ONCE SENT", value: "…", dim: true, tap: .takeBack)
        case .barcode(_, let weight, let product?):
            return Row(
                id: id, entry: capture.id, mark: .solid, title: capture.name,
                label: "ON THIS PHONE · \(waiting)", value: kcal(product.amount(grams: weight).kcal),
                dim: true,
                tap: .takeBack)
        case .barcode(_, let weight, nil):
            return Row(
                id: id, entry: capture.id, mark: .outline, title: capture.name,
                label: "ON THIS PHONE · \(grams(weight)) G · LOOKED UP ONCE SENT", value: "?", dim: true,
                tap: .takeBack)
        case .typed(let food):
            return Row(
                id: id, entry: capture.id, mark: .solid, title: capture.name,
                label: "ON THIS PHONE · \(waiting)",
                value: kcal(MealDraft.kcal(of: food)), dim: true, tap: .takeBack)
        case .built(_, let parts):
            // What this phone knows of it: a photo or an unknown code is
            // counted once the backend has it.
            let known = parts.compactMap { $0.ingredient(estimate: nil) }
            let photo = parts.contains { if case .photo = $0.kind { true } else { false } }
            return Row(
                id: id, entry: capture.id, mark: photo ? .striped : .solid, title: capture.name,
                label: "ON THIS PHONE · \(partsCount(parts.count)) · NOT COUNTED YET",
                value: known.isEmpty ? "…" : kcal(known.reduce(0) { $0 + MealDraft.kcal(of: $1) }),
                dim: true,
                tap: .takeBack)
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
        guard let estimated = food.kcalEstimated, estimated > 0, let low = food.kcalLow,
            let high = food.kcalHigh
        else {
            return nil
        }
        return "\(kcal(estimated)) ESTIMATED · DAY \(kcal(low))–\(kcal(high))"
    }

    /// Said above the day when something logged is still without its
    /// figures: a meal of one thing, or a part of a built one.
    static func unknownNotice(_ food: FoodDay) -> String? {
        let pending = food.entries.flatMap(\.counted).filter { !$0.isKnown }
        guard !pending.isEmpty else { return nil }
        let estimating = pending.filter { $0.figures == .estimating }.count
        let rest = pending.count - estimating
        var parts: [String] = []
        if estimating == 1 { parts.append("1 photo is being estimated") }
        if estimating > 1 { parts.append("\(estimating) photos are being estimated") }
        if rest == 1 { parts.append("1 food needs its figures typed") }
        if rest > 1 { parts.append("\(rest) foods need their figures typed") }
        return parts.joined(separator: "; ") + ". Not in the total until then."
    }

    /// "WEIGHED · 43 G PROTEIN", with the portions when not one. A meal
    /// with a photo's estimate in it says how much of it is estimated.
    static func entryLabel(servings: Double, proteinG: Double, kcalEstimated: Int = 0) -> String {
        let portion = abs(servings - 1) < 0.001 ? "" : " · \(portions(servings))"
        if kcalEstimated > 0 {
            return "SAVED\(portion) · \(kcal(kcalEstimated)) ESTIMATED · \(grams(proteinG)) G"
        }
        return "WEIGHED\(portion) · \(grams(proteinG)) G PROTEIN"
    }

    /// A saved meal, as the row that logs it.
    static func mealRow(_ meal: SavedMeal) -> Row {
        let batch = meal.portions > 1 ? " · 1 OF \(meal.portions)" : ""
        let estimated = (meal.kcalEstimated ?? 0) > 0 ? " · PART ESTIMATED" : ""
        return Row(
            id: "meal-\(meal.id)", entry: nil, mark: .outline, title: meal.name,
            label: "\(slotName(meal.slot))\(batch) · \(grams(meal.proteinG)) G PROTEIN\(estimated)",
            value: kcal(meal.kcal))
    }

    /// The row on Food that leads back to a meal left half built.
    static func buildingLine(_ building: FoodScreen.Building) -> String {
        "MEAL IN PROGRESS · \(partsCount(building.parts)) · \(kcal(building.kcal)) KCAL"
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
            return Bar(
                small: "WEIGH IT ONCE · LOG IT WITH ONE TAP", big: "ADD A SAVED MEAL", action: .newMeal)
        }
        let open = food.openSlots.filter { slot in
            !unsent.contains { $0.slot == slot } && !captures.contains { $0.slot == slot }
        }
        for slot in open {
            if let meal = food.meals.first(where: { $0.slot == slot }) {
                return Bar(
                    small:
                        "LOG \(slotName(slot)) · \(kcal(meal.kcal)) KCAL · \(grams(meal.proteinG)) G · ONE TAP",
                    big: meal.name.uppercased(), action: .log(meal))
            }
        }
        if food.target == nil {
            return Bar(small: "TO SEE THE DAY AGAINST THEM", big: "SET YOUR TARGETS", action: .setTargets)
        }
        let standing = "\(kcal(food.kcal)) KCAL · \(leftLine(food))"
        if open.isEmpty {
            return Bar(
                small: standing, big: unsent.isEmpty ? "DAY LOGGED" : "DAY TAPPED IN", action: .none)
        }
        return Bar(
            small: "\(open.map(slotName).joined(separator: ", ")) OPEN · \(leftLine(food))",
            big: "LOGGED SO FAR",
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
            return (
                streak.previousBest > 0 ? "STARTING AGAIN" : "NO STREAK YET", "ONE MEAL LOGGED STARTS ONE"
            )
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
        return
            "\(kcal(food.kcal)) OF \(kcal(target.kcal)) KCAL · \(grams(food.proteinG)) OF \(target.proteinG) G"
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

    // MARK: The meal builder

    /// What an ingredient is, under its name. Weighed and typed: "80 G ·
    /// 379 KCAL · 13.2 G PER 100 G", the weight, then the label's calories
    /// and protein, in the order of the fields below it. Scanned: its
    /// weight. Typed whole, or a photo's estimate: said so.
    static func ingredientLabel(_ food: Ingredient) -> String {
        switch food.quantity {
        case .weighed(let weight, let kcalPer100g, let proteinPer100g) where food.code == nil:
            "\(plain(weight)) G · \(plain(kcalPer100g)) KCAL · \(plain(proteinPer100g)) G PER 100 G"
        case .weighed(let weight, _, _):
            "LABEL · \(plain(weight)) G · \(grams(food.proteinG)) G PROTEIN"
        case .whole where food.estimated:
            "PHOTO ESTIMATE · \(grams(food.proteinG)) G PROTEIN"
        case .whole:
            "TYPED WHOLE · \(grams(food.proteinG)) G PROTEIN"
        }
    }

    /// A part of the meal on the builder, as its row: solid when its
    /// figures are measured, striped when they are a photo's, outlined
    /// with a question mark while lyfe cannot say. `estimate` is the
    /// backend's entry for a photo; `unsent` says it is still on this phone.
    static func partRow(_ part: MealPart, estimate: FoodDay.Entry? = nil, unsent: Bool = false) -> Row {
        let id = "part-\(part.id)"
        switch part.kind {
        case .food(let food):
            return Row(
                id: id, entry: nil, mark: food.estimated ? .striped : .solid, title: food.name,
                label: ingredientLabel(food), value: kcal(MealDraft.kcal(of: food)))
        case .scan(_, let weight):
            return Row(
                id: id, entry: nil, mark: .outline, title: part.name,
                label: "\(plain(weight)) G · LOOKED UP ONCE SENT", value: "?")
        case .photo:
            if let estimate {
                var row = entryRow(estimate)
                row.id = id
                return row
            }
            return Row(
                id: id, entry: nil, mark: .striped, title: part.name,
                label: unsent ? "PHOTO · ON THIS PHONE · ESTIMATED ONCE SENT" : "PHOTO · SENT TO THE SPARK",
                value: "…")
        }
    }

    /// Under the builder's running figure: the protein, how much of it is
    /// estimated, and what is still to come.
    static func totalLine(_ total: MealDraft.Total, parts: Int) -> String {
        var line = [partsCount(parts), "\(grams(total.proteinG)) G PROTEIN"]
        if total.kcalEstimated > 0 { line.append("\(kcal(total.kcalEstimated)) ESTIMATED") }
        if total.unknown > 0 { line.append("\(total.unknown) STILL UNKNOWN") }
        return line.joined(separator: " · ")
    }

    /// The builder's bar for a meal to be logged: what it comes to so far.
    static func logBar(_ draft: MealDraft, total: MealDraft.Total, logging: Bool) -> (
        small: String, big: String
    ) {
        let big = logging ? "LOGGING" : "LOG IT"
        if draft.parts.isEmpty {
            return ("SCAN, PHOTOGRAPH OR TYPE WHAT YOU ATE", big)
        }
        if draft.isSaved {
            return ("SAVED · LOGS ONE PORTION AS \(slotName(draft.slot))", big)
        }
        let waiting = total.unknown > 0 ? " · \(total.unknown) TO COME" : ""
        return (
            "\(slotName(draft.slot)) · \(kcal(total.kcal)) KCAL · \(grams(total.proteinG)) G\(waiting)",
            big
        )
    }

    /// The builder's bar for a saved meal: what one portion comes to, or
    /// what is missing.
    static func editorBar(_ draft: MealDraft, estimates: [UUID: FoodDay.Entry] = [:], saving: Bool)
        -> (
            small: String, big: String
        )
    {
        let big = saving ? "SAVING" : "SAVE MEAL"
        if let missing = draft.missing(estimates: estimates) {
            return (missing.uppercased(), big)
        }
        return (portionLine(draft, estimates: estimates), big)
    }

    /// "EACH OF 5 PORTIONS · 561 KCAL · 49 G PROTEIN"
    static func portionLine(_ draft: MealDraft, estimates: [UUID: FoodDay.Entry] = [:]) -> String {
        let portion = draft.portion(estimates: estimates)
        let each = draft.portions > 1 ? "EACH OF \(draft.portions) PORTIONS" : "THE PORTION"
        return "\(each) · \(kcal(portion.kcal)) KCAL · \(grams(portion.proteinG)) G PROTEIN"
    }

    // MARK: A logged meal

    /// Under a logged meal's figure: its parts, protein, and what of it is
    /// estimated or still unknown.
    static func mealLine(_ meal: FoodDay.Entry) -> String {
        let parts = meal.parts ?? []
        var line = [partsCount(parts.count), "\(grams(meal.proteinG)) G PROTEIN"]
        if let low = meal.kcalLow, let high = meal.kcalHigh {
            line.append("\(kcal(meal.kcalEstimated ?? 0)) ESTIMATED · \(kcal(low))–\(kcal(high))")
        }
        let unknown = parts.filter { !$0.isKnown }.count
        if unknown > 0 { line.append("\(unknown) STILL UNKNOWN") }
        return line.joined(separator: " · ")
    }

    // MARK: The targets entry

    /// Under the two figures: what is in force now.
    static func targetsNow(_ target: FoodDay.Target?) -> String {
        guard let target else { return "No targets yet" }
        return "Now \(kcal(target.kcal)) KCAL · \(target.proteinG) G · since \(target.since.shortLabel)"
    }
}
