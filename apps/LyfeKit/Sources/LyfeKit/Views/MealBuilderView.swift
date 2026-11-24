import SwiftUI

/// The meal builder: what was eaten, added part by part, with what it
/// comes to kept on screen. A part is scanned from its barcode, taken as a
/// photo and one line, or typed. The meal is logged as one meal, saved for
/// one tap next time, or both. The same screen types and changes a saved
/// meal, where it only saves.
public struct MealBuilderView: View {
    var recent: [[Ingredient]] = []
    var saved: [SavedMeal] = []
    var onSaved: (SavedMeal) -> Void = { _ in }
    let draft: MealDraft
    /// The backend's entry for each photo part, once it has one.
    var estimates: [UUID: FoodDay.Entry] = [:]
    /// Photo parts still on this phone, waiting to be sent.
    var unsent: Set<UUID> = []
    let onChange: ((inout MealDraft) -> Void) -> Void
    var onScan: () -> Void = {}
    var onPhoto: () -> Void = {}
    /// Opens a photo part's estimate, to correct it.
    var onEstimate: (UUID) -> Void = { _ in }
    /// Logs the meal; answers with what went wrong, if anything.
    var onLog: () async -> String? = { nil }
    let onSave: () async -> String?
    /// Takes the saved meal being changed out of the list.
    var onRemove: () async -> String? = { nil }
    /// Throws away the meal being built.
    var onDiscard: () async -> Void = {}
    /// Sends what is waiting and fetches the estimates again.
    var onFollow: () async -> Void = {}
    let onClose: () -> Void

    /// The typing form.
    @State private var fields = TypedFields()
    @State private var typing: Bool
    /// The part being changed.
    @State private var selected: UUID?
    @State private var grams = ""
    /// The "save for one tap" section, on a meal being logged.
    @State private var browsing = false
    @State private var savingOpen = false
    @State private var note: String?
    @State private var busy: Busy?
    @State private var confirming: Confirming?
    @FocusState private var nameFocused: Bool

    enum Busy {
        case logging, saving
    }

    enum Confirming: Identifiable {
        case remove, discard
        var id: Self { self }
    }

    public init(
        draft: MealDraft, recent: [[Ingredient]] = [], saved: [SavedMeal] = [], onSaved: @escaping (SavedMeal) -> Void = { _ in }, estimates: [UUID: FoodDay.Entry] = [:], unsent: Set<UUID> = [],
        typing: Bool = false,
        onChange: @escaping ((inout MealDraft) -> Void) -> Void, onScan: @escaping () -> Void = {},
        onPhoto: @escaping () -> Void = {}, onEstimate: @escaping (UUID) -> Void = { _ in },
        onLog: @escaping () async -> String? = { nil }, onSave: @escaping () async -> String?,
        onRemove: @escaping () async -> String? = { nil }, onDiscard: @escaping () async -> Void = {},
        onFollow: @escaping () async -> Void = {}, onClose: @escaping () -> Void
    ) {
        self.recent = recent
        self.onSaved = onSaved
        self.saved = saved
        self.draft = draft
        self.estimates = estimates
        self.unsent = unsent
        self.onChange = onChange
        self.onScan = onScan
        self.onPhoto = onPhoto
        self.onEstimate = onEstimate
        self.onLog = onLog
        self.onSave = onSave
        self.onRemove = onRemove
        self.onDiscard = onDiscard
        self.onFollow = onFollow
        self.onClose = onClose
        // A recipe with nothing in it yet starts at the typing form, as
        // weighing a meal once does.
        _typing = State(initialValue: typing || (draft.purpose == .recipe && draft.parts.isEmpty))
    }

    /// The builder as the galleries show it: with the ingredient picker
    /// open, or the typing form open on what is already typed.
    init(
        draft: MealDraft, browsing: Bool, typed: TypedFields? = nil, onChange: @escaping ((inout MealDraft) -> Void) -> Void
    ) {
        self.init(draft: draft, typing: typed != nil, onChange: onChange, onSave: { nil }, onClose: {})
        _browsing = State(initialValue: browsing)
        if let typed { _fields = State(initialValue: typed) }
    }

