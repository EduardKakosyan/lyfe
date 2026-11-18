import SwiftUI

/// The meal editor: a saved meal typed once from weighed ingredients and
/// the figures on their labels. The bar shows what one portion comes to
/// as the recipe grows, so a slipped figure stands out before it is saved.
public struct MealEditorView: View {
    let onSave: (MealDraft) async -> String?
    let onRemove: (UUID) async -> String?
    let onClose: () -> Void

    @State private var draft: MealDraft
    /// The ingredient form.
    @State private var name = ""
    @State private var grams = ""
    @State private var kcal = ""
    @State private var protein = ""
    /// The ingredient the form is changing; nil while it adds a new one.
    @State private var changing: Int?
    @State private var note: String?
    @State private var saving = false
    @State private var confirmingRemove = false
    @FocusState private var focus: Field?

    enum Field {
        case meal, name, grams, kcal, protein
    }

    public init(
        start: MealDraft, onSave: @escaping (MealDraft) async -> String?,
        onRemove: @escaping (UUID) async -> String?, onClose: @escaping () -> Void
    ) {
        _draft = State(initialValue: start)
        self.onSave = onSave
        self.onRemove = onRemove
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    PosterRule()
                    ForEach(Array(draft.ingredients.enumerated()), id: \.offset) { index, ingredient in
                        Button {
                            change(index)
                        } label: {
                            FoodRow(
                                row: .init(
                                    id: "ingredient-\(index)", entry: nil, mark: changing == index ? .striped : .solid,
                                    title: ingredient.name, label: FoodText.ingredientLabel(ingredient),
                                    value: FoodText.kcal(MealDraft.kcal(of: ingredient))))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Changes this ingredient")
                        PosterRule(thickness: 1.5)
                    }
                    form
                    PosterRule()
                    if let note {
                        NoticeRow(text: note)
                        PosterRule(thickness: 1.5)
                    }
                    if !draft.isNew {
                        Button {
                            confirmingRemove = true
                        } label: {
                            Text("Remove this meal").posterLabel().opacity(0.55)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            let bar = FoodText.editorBar(draft, saving: saving)
            Button {
                Task { await save() }
            } label: {
                BreathBar(small: bar.small, big: bar.big, mark: "→", onDark: false)
            }
            .buttonStyle(.plain)
            .allowsHitTesting(!saving)
        }
        .foregroundStyle(Poster.ink)
        .background(Poster.paper.ignoresSafeArea())
        .onAppear {
            if draft.isNew { focus = .meal }
        }
        .confirmationDialog(
            "Remove \(draft.name) from your saved meals?", isPresented: $confirmingRemove, titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task { note = await onRemove(draft.id) }
            }
        } message: {
            Text("What you logged from it stays.")
        }
    }

    /// The meal itself: its name, when it is eaten, and how many portions
    /// the weighed recipe makes.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Text("✕ Close").posterLabel().padding(.vertical, 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text(draft.isNew ? "New saved meal" : "Saved meal").posterLabel()
            }
            TextField("", text: $draft.name, prompt: Text("MEAL NAME").foregroundStyle(Poster.ink.opacity(0.25)))
                .font(.system(size: 34, weight: .heavy))
                .tracking(-1)
                .focused($focus, equals: .meal)
                .submitLabel(.next)
                .onSubmit { focus = .name }
                #if os(iOS)
                    .textInputAutocapitalization(.characters)
                #endif
                .autocorrectionDisabled()
                .accessibilityLabel("Meal name")
            HStack(spacing: 6) {
                ForEach(MealSlot.allCases, id: \.self) { slot in
                    Button {
                        draft.slot = slot
                    } label: {
                        Text(FoodText.slotName(slot))
                            .font(.system(size: 11, weight: .heavy))
                            .tracking(0.7)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundStyle(draft.slot == slot ? Poster.paper : Poster.ink)
                            .background(draft.slot == slot ? Poster.ink : .clear)
                            .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 2.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(draft.slot == slot ? .isSelected : [])
                }
            }
            .padding(.top, 10)
            HStack(spacing: 10) {
                Text("The recipe makes").posterLabel()
                Spacer(minLength: 0)
                step("−", by: -1)
                Text("\(draft.portions)")
                    .font(.system(size: 22, weight: .heavy))
                    .monospacedDigit()
                    .frame(minWidth: 30)
                    .contentTransition(.numericText())
                step("+", by: 1)
                Text(draft.portions == 1 ? "Portion" : "Portions").posterLabel().frame(width: 70, alignment: .leading)
            }
            .padding(.top, 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("The recipe makes \(draft.portions) \(draft.portions == 1 ? "portion" : "portions")")
            .accessibilityAdjustableAction { direction in
                adjust(by: direction == .increment ? 1 : -1)
            }
        }
        .padding(.horizontal, Poster.margin)
        .padding(.bottom, 12)
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
        draft.portions = min(MealDraft.maxPortions, max(1, draft.portions + change))
    }

