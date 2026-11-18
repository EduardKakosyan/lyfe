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

/// A saved meal while it is being typed: a new one, or a saved one being
/// changed.
public struct MealDraft: Equatable, Sendable, Identifiable {
    /// Made here for a new meal, so saving it twice stores it once.
    public var id: UUID
    /// False when this changes a meal that is already saved.
    public var isNew: Bool
    public var name: String
    public var slot: MealSlot
    /// Portions the weighed recipe makes.
    public var portions: Int
    public var ingredients: [Ingredient]

    public static let maxPortions = 50
    public static let maxIngredients = 40
    public static let maxNameLength = 60

    /// A new meal with nothing in it yet.
    public init(id: UUID = UUID(), slot: MealSlot = .breakfast) {
        self.id = id
        isNew = true
        name = ""
        self.slot = slot
        portions = 1
        ingredients = []
    }

    /// A saved meal, to change its recipe.
    public init(editing meal: SavedMeal) {
        id = meal.id
        isNew = false
        name = meal.name
        slot = meal.slot
        portions = meal.portions
        ingredients = meal.ingredients
    }

    /// What one portion comes to, shown while the recipe is typed so a
    /// slipped figure stands out. The backend's figure is the one kept.
    public var portion: (kcal: Int, proteinG: Double) {
        let share = 1 / Double(max(portions, 1))
        let kcal = ingredients.reduce(0) { $0 + $1.grams * $1.kcalPer100g / 100 }
        let protein = ingredients.reduce(0) { $0 + $1.grams * $1.proteinPer100g / 100 }
        return (Int((kcal * share).rounded()), (protein * share * 10).rounded() / 10)
    }

    /// What one ingredient adds to the whole recipe, in kcal.
    public static func kcal(of ingredient: Ingredient) -> Int {
        Int((ingredient.grams * ingredient.kcalPer100g / 100).rounded())
    }

    /// What still stops the meal being saved; nil when nothing does.
    public var missing: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Give the meal a name" }
        if trimmed.count > Self.maxNameLength { return "The name is too long" }
        if ingredients.isEmpty { return "Add what goes into it" }
        return nil
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
        guard !name.isEmpty else { return .failure(FoodSlip("Name the ingredient")) }
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