    private var logs: Bool { draft.purpose == .log }
    private var total: MealDraft.Total { draft.total(estimates: estimates) }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    PosterRule()
                    if logs, draft.parts.isEmpty, !typing, !browsing {
                        if !recent.isEmpty {
                            ScrollView(.horizontal) {
                                HStack {
                                    ForEach(recent.indices, id: \.self) { index in
                                        let portion = recent[index]
                                        Button { onChange { $0.parts = portion.map { MealPart(.food($0)) } } } label: {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("Recent · \(Int(portion.reduce(0) { $0 + $1.kcal }.rounded())) kcal").posterLabel()
                                                Text(portion.map(\.name).joined(separator: " + ")).font(.headline).lineLimit(2)
                                            }.padding(12).frame(maxWidth: 210, alignment: .leading).background(Poster.yellow)
                                        }.buttonStyle(.plain)
                                    }
                                }.padding(.horizontal, Poster.margin)
                            }.padding(.vertical, 8)
                        }
                        if !saved.isEmpty {
                            Menu {
                                ForEach(saved) { meal in Button(meal.name) { onSaved(meal) } }
                            } label: { StripRow(left: "Log a saved meal", right: "1 portion ▾").frame(minHeight: 44) }
                            PosterRule(thickness: 1.5)
                        }
                    }
                    ForEach(draft.parts) { part in
                        Button {
                            tap(part)
                        } label: {
                            FoodRow(
                                row: FoodText.partRow(
                                    part, estimate: estimates[part.id], unsent: unsent.contains(part.id))
                            )
                            .background(selected == part.id ? Poster.yellow : .clear)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(hint(for: part))
                        PosterRule(thickness: 1.5)
                    }
                    if let part = draft.parts.first(where: { $0.id == selected }) {
                        change(part)
                    } else {
                        Button {
                            browsing.toggle()
                            typing = false
                        } label: {
                            StripRow(left: "Find an ingredient", right: browsing ? "Close" : "Search →")
                                .frame(minHeight: 44)
                        }.buttonStyle(.plain)
                        if browsing {
                            IngredientPicker { food in
                                guard draft.parts.count < MealDraft.maxParts else {
                                    note = "A meal takes \(MealDraft.maxParts) parts at most."
                                    return
                                }
                                onChange { $0.parts.append(MealPart(.food(food))) }
                                browsing = false
                                note = nil
                            }
                        }
                        AddPartButtons(onScan: onScan, onPhoto: onPhoto) {
                            typing.toggle()
                            browsing = false
                            note = nil
                        }
                        if typing {
                            PosterRule(thickness: 1.5)
                            TypedFieldsView(
                                fields: $fields, title: logs ? "Type what you ate" : "Add what goes into it",
                                primary: "Add", onPrimary: { add() })
                        }
                    }
                    PosterRule()
                    if let note {
                        NoticeRow(text: note)
                        PosterRule(thickness: 1.5)
                    }
                    if logs, !draft.parts.isEmpty {
                        saveForOneTap
                    }
                    wayOut
                }
            }
            .scrollDismissesKeyboard(.interactively)
            if !logs || !draft.parts.isEmpty || typing { bar }
        }
        .foregroundStyle(Poster.ink)
        .background(Poster.paper.ignoresSafeArea())
        .onAppear {
            if !logs, draft.isNew, draft.parts.isEmpty { nameFocused = true }
        }
        // While a photo is with the model, look again every few seconds.
        .task(id: awaited) {
            while awaited, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                await onFollow()
            }
        }
        .confirmationDialog(
            confirmTitle, isPresented: confirmShown, titleVisibility: .visible, presenting: confirming
        ) {
            switch $0 {
            case .remove:
                Button("Remove", role: .destructive) {
                    Task { note = await onRemove() }
                }
            case .discard:
                Button("Throw it away", role: .destructive) {
                    Task { await onDiscard() }
                }
            }
        } message: {
            switch $0 {
            case .remove: Text("What you logged from it stays.")
            case .discard: Text("Nothing of it is logged.")
            }
        }
    }

    /// True while a photo part is still to be sent or estimated.
    private var awaited: Bool {
        draft.parts.contains { part in
            guard case .photo = part.kind else { return false }
            return estimates[part.id].map { $0.figures == .estimating } ?? true
        }
    }

    private var confirmTitle: String {
        switch confirming {
        case .remove: "Remove \(draft.name) from your saved meals?"
        case .discard: "Throw this meal away?"
        case nil: ""
        }
    }

    private var confirmShown: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    private var name: Binding<String> {
        Binding(get: { draft.name }, set: { text in onChange { $0.name = text } })
    }

    private var slot: Binding<MealSlot> {
        Binding(get: { draft.slot }, set: { slot in onChange { $0.slot = slot } })
    }

    /// The meal itself: its name, when it is eaten, and what it comes to
    /// so far; for a recipe, how many portions it makes.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            TopLine(left: "✕ Close", right: title, onLeft: onClose)
                .padding(.horizontal, -Poster.margin)
            if logs {
                Menu {
                    Picker("Meal", selection: slot) {
                        ForEach(MealSlot.allCases, id: \.self) { item in Text(item.title).tag(item) }
                    }
                } label: { Text("\(draft.slot.title) ▾").posterLabel().frame(minHeight: 44) }
            } else {
                mealName
                SlotPicker(slot: slot).padding(.top, 10)
            }
            if logs, !draft.parts.isEmpty {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(Poster.tight(FoodText.kcal(total.kcal), by: -4))
                        .font(.system(size: 76, weight: .heavy))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                    Text("kcal").posterHeading(24)
                    Spacer(minLength: 0)
                }
                .padding(.top, 4)
                .padding(.bottom, -6)
                .animation(.snappy, value: total.kcal)
                Text(FoodText.totalLine(total, parts: draft.parts.count)).posterLabel()
                    .accessibilityLabel(
                        "\(total.kcal) kilocalories so far, \(FoodText.totalLine(total, parts: draft.parts.count))"
                    )
                let foods = draft.parts.map { $0.ingredient(estimate: estimates[$0.id]) }
                Text(FoodText.macros(carbs: foods.map { $0?.carbsG }, fat: foods.map { $0?.fatG }))
                    .posterLabel()
            } else if !logs {
                PortionStepper(
                    portions: Binding(
                        get: { draft.portions }, set: { count in onChange { $0.portions = count } })
                )
                .padding(.top, 12)
            }
        }
        .padding(.horizontal, Poster.margin)
        .padding(.bottom, 12)
    }

    private var mealName: some View {
            TextField(
                "", text: name,
                prompt: Text("Meal name")
                    .foregroundStyle(Poster.ink.opacity(0.25))
            )
            .font(.system(size: 34, weight: .heavy))
            .tracking(-1)
            .focused($nameFocused)
            .submitLabel(.done)
            #if os(iOS)
                .textInputAutocapitalization(.characters)
            #endif
            .autocorrectionDisabled()
            .accessibilityLabel("Meal name")
    }

    private var title: String {
        if logs { return "Build a meal" }
        return draft.isNew ? "New saved meal" : "Saved meal"
    }

    private func hint(for part: MealPart) -> String {
        if case .photo = part.kind, estimates[part.id] != nil {
            return "Shows the estimate, to correct it"
        }
        return "Changes this part"
    }

    /// A photo with an estimate opens it; anything else is picked to be
    /// changed or taken out.
    private func tap(_ part: MealPart) {
        note = nil
        if case .photo = part.kind, estimates[part.id] != nil {
            onEstimate(part.id)
            return
        }
        guard selected != part.id else {
            selected = nil
            return
        }
        selected = part.id
        switch part.kind {
        case .food(let food) where food.code == nil:
            fields = TypedFields(food)
        case .food(let food):
            grams = food.grams.map(FoodText.plain) ?? ""
        case .scan(_, let weight):
            grams = FoodText.plain(weight)
        case .photo:
            break
        }
    }

    /// The part picked, open to change: the typed form for a typed food,
    /// its grams for a scanned one, and the way to take it out.
    @ViewBuilder
    private func change(_ part: MealPart) -> some View {
        switch part.kind {
        case .food(let food) where food.code == nil:
            TypedFieldsView(
                fields: $fields,
                title: food.estimated ? "A photo's estimate · type it to replace it" : "Change this part",
                primary: "Keep the change", onPrimary: { keepTyped(part) }, secondary: "Take it out",
                onSecondary: { takeOut(part) })
        case .food, .scan:
            VStack(alignment: .leading, spacing: 8) {
                Text("How much of it").posterLabel()
                HStack(alignment: .bottom, spacing: 6) {
                    LabeledField(label: "Grams", text: $grams, prompt: "60", numeric: true)
                    FormButton(title: "Keep", filled: true) { keepGrams(part) }
                    FormButton(title: "Take it out", filled: false) { takeOut(part) }
                }
            }
            .padding(.horizontal, Poster.margin)
            .padding(.vertical, 12)
            .background(Poster.yellow)
        case .photo:
            VStack(alignment: .leading, spacing: 8) {
                Text("Its estimate shows here once the model has answered").posterLabel()
                FormButton(title: "Take it out", filled: false) { takeOut(part) }
            }
            .padding(.horizontal, Poster.margin)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Poster.yellow)
        }
    }

    /// Saving the meal being logged for one tap next time: closed until
    /// asked for, since a meal eaten once needs neither a name nor portions.
    @ViewBuilder
    private var saveForOneTap: some View {
        Button {
            savingOpen.toggle()
            note = nil
        } label: {
            StripRow(
                left: draft.isSaved ? "■ Saved for one tap" : "Save it for one tap next time",
                right: savingOpen ? "Close ↑" : (draft.isSaved ? "Change →" : "→"))
        }
        .buttonStyle(.plain)
        if savingOpen {
            VStack(alignment: .leading, spacing: 10) {
                mealName
                PortionStepper(
                    portions: Binding(
                        get: { draft.portions }, set: { count in onChange { $0.portions = count } }))
                Text(
                    draft.missing(estimates: estimates).map { $0 + " first" }
                        ?? FoodText.portionLine(draft, estimates: estimates)
                )
                .posterLabel()
                FormButton(
                    title: busy == .saving ? "Saving" : (draft.isSaved ? "Saved" : "Save it"), filled: true
                ) {
                    Task { await save() }
                }
                .allowsHitTesting(busy == nil && !draft.isSaved)
                .opacity(draft.isSaved ? 0.45 : 1)
            }
            .padding(.horizontal, Poster.margin)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Poster.yellow)
        }
        PosterRule(thickness: 1.5)
    }

    /// The way out that keeps nothing: throwing a meal away, or removing
    /// a saved one.
    @ViewBuilder
    private var wayOut: some View {
        if logs, !draft.parts.isEmpty {
            dimLink("Throw this meal away") { confirming = .discard }
        } else if !logs, !draft.isNew {
            dimLink("Remove this meal") { confirming = .remove }
        }
    }

    private func dimLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).posterLabel().opacity(0.55)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var bar: some View {
        let words =
            logs
            ? FoodText.logBar(draft, total: total, logging: busy == .logging)
            : FoodText.editorBar(draft, estimates: estimates, saving: busy == .saving)
        return Button {
            Task {
                if logs { await log() } else { await save() }
            }
        } label: {
            BreathBar(small: words.small, big: words.big, mark: "→", onDark: false)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(busy == nil)
    }

    /// Takes what is in the form into the meal. False when it does not
    /// read as a food; the note then says why.
    @discardableResult
    private func add() -> Bool {
        switch fields.read() {
        case .success(let food):
            guard draft.parts.count < MealDraft.maxParts else {
                note = "A meal takes \(MealDraft.maxParts) parts at most."
                return false
            }
            onChange { $0.parts.append(MealPart(.food(food))) }
            fields = TypedFields(way: fields.way)
            note = nil
            return true
        case .failure(let slip):
            note = slip.message + "."
            return false
        }
    }

    private func keepTyped(_ part: MealPart) {
        switch fields.read() {
        case .success(let food):
            replace(part, with: .food(food))
        case .failure(let slip):
            note = slip.message + "."
        }
    }

    private func keepGrams(_ part: MealPart) {
        guard case .success(let weight) = FoodTyping.grams(grams) else {
            note = "Type the grams, like 45."
            return
        }
        switch part.kind {
        case .food(var food):
            if case .weighed(_, let kcalPer100g, let proteinPer100g) = food.quantity {
                food.quantity = .weighed(
                    grams: weight, kcalPer100g: kcalPer100g, proteinPer100g: proteinPer100g)
            }
            replace(part, with: .food(food))
        case .scan(let code, _):
            replace(part, with: .scan(code: code, grams: weight))
        case .photo:
            break
        }
    }

    private func replace(_ part: MealPart, with kind: MealPart.Kind) {
        onChange { draft in
            if let index = draft.parts.firstIndex(where: { $0.id == part.id }) {
                draft.parts[index].kind = kind
            }
        }
        deselect()
    }

    private func takeOut(_ part: MealPart) {
        onChange { $0.parts.removeAll { $0.id == part.id } }
        deselect()
    }

    private func deselect() {
        selected = nil
        fields = TypedFields(way: fields.way)
        note = nil
    }

    /// A food typed but not yet added is taken in, not lost.
    private func takeInWhatIsTyped() -> Bool {
        guard selected == nil, typing, !fields.isEmpty else { return true }
        return add()
    }

    private func log() async {
        guard takeInWhatIsTyped() else { return }
        busy = .logging
        defer { busy = nil }
        nameFocused = false
        note = await onLog()
    }

    private func save() async {
        guard takeInWhatIsTyped() else { return }
        busy = .saving
        defer { busy = nil }
        nameFocused = false
        note = await onSave()
    }
}

