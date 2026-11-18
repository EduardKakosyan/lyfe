import Foundation

/// The logging prompt, as the backend names it. It has nothing to type
/// into; the name is what lets a tap on it open the Food screen.
public enum FoodPrompt {
    public static let category = "FOOD_LOG"
}

/// One tap on a saved meal, as it is kept on this phone and sent.
public struct MealTap: Codable, Equatable, Sendable, Identifiable {
    /// Made here when the meal is tapped, so sending it twice logs it once.
    public var id: UUID
    public var eatenAt: Date
    public var mealId: UUID
    /// Portions of the meal; one unless another was chosen.
    public var servings: Double
    /// The meal as it stood when tapped, to show while the tap waits to be
    /// sent. The backend works out the figures it stores.
    public var name: String
    public var slot: MealSlot
    public var kcal: Int
    public var proteinG: Double

    public init(id: UUID = UUID(), eatenAt: Date, meal: SavedMeal, servings: Double = 1) {
        self.id = id
        self.eatenAt = eatenAt
        mealId = meal.id
        self.servings = servings
        name = meal.name
        slot = meal.slot
        kcal = Int((Double(meal.kcal) * servings).rounded())
        proteinG = (meal.proteinG * servings * 10).rounded() / 10
    }
}

/// Meals tapped on this phone that the backend has not confirmed yet.
///
/// A tap is written here before anything is sent, so a meal logged with no
/// connection is not lost, and still counts for the day it was eaten on.
/// It stays until the backend has answered for it.
public struct FoodStore: Sendable {
    private let file: URL

    public init(directory: URL) {
        file = directory.appending(path: "food-outbox.json")
    }

    /// The app's own Application Support folder.
    public static func standard() -> FoodStore {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return FoodStore(directory: base.appending(path: "lyfe"))
    }

