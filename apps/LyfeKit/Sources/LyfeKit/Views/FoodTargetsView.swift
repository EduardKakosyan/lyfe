import SwiftUI

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