/// A meal logged from parts: what it comes to, and each part, to correct,
/// take out or add to. Once every part's figures are known it can be saved
/// for one tap.
public struct LoggedMealView: View {
    let meal: FoodDay.Entry
    /// Parts added here that the backend does not have yet.
    var unsent: [FoodCapture] = []
    var onScan: () -> Void = {}
    var onPhoto: () -> Void = {}
    /// Adds a typed food to the meal.
    var onType: (Ingredient) async -> Void = { _ in }
    var onEstimate: (UUID) -> Void = { _ in }
    var onLabel: (String) -> Void = { _ in }
    /// Takes a part out, or the whole meal off the day.
    let onTakeBack: (UUID) async -> String?
    /// Opens the builder to save the meal; false while it cannot be.
    var onSave: () -> Bool = { false }
    /// Fetches the day again, to follow a photo still being estimated.
    var onReload: () async -> Void = {}
    let onClose: () -> Void

    @State private var fields = TypedFields()
    @State private var typing = false
    @State private var takingOut: FoodText.Row?
    @State private var takingOff = false
    @State private var note: String?

    public init(
        meal: FoodDay.Entry, unsent: [FoodCapture] = [], onScan: @escaping () -> Void = {},
        onPhoto: @escaping () -> Void = {}, onType: @escaping (Ingredient) async -> Void = { _ in },
        onEstimate: @escaping (UUID) -> Void = { _ in }, onLabel: @escaping (String) -> Void = { _ in },
        onTakeBack: @escaping (UUID) async -> String?, onSave: @escaping () -> Bool = { false },
        onReload: @escaping () async -> Void = {}, onClose: @escaping () -> Void
    ) {
        self.meal = meal
        self.unsent = unsent
        self.onScan = onScan
        self.onPhoto = onPhoto
        self.onType = onType
        self.onEstimate = onEstimate
        self.onLabel = onLabel
        self.onTakeBack = onTakeBack
        self.onSave = onSave
        self.onReload = onReload
        self.onClose = onClose
    }