    /// Oldest first.
    public func outbox() -> [MealTap] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? Self.decoder.decode([MealTap].self, from: data)) ?? []
    }

    public func enqueue(_ tap: MealTap) {
        var all = outbox()
        guard !all.contains(where: { $0.id == tap.id }) else { return }
        all.append(tap)
        write(all)
    }

    /// Called once the backend has answered for a tap, or the owner took
    /// it back before it was sent.
    public func remove(_ id: UUID) {
        let rest = outbox().filter { $0.id != id }
        if rest.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else {
            write(rest)
        }
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private func write(_ all: [MealTap]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(all) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// What became of a tap on a saved meal.
public enum MealLogOutcome: Equatable, Sendable {
    /// The backend has it.
    case sent
    /// Kept on this phone; sent when the backend can be reached.
    case saved
    /// The backend would not take it; nothing was kept.
    case refused
}

/// Something typed that cannot be what it was meant to be, in words for
/// the owner.
public struct FoodSlip: Error, Equatable, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// One part of a meal being built on this phone.
public struct MealPart: Codable, Equatable, Sendable, Identifiable {
    /// Made here, so the part is logged once however often it is sent.
    public var id: UUID
    public var kind: Kind

    public enum Kind: Codable, Equatable, Sendable {
        /// Its figures are known here: typed, weighed or whole; scanned,
        /// with its label found; or a saved meal's fixed estimate.
        case food(Ingredient)
        /// Scanned without a connection, so its label is not known here.
        /// It is looked up when the meal is sent.
        case scan(code: String, grams: Double)
        /// A photo and one line, sent to be estimated while the meal is
        /// built. The photo is kept beside the captures under this id.
        case photo(note: String, hasPhoto: Bool)
    }

    public init(id: UUID = UUID(), _ kind: Kind) {
        self.id = id
        self.kind = kind
    }

    /// A scanned food: with its label when this phone or the backend
    /// knows the code, to be looked up later when neither could say.
    public static func scanned(code: String, grams: Double, product: Product?) -> MealPart {
        guard let product else { return MealPart(.scan(code: code, grams: grams)) }
        return MealPart(
            .food(
                Ingredient(
                    name: product.name, grams: grams, kcalPer100g: product.kcalPer100g,
                    proteinPer100g: product.proteinPer100g, code: code)))
    }

    public var name: String {
        switch kind {
        case .food(let food): return food.name
        case .scan(let code, _): return "Barcode \(code)"
        case .photo(let note, _):
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Photo meal" : trimmed
        }
    }

    /// As something that goes into a saved meal, once its figures are
    /// known. `estimate` is the backend's entry for a photo part.
    public func ingredient(estimate: FoodDay.Entry?) -> Ingredient? {
        switch kind {
        case .food(let food): food
        case .scan: nil
        case .photo: estimate?.asIngredient
        }
    }
}

/// A meal while it is being built: logged now from its parts, saved for
/// one tap next time, or both. Also a saved meal being changed.
public struct MealDraft: Codable, Equatable, Sendable, Identifiable {
    /// The logged meal's id, made here so logging it twice logs it once.
    /// Photos are sent ahead as parts of the meal with this id.
    public var id: UUID
    /// The saved meal's id: made here for a new one, so saving it twice
    /// stores it once; the meal's own when this changes a saved meal.
    public var mealId: UUID
    /// False when this changes a meal that is already saved.
    public var isNew: Bool
    public var purpose: Purpose
    public var name: String
    public var slot: MealSlot
    /// Portions the recipe makes. One for a meal built to be eaten now.
    public var portions: Int
    public var parts: [MealPart]
    /// True once it has been saved for one tap in this sitting.
    public var isSaved: Bool
    public var startedAt: Date

    public enum Purpose: String, Codable, Sendable {
        /// Built to be logged now; it can be saved for one tap as well.
        case log
        /// A saved meal typed or changed. It is saved, not logged.
        case recipe
    }

    public static let maxPortions = 50
    public static let maxParts = 40
    public static let maxNameLength = 60

    /// A new meal with nothing in it yet.
    public init(id: UUID = UUID(), slot: MealSlot = .breakfast, purpose: Purpose = .recipe, startedAt: Date = Date()) {
        self.id = id
        mealId = UUID()
        isNew = true
        self.purpose = purpose
        name = ""
        self.slot = slot
        portions = 1
        parts = []
        isSaved = false
        self.startedAt = startedAt
    }

    /// A saved meal, to change its recipe.
    public init(editing meal: SavedMeal) {
        self.init(slot: meal.slot)
        mealId = meal.id
        isNew = false
        name = meal.name
        portions = meal.portions
        parts = meal.ingredients.map { MealPart(.food($0)) }
    }

    /// A meal already logged from parts, to save it for one tap. Nil
    /// until every part's figures are known.
    public init?(saving meal: FoodDay.Entry) {
        guard let parts = meal.parts, !parts.isEmpty else { return nil }
        let ingredients = parts.compactMap(\.asIngredient)
        guard ingredients.count == parts.count else { return nil }
        self.init(slot: meal.slot)
        name = meal.name
        self.parts = ingredients.map { MealPart(.food($0)) }
    }

    /// What the meal is called when logged without a name: its part of
    /// the day.
    public var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? slot.title : trimmed
    }

    /// What the parts add up to so far.
    public struct Total: Equatable, Sendable {
        public var kcal: Int
        public var proteinG: Double
        /// The kcal of it that are estimated.
        public var kcalEstimated: Int
        /// Parts whose figures are not known yet: left out, not zero.
        public var unknown: Int
    }

    /// The meal as it would be logged now: each part rounded as the
    /// backend rounds it, then added up. `estimates` are the backend's
    /// entries for the photo parts, by part.
    public func total(estimates: [UUID: FoodDay.Entry] = [:]) -> Total {
        var total = Total(kcal: 0, proteinG: 0, kcalEstimated: 0, unknown: 0)
        var proteinDg = 0
        for part in parts {
            guard let food = part.ingredient(estimate: estimates[part.id]) else {
                total.unknown += 1
                continue
            }
            let kcal = Int(food.kcal.rounded())
            total.kcal += kcal
            proteinDg += Int((food.proteinG * 10).rounded())
            if food.estimated { total.kcalEstimated += kcal }
        }
        total.proteinG = Double(proteinDg) / 10
        return total
    }

    /// The parts as a saved meal's ingredients; nil while any part's
    /// figures are not known.
    public func ingredients(estimates: [UUID: FoodDay.Entry] = [:]) -> [Ingredient]? {
        let known = parts.compactMap { $0.ingredient(estimate: estimates[$0.id]) }
        return known.count == parts.count ? known : nil
    }

    /// What one portion comes to, shown while the recipe is typed so a
    /// slipped figure stands out. The backend's figure is the one kept.
    public func portion(estimates: [UUID: FoodDay.Entry] = [:]) -> (kcal: Int, proteinG: Double) {
        let share = 1 / Double(max(portions, 1))
        let known = parts.compactMap { $0.ingredient(estimate: estimates[$0.id]) }
        let kcal = known.reduce(0) { $0 + $1.kcal }
        let protein = known.reduce(0) { $0 + $1.proteinG }
        return (Int((kcal * share).rounded()), (protein * share * 10).rounded() / 10)
    }

    /// What one ingredient adds to the whole recipe, in kcal.
    public static func kcal(of ingredient: Ingredient) -> Int {
        Int(ingredient.kcal.rounded())
    }

    /// What still stops the meal being saved for one tap; nil when
    /// nothing does.
    public func missing(estimates: [UUID: FoodDay.Entry] = [:]) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Give the meal a name" }
        if trimmed.count > Self.maxNameLength { return "The name is too long" }
        if parts.isEmpty { return "Add what goes into it" }
        if ingredients(estimates: estimates) == nil { return "A part's figures are not known yet" }
        return nil
    }
}

