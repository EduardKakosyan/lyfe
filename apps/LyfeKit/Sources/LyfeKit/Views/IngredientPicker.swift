import SwiftUI

struct CommonIngredient: Identifiable, Decodable {
    var symbol: String?
    var category: String?
    var icon: String { symbol ?? Self.icons[category ?? ""] ?? "🍽️" }
    let name: String
    let kcal, protein, carbs, fat: Double
    var id: String { name }

    init(_ icon: String, _ name: String, _ kcal: Double, _ protein: Double, _ carbs: Double, _ fat: Double) {
        self.symbol = icon
        self.category = switch icon {
        case "🐖": "Pork"
        case "🍗": "Poultry"
        case "🥩": "Beef"
        case "🐟": "Fish & seafood"
        case "🥚", "🥛", "🧀": "Dairy & eggs"
        case "🍚", "🍝", "🥣": "Grains & pasta"
        case "🫘": "Beans & legumes"
        case "🍌", "🍎", "🥑": "Fruit"
        case "🧈", "🫒": "Fats & oils"
        default: "Vegetables"
        }
        self.name = name
        self.kcal = kcal
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
    }

    static let icons = ["Dairy & eggs": "🥛", "Herbs & spices": "🌿", "Fats & oils": "🫒", "Poultry": "🍗",
                        "Soups & sauces": "🥣", "Deli meats": "🥓", "Fruit": "🍎", "Pork": "🐖", "Vegetables": "🥬",
                        "Nuts & seeds": "🥜", "Beef": "🥩", "Fish & seafood": "🐟", "Beans & legumes": "🫘",
                        "Other meats": "🍖", "Breads & baking": "🍞", "Sweets": "🍫", "Grains & pasta": "🌾"]

    static let library: [Self] = {
        guard let url = Bundle.module.url(forResource: "Ingredients", withExtension: "json"),
              let data = try? Data(contentsOf: url), let foods = try? JSONDecoder().decode([Self].self, from: data)
        else { return staples }
        let quickNames = Set(staples.map { $0.name.lowercased() })
        return staples + foods.filter { !quickNames.contains($0.name.lowercased()) }
    }()

    static func matches(query: String, category: String?) -> [Self] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        return library.filter { food in
            (category == nil || food.category == category) && terms.allSatisfy { food.name.lowercased().contains($0) }
        }
    }

    func weighed(_ grams: Double) -> Ingredient {
        var food = Ingredient(name: name, grams: grams, kcalPer100g: kcal, proteinPer100g: protein)
        food.carbsG = grams * carbs / 100
        food.fatG = grams * fat / 100
        return food
    }

    // Typical values per 100 g of the edible portion, prepared as named.
    static let staples: [Self] = [
        .init("🐖", "Pork tenderloin, roasted", 143, 26.2, 0, 3.5),
        .init("🍗", "Chicken breast, roasted", 165, 31, 0, 3.6),
        .init("🥩", "Ground beef, 90% lean, raw", 176, 20, 0, 10),
        .init("🐟", "Atlantic salmon, cooked", 206, 22.1, 0, 12.4),
        .init("🥚", "Egg, hard-boiled", 155, 12.6, 1.1, 10.6),
        .init("🍚", "White rice, cooked", 130, 2.7, 28.2, 0.3),
        .init("🍝", "Spaghetti, cooked", 158, 5.8, 30.9, 0.9),
        .init("🥣", "Rolled oats, dry", 379, 13.2, 67.7, 6.5),
        .init("🥔", "Potato, baked", 93, 2.5, 21.2, 0.1),
        .init("🫘", "Black beans, cooked", 132, 8.9, 23.7, 0.5),
        .init("🥦", "Broccoli, raw", 34, 2.8, 6.6, 0.4),
        .init("🥕", "Carrot, raw", 41, 0.9, 9.6, 0.2),
        .init("🍅", "Tomato, raw", 18, 0.9, 3.9, 0.2),
        .init("🍌", "Banana, peeled", 89, 1.1, 22.8, 0.3),
        .init("🍎", "Apple, with skin", 52, 0.3, 13.8, 0.2),
        .init("🥑", "Avocado, flesh", 160, 2, 8.5, 14.7),
        .init("🥛", "Whole milk", 61, 3.2, 4.8, 3.3),
        .init("🧀", "Cheddar cheese", 403, 24.9, 1.3, 33.1),
        .init("🧈", "Butter", 717, 0.9, 0.1, 81.1),
        .init("🫒", "Olive oil", 884, 0, 0, 100),
    ]
}

struct IngredientPicker: View {
    let add: (Ingredient) -> Void
    @State private var selection: CommonIngredient?
    @State private var grams = ""
    @State private var query = ""
    @State private var category: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Common ingredients").posterLabel()
            HStack {
                TextField("Search foods, e.g. pork loin", text: $query)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Search foods")
                Menu(category ?? "All foods") {
                    Button("All foods") { category = nil }
                    ForEach(CommonIngredient.icons.keys.sorted(), id: \.self) { group in
                        Button(group) { category = group }
                    }
                }
            }
            let matches = CommonIngredient.matches(query: query, category: category)
            Text(matches.isEmpty ? "No matches. Try a different search or type the food by hand." : "\(matches.count) foods · swipe to browse").posterLabel()
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top) {
                    ForEach(matches) { item in
                        Button {
                            selection = item
                            grams = ""
                        } label: {
                            VStack {
                                Text(item.icon).font(.largeTitle).accessibilityHidden(true)
                                Text(item.name).font(.caption.bold()).multilineTextAlignment(.center)
                            }.padding(6).frame(width: 112).background(selection?.id == item.id ? Poster.yellow : .clear)
                        }.buttonStyle(.plain)
                    }
                }
            }.id("\(category ?? "")/\(query)")
            if let selection {
                LabeledField(label: "\(selection.name) · grams", text: $grams, prompt: "100", numeric: true)
                let weight = FoodTyping.number(grams).flatMap { (0 < $0 && $0 <= 20_000) ? $0 : nil }
                if let weight {
                    let food = selection.weighed(weight)
                    Text("\(FoodText.plain(food.kcal)) kcal · \(FoodText.plain(food.proteinG)) g protein · \(FoodText.plain(food.carbsG ?? 0)) g carbs · \(FoodText.plain(food.fatG ?? 0)) g fat").posterLabel()
                }
                FormButton(title: "Add ingredient", filled: true) {
                    guard let weight else { return }
                    add(selection.weighed(weight))
                    self.selection = nil
                }.disabled(weight == nil)
            }
        }.padding(.horizontal, Poster.margin).padding(.vertical, 10)
            .onChange(of: query) { selection = nil }
            .onChange(of: category) { selection = nil }
    }
}