    private var parts: [FoodDay.Entry] { meal.parts ?? [] }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TopLine(
                        left: "← Food", right: "\(FoodText.slotName(meal.slot)) · Logged", onLeft: onClose)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(meal.name).posterHeading(34).lineLimit(2).minimumScaleFactor(0.6)
                        HStack(alignment: .lastTextBaseline, spacing: 8) {
                            Text(Poster.tight(FoodText.kcal(meal.kcal), by: -4))
                                .font(.system(size: 76, weight: .heavy))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .contentTransition(.numericText())
                            Text("kcal").posterHeading(24)
                            Spacer(minLength: 0)
                        }
                        .padding(.bottom, -6)
                        .animation(.snappy, value: meal.kcal)
                        Text(FoodText.mealLine(meal)).posterLabel()
                        Text(FoodText.macros(parts)).posterLabel()
                    }
                    .padding(.horizontal, Poster.margin)
                    .padding(.bottom, 12)
                    PosterRule()
                    ForEach(parts) { part in
                        partRow(FoodText.entryRow(part))
                        PosterRule(thickness: 1.5)
                    }
                    ForEach(unsent) { capture in
                        partRow(FoodText.captureRow(capture))
                        PosterRule(thickness: 1.5)
                    }
                    IngredientPicker { food in Task { await onType(food) } }
                    AddPartButtons(onScan: onScan, onPhoto: onPhoto) {
                        typing.toggle()
                        note = nil
                    }
                    if typing {
                        PosterRule(thickness: 1.5)
                        TypedFieldsView(
                            fields: $fields, title: "Type what else you ate", primary: "Add", onPrimary: { add() }
                        )
                    }
                    PosterRule()
                    if let note {
                        NoticeRow(text: note)
                        PosterRule(thickness: 1.5)
                    }
                    Button {
                        if !onSave() {
                            note = "It can be saved once every part's figures are known."
                        }
                    } label: {
                        StripRow(left: "Save it for one tap next time", right: "→")
                    }
                    .buttonStyle(.plain)
                    PosterRule(thickness: 1.5)
                    Button {
                        takingOff = true
                    } label: {
                        Text("Take the meal off today").posterLabel().opacity(0.55)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            Button(action: onClose) {
                BreathBar(small: "Counts for today's streak", big: "DONE", mark: "→", onDark: false)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Poster.ink)
        .background(Poster.paper.ignoresSafeArea())
        // While a photo is with the model, or still to be drawn, look again.
        .followingTheSpark(SparkWait(parts), reload: onReload)
        .confirmationDialog(
            takingOut.map { "Take \($0.title) out of \(meal.name)?" } ?? "", isPresented: takingOutShown,
            titleVisibility: .visible
        ) {
            Button("Take it out", role: .destructive) {
                guard let id = takingOut?.entry else { return }
                Task { note = await onTakeBack(id) }
            }
        }
        .confirmationDialog(
            "Take \(meal.name) off today?", isPresented: $takingOff, titleVisibility: .visible
        ) {
            Button("Take it off", role: .destructive) {
                Task {
                    note = await onTakeBack(meal.id)
                    if note == nil { onClose() }
                }
            }
        } message: {
            Text("All of its parts go with it.")
        }
    }

    private var takingOutShown: Binding<Bool> {
        Binding(get: { takingOut != nil }, set: { if !$0 { takingOut = nil } })
    }

    /// A part as its row on the day would be: a photo opens its estimate,
    /// an unknown code its label, anything else asks to be taken out.
    @ViewBuilder
    private func partRow(_ row: FoodText.Row) -> some View {
        Button {
            switch row.tap {
            case .estimate(let id): onEstimate(id)
            case .label(let code): onLabel(code)
            case .takeBack: takingOut = row
            case .meal, .none: break
            }
        } label: {
            FoodRow(row: row)
        }
        .buttonStyle(.plain)
        .accessibilityHint(row.tap == .takeBack ? "Takes it out of the meal" : "Opens it")
    }

    private func add() {
        switch fields.read() {
        case .success(let food):
            fields = TypedFields(way: fields.way)
            note = nil
            Task { await onType(food) }
        case .failure(let slip):
            note = slip.message + "."
        }
    }
}