    /// The ingredient form, in yellow: what it is, what it weighed, and
    /// the two figures from its label.
    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(changing == nil ? "Add what goes into it" : "Change this ingredient").posterLabel()
            field("Ingredient", text: $name, prompt: "OATS", field: .name, next: .grams)
            HStack(alignment: .bottom, spacing: 6) {
                field("Weighed · g", text: $grams, prompt: "80", field: .grams, next: .kcal, numeric: true)
                field("kcal per 100 g", text: $kcal, prompt: "379", field: .kcal, next: .protein, numeric: true)
                field("Protein per 100 g", text: $protein, prompt: "13.2", field: .protein, next: nil, numeric: true)
            }
            HStack(spacing: 6) {
                Button {
                    add()
                } label: {
                    Text(changing == nil ? "Add" : "Keep the change")
                        .font(.system(size: 12, weight: .heavy))
                        .tracking(0.7)
                        .textCase(.uppercase)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(Poster.yellow)
                        .background(Poster.ink)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let changing {
                    Button {
                        draft.ingredients.remove(at: changing)
                        clearForm()
                    } label: {
                        Text("Take it out")
                            .font(.system(size: 12, weight: .heavy))
                            .tracking(0.7)
                            .textCase(.uppercase)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 2.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Poster.yellow)
    }

    private func field(
        _ label: String, text: Binding<String>, prompt: String, field: Field, next: Field?, numeric: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).posterLabel().lineLimit(1).minimumScaleFactor(0.7)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(Poster.ink.opacity(0.3)))
                .font(.system(size: 17, weight: .heavy))
                .monospacedDigit()
                .focused($focus, equals: field)
                .submitLabel(next == nil ? .done : .next)
                .onSubmit {
                    if let next { focus = next } else { add() }
                }
                #if os(iOS)
                    .keyboardType(numeric ? .decimalPad : .default)
                    .textInputAutocapitalization(.words)
                #endif
                .autocorrectionDisabled()
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(Poster.paper)
                .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 2.5))
                .accessibilityLabel(label)
        }
    }

    /// Loads an ingredient back into the form to change or take out.
    private func change(_ index: Int) {
        let ingredient = draft.ingredients[index]
        changing = index
        name = ingredient.name
        grams = FoodText.plain(ingredient.grams)
        kcal = FoodText.plain(ingredient.kcalPer100g)
        protein = FoodText.plain(ingredient.proteinPer100g)
        note = nil
    }

    private var formIsEmpty: Bool {
        [name, grams, kcal, protein].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Takes what is in the form into the recipe. False when it does not
    /// read as an ingredient; the note then says why.
    @discardableResult
    private func add() -> Bool {
        switch FoodTyping.ingredient(name: name, grams: grams, kcal: kcal, protein: protein) {
        case .success(let ingredient):
            if let changing, draft.ingredients.indices.contains(changing) {
                draft.ingredients[changing] = ingredient
            } else if draft.ingredients.count < MealDraft.maxIngredients {
                draft.ingredients.append(ingredient)
            } else {
                note = "A meal takes \(MealDraft.maxIngredients) ingredients at most."
                return false
            }
            clearForm()
            focus = .name
            return true
        case .failure(let slip):
            note = slip.message + "."
            return false
        }
    }

    private func clearForm() {
        changing = nil
        name = ""
        grams = ""
        kcal = ""
        protein = ""
        note = nil
    }

    private func save() async {
        // An ingredient typed but not yet added is taken in, not lost.
        if !formIsEmpty, !add() { return }
        saving = true
        defer { saving = false }
        focus = nil
        note = await onSave(draft)
    }
}