extension MealSlot {
    /// What a meal with no name of its own is called.
    public var title: String {
        switch self {
        case .breakfast: "Breakfast"
        case .lunch: "Lunch"
        case .dinner: "Dinner"
        case .snack: "Snack"
        }
    }
}

/// The meal being built on this phone, kept so that leaving lyfe half way
/// through does not lose what was scanned.
public struct DraftStore: Sendable {
    private let file: URL

    public init(directory: URL) {
        file = directory.appending(path: "meal-draft.json")
    }

    public static func standard() -> DraftStore {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return DraftStore(directory: base.appending(path: "lyfe"))
    }

    public func load() -> MealDraft? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(MealDraft.self, from: data)
    }

    /// Keeps the meal, or forgets it when there is none.
    public func save(_ draft: MealDraft?) {
        guard let draft else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(draft) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Reading what is typed into the meal editor and the targets entry. The
/// limits are the backend's; a slip is caught here first so it can be said
/// next to the field it was typed in.
public enum FoodTyping {
    /// A plain figure: "80", "13,2", " 379 ". Nil for anything else.
    public static func number(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = cleaned.wholeMatch(of: /[0-9]{1,5}(?:[.,][0-9]{1,2})?/) else { return nil }
        return Double(match.0.replacingOccurrences(of: ",", with: "."))
    }

    /// The four fields of the ingredient form as an ingredient, or the
    /// first thing wrong with them.
    public static func ingredient(name: String, grams: String, kcal: String, protein: String)
        -> Result<Ingredient, FoodSlip>
    {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(FoodSlip("Name it")) }
        guard name.count <= MealDraft.maxNameLength else { return .failure(FoodSlip("That name is too long")) }
        guard let grams = number(grams), grams > 0, grams <= 20_000 else {
            return .failure(FoodSlip("Type its weight in grams, like 80"))
        }
        guard let kcal = number(kcal), kcal <= 900 else {
            return .failure(FoodSlip("Type the kcal in 100 g from the label, 0 to 900"))
        }
        guard let protein = number(protein), protein <= 100 else {
            return .failure(FoodSlip("Type the protein in 100 g from the label, 0 to 100"))
        }
        return .success(Ingredient(name: name, grams: grams, kcalPer100g: kcal, proteinPer100g: protein))
    }

    /// The three fields of a food typed whole: what it is and what it
    /// comes to, as a menu gives it. Or the first thing wrong with them.
    public static func whole(name: String, kcal: String, protein: String) -> Result<Ingredient, FoodSlip> {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(FoodSlip("Name it")) }
        guard name.count <= MealDraft.maxNameLength else { return .failure(FoodSlip("That name is too long")) }
        guard let kcal = number(kcal), kcal <= 10_000 else {
            return .failure(FoodSlip("Type the kcal it comes to, 0 to 10000"))
        }
        guard let protein = number(protein), protein <= 1000 else {
            return .failure(FoodSlip("Type the protein it comes to in grams, 0 to 1000"))
        }
        return .success(Ingredient(name: name, kcal: kcal, proteinG: protein))
    }

    /// The two fields of the targets entry, or the first thing wrong.
    public static func targets(kcal: String, protein: String) -> Result<FoodTargets, FoodSlip> {
        guard let kcal = number(kcal), kcal == kcal.rounded(), (800...10_000).contains(kcal) else {
            return .failure(FoodSlip("Type the calories for a day, 800 to 10000"))
        }
        guard let protein = number(protein), protein == protein.rounded(), (20...500).contains(protein) else {
            return .failure(FoodSlip("Type the protein for a day in grams, 20 to 500"))
        }
        return .success(FoodTargets(kcal: Int(kcal), proteinG: Int(protein)))
    }
}

/// The calorie and protein targets as typed.
public struct FoodTargets: Equatable, Sendable {
    public var kcal: Int
    public var proteinG: Int

    public init(kcal: Int, proteinG: Int) {
        self.kcal = kcal
        self.proteinG = proteinG
    }
}