// MARK: Parts

/// What is typed for one food: weighed, with the label's figures per
/// 100 g; whole, just what it comes to; or as its macros alone, with the
/// calories worked out from them.
struct TypedFields: Equatable {
    var way = Way.weighed
    var name = ""
    var grams = ""
    /// Per 100 g when weighed; what it comes to when whole. Not typed for
    /// macros.
    var kcal = ""
    /// Per 100 g when weighed; grams otherwise.
    var protein = ""
    var carbs = ""
    var fat = ""

    /// The three ways to type a food.
    enum Way: Equatable, CaseIterable {
        /// Weighed, with the figures per 100 g from its label.
        case weighed
        /// Just the totals: a menu item, a coffee from a café.
        case whole
        /// Only the grams of protein, carbs and fat it has.
        case macros

        var title: String {
            switch self {
            case .weighed: "Weighed"
            case .whole: "Just the totals"
            case .macros: "Macros"
            }
        }
    }

    init(way: Way = .weighed) {
        self.way = way
    }

    /// A food, back in the form to be changed.
    init(_ food: Ingredient) {
        name = food.name
        let scale = food.grams.map { 100 / $0 } ?? 1
        carbs = food.carbsG.map { FoodText.plain($0 * scale) } ?? ""
        fat = food.fatG.map { FoodText.plain($0 * scale) } ?? ""
        switch food.quantity {
        case .weighed(let weight, let kcalPer100g, let proteinPer100g):
            grams = FoodText.plain(weight)
            kcal = FoodText.plain(kcalPer100g)
            protein = FoodText.plain(proteinPer100g)
        case .whole(_, let proteinG) where Macros.made(food):
            way = .macros
            // None of one is left blank, as it was typed.
            protein = proteinG > 0 ? FoodText.plain(proteinG) : ""
            if food.carbsG == 0 { carbs = "" }
            if food.fatG == 0 { fat = "" }
            // A name lyfe gave it follows the figures when they change.
            if name == Macros.name(proteinG: proteinG, carbsG: food.carbsG ?? 0, fatG: food.fatG ?? 0) {
                name = ""
            }
        case .whole(let kcal, let proteinG):
            way = .whole
            self.kcal = FoodText.plain(kcal)
            protein = FoodText.plain(proteinG)
        }
    }