/// The targets entry: calories and protein for a day, typed by the owner.
/// lyfe holds each day to them and never changes them by itself.
public struct FoodTargetsView: View {
    let current: FoodDay.Target?
    let today: CalendarDay
    let onSave: (FoodTargets) async -> String?
    let onClose: () -> Void

    @State private var kcal: String
    @State private var protein: String
    @State private var note: String?
    @State private var saving = false
    @FocusState private var focus: Field?

    enum Field {
        case kcal, protein
    }

    public init(
        current: FoodDay.Target?, today: CalendarDay, onSave: @escaping (FoodTargets) async -> String?,
        onClose: @escaping () -> Void
    ) {
        self.current = current
        self.today = today
        self.onSave = onSave
        self.onClose = onClose
        _kcal = State(initialValue: current.map { String($0.kcal) } ?? "")
        _protein = State(initialValue: current.map { String($0.proteinG) } ?? "")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Text("✕ Close").posterLabel().padding(.vertical, 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Targets · \(today.posterLabel)").posterLabel()
            }
            .padding(.horizontal, Poster.margin)

            figure($kcal, prompt: "0", size: 110, field: .kcal, label: "Calories a day")
                .padding(.top, 12)
            Text("kcal a day").posterHeading(26).padding(.horizontal, Poster.margin)
            figure($protein, prompt: "0", size: 72, field: .protein, label: "Protein a day in grams")
                .padding(.top, 14)
            Text("g protein a day").posterHeading(26).padding(.horizontal, Poster.margin)
            Text(note ?? FoodText.targetsNow(current))
                .posterLabel()
                .padding(.horizontal, Poster.margin)
                .padding(.top, 12)
            Text("Counts from today. Earlier days keep the target they had.")
                .posterLabel()
                .opacity(0.55)
                .padding(.horizontal, Poster.margin)
                .padding(.top, 4)
            Spacer(minLength: 0)
            Button {
                Task { await save() }
            } label: {
                BreathBar(
                    small: "Yours to set · lyfe never changes them", big: saving ? "SAVING" : "SAVE TARGETS",
                    mark: "→", onDark: false)
            }
            .buttonStyle(.plain)
            .allowsHitTesting(!saving)
        }
        .foregroundStyle(Poster.ink)
        .background(Poster.paper.ignoresSafeArea())
        .onAppear { focus = .kcal }
    }

    private func figure(_ text: Binding<String>, prompt: String, size: CGFloat, field: Field, label: String) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(Poster.ink.opacity(0.2)))
            .font(.system(size: size, weight: .heavy))
            .tracking(-size * 0.05)
            .monospacedDigit()
            .minimumScaleFactor(0.5)
            .focused($focus, equals: field)
            #if os(iOS)
                .keyboardType(.numberPad)
            #endif
            .padding(.horizontal, Poster.margin - 4)
            .accessibilityLabel(label)
    }

    private func save() async {
        switch FoodTyping.targets(kcal: kcal, protein: protein) {
        case .failure(let slip):
            note = slip.message + "."
        case .success(let targets):
            saving = true
            defer { saving = false }
            note = await onSave(targets)
        }
    }
}