    var isEmpty: Bool {
        [name, grams, kcal, protein, carbs, fat].allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// What the macros typed so far come to, in kcal; nil while any of
    /// them does not read as a figure.
    var macrosKcal: Double? {
        var grams: [Double] = []
        for text in [protein, carbs, fat] {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                grams.append(0)
            } else if let value = FoodTyping.number(text) {
                grams.append(value)
            } else {
                return nil
            }
        }
        return Macros.kcal(proteinG: grams[0], carbsG: grams[1], fatG: grams[2])
    }

    /// The food typed, or the first thing wrong with it.
    func read() -> Result<Ingredient, FoodSlip> {
        let result: Result<Ingredient, FoodSlip>
        switch way {
        case .weighed: result = FoodTyping.ingredient(name: name, grams: grams, kcal: kcal, protein: protein)
        case .whole: result = FoodTyping.whole(name: name, kcal: kcal, protein: protein)
        case .macros: return FoodTyping.macros(name: name, protein: protein, carbs: carbs, fat: fat)
        }
        return result.flatMap { ingredient in
            var food = ingredient
            let scale = food.grams.map { $0 / 100 } ?? 1
            for (text, key) in [(carbs, \Ingredient.carbsG), (fat, \Ingredient.fatG)] where !text.isEmpty {
                guard let value = FoodTyping.number(text), value <= (way == .whole ? 1000 : 100) else {
                    return .failure(FoodSlip("Check the carbs and fat, or leave them blank"))
                }
                food[keyPath: key] = value * scale
            }
            return .success(food)
        }
    }
}

/// The typing form, in yellow: what it is, then what it weighed and the
/// figures from its label, or just what it comes to, or only its macros.
struct TypedFieldsView: View {
    @Binding var fields: TypedFields
    var title: String
    var primary: String
    var onPrimary: () -> Void
    var secondary: String?
    var onSecondary: () -> Void = {}

    @FocusState private var focus: Field?

    enum Field {
        case name, first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).posterLabel().lineLimit(1).minimumScaleFactor(0.7)
            HStack(spacing: 6) {
                ForEach(TypedFields.Way.allCases, id: \.self) { way($0) }
                Spacer(minLength: 0)
            }
            // The return key leads on to the figures, which brings their
            // row up from behind the keyboard.
            LabeledField(
                label: fields.way == .macros ? "What it is · or leave it blank" : "What it is",
                text: $fields.name, prompt: namePrompt, onSubmit: { focus = .first }
            )
            .focused($focus, equals: .name)
            HStack(alignment: .bottom, spacing: 6) {
                switch fields.way {
                case .weighed:
                    LabeledField(label: "Weighed · g", text: $fields.grams, prompt: "80", numeric: true)
                        .focused($focus, equals: .first)
                    LabeledField(label: "kcal per 100 g", text: $fields.kcal, prompt: "379", numeric: true)
                    LabeledField(
                        label: "Protein per 100 g", text: $fields.protein, prompt: "13.2", numeric: true)
                case .whole:
                    LabeledField(label: "kcal", text: $fields.kcal, prompt: "120", numeric: true)
                        .focused($focus, equals: .first)
                    LabeledField(label: "Protein · g", text: $fields.protein, prompt: "6", numeric: true)
                case .macros:
                    LabeledField(label: "Protein · g", text: $fields.protein, prompt: "0", numeric: true)
                        .focused($focus, equals: .first)
                    LabeledField(label: "Carbs · g", text: $fields.carbs, prompt: "0", numeric: true)
                    LabeledField(label: "Fat · g", text: $fields.fat, prompt: "0", numeric: true)
                }
            }
            if fields.way == .macros {
                Text(FoodText.macrosComeTo(fields.macrosKcal)).posterLabel()
            } else {
                HStack(spacing: 6) {
                    LabeledField(
                        label: fields.way == .whole ? "Carbs · g" : "Carbs per 100 g", text: $fields.carbs,
                        prompt: "Optional", numeric: true)
                    LabeledField(
                        label: fields.way == .whole ? "Fat · g" : "Fat per 100 g", text: $fields.fat,
                        prompt: "Optional", numeric: true)
                }
            }
            HStack(spacing: 6) {
                FormButton(title: primary, filled: true, wide: true, action: onPrimary)
                if let secondary {
                    FormButton(title: secondary, filled: false, wide: true, action: onSecondary)
                }
            }
        }
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Poster.yellow)
    }

    private var namePrompt: String {
        switch fields.way {
        case .weighed: "OATS"
        case .whole: "FLAT WHITE"
        case .macros: "OLIVE OIL"
        }
    }

    /// One of the ways to type a food.
    private func way(_ way: TypedFields.Way) -> some View {
        let chosen = fields.way == way
        return Button {
            guard !chosen else { return }
            // The figures mean something else the other way round.
            fields.way = way
            fields.grams = ""
            fields.kcal = ""
            fields.protein = ""
            fields.carbs = ""
            fields.fat = ""
        } label: {
            Text(way.title)
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.6)
                .textCase(.uppercase)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .foregroundStyle(chosen ? Poster.yellow : Poster.ink)
                .background(chosen ? Poster.ink : .clear)
                .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// A button on a yellow form: filled for the thing to do, outlined for the
/// other.
struct FormButton: View {
    var title: String
    var filled: Bool
    var wide = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .heavy))
                .tracking(0.7)
                .textCase(.uppercase)
                .lineLimit(1)
                .frame(maxWidth: wide ? .infinity : nil)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .foregroundStyle(filled ? Poster.yellow : Poster.ink)
                .background(filled ? Poster.ink : .clear)
                .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 2.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// How many portions a recipe makes: one for a single meal, more for a
/// batch.
struct PortionStepper: View {
    @Binding var portions: Int

    var body: some View {
        HStack(spacing: 10) {
            Text("The recipe makes").posterLabel()
            Spacer(minLength: 0)
            step("−", by: -1)
            Text("\(portions)")
                .font(.system(size: 22, weight: .heavy))
                .monospacedDigit()
                .frame(minWidth: 30)
                .contentTransition(.numericText())
            step("+", by: 1)
            Text(portions == 1 ? "Portion" : "Portions").posterLabel().frame(
                width: 70, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The recipe makes \(portions) \(portions == 1 ? "portion" : "portions")")
        .accessibilityAdjustableAction { direction in
            adjust(by: direction == .increment ? 1 : -1)
        }
    }

    private func step(_ sign: String, by change: Int) -> some View {
        Button {
            adjust(by: change)
        } label: {
            Text(sign)
                .font(.system(size: 20, weight: .heavy))
                .frame(width: 38, height: 34)
                .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 2.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func adjust(by change: Int) {
        portions = min(MealDraft.maxPortions, max(1, portions + change))
    }
}
