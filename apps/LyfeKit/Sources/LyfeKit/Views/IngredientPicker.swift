import SwiftUI

/// A food in the ingredient catalogue: its figures per 100 g, and the
/// category it is browsed under.
struct CommonIngredient: Identifiable, Decodable {
    var category: String?
    let name: String
    let kcal, protein, carbs, fat: Double
    var id: String { name }

    init(_ category: String, _ name: String, _ kcal: Double, _ protein: Double, _ carbs: Double, _ fat: Double) {
        self.category = category
        self.name = name
        self.kcal = kcal
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
    }

    /// The catalogue's categories, each with the food its drawing shows.
    /// The Spark draws that as it draws any food's icon, by name, and a
    /// food is shown with its category's drawing until its own has been
    /// drawn.
    static let categoryPictures = [
        "Beans & legumes": "dried beans and green peas",
        "Beef": "raw beef steak",
        "Breads & baking": "bread",
        "Dairy & eggs": "milk, cheese and eggs",
        "Deli meats": "sliced salami and ham",
        "Fats & oils": "cooking oil and butter",
        "Fish & seafood": "fish and shrimp",
        "Fruit": "mixed fruit",
        "Grains & pasta": "dry pasta and grains",
        "Herbs & spices": "fresh herbs and ground spices",
        "Nuts & seeds": "mixed nuts",
        "Other meats": "lamb chops",
        "Pork": "raw pork chop",
        "Poultry": "roast chicken",
        "Soups & sauces": "soup",
        "Sweets": "chocolate and sweets",
        "Vegetables": "mixed vegetables",
    ]

    static let categories = categoryPictures.keys.sorted()

    /// What this food's category is drawn as; nil for a food in none.
    var categoryPicture: String? { category.flatMap { Self.categoryPictures[$0] } }

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
        .init("Pork", "Pork tenderloin, roasted", 143, 26.2, 0, 3.5),
        .init("Poultry", "Chicken breast, roasted", 165, 31, 0, 3.6),
        .init("Beef", "Ground beef, 90% lean, raw", 176, 20, 0, 10),
        .init("Fish & seafood", "Atlantic salmon, cooked", 206, 22.1, 0, 12.4),
        .init("Dairy & eggs", "Egg, hard-boiled", 155, 12.6, 1.1, 10.6),
        .init("Grains & pasta", "White rice, cooked", 130, 2.7, 28.2, 0.3),
        .init("Grains & pasta", "Spaghetti, cooked", 158, 5.8, 30.9, 0.9),
        .init("Grains & pasta", "Rolled oats, dry", 379, 13.2, 67.7, 6.5),
        .init("Vegetables", "Potato, baked", 93, 2.5, 21.2, 0.1),
        .init("Beans & legumes", "Black beans, cooked", 132, 8.9, 23.7, 0.5),
        .init("Vegetables", "Broccoli, raw", 34, 2.8, 6.6, 0.4),
        .init("Vegetables", "Carrot, raw", 41, 0.9, 9.6, 0.2),
        .init("Vegetables", "Tomato, raw", 18, 0.9, 3.9, 0.2),
        .init("Fruit", "Banana, peeled", 89, 1.1, 22.8, 0.3),
        .init("Fruit", "Apple, with skin", 52, 0.3, 13.8, 0.2),
        .init("Fruit", "Avocado, flesh", 160, 2, 8.5, 14.7),
        .init("Dairy & eggs", "Whole milk", 61, 3.2, 4.8, 3.3),
        .init("Dairy & eggs", "Cheddar cheese", 403, 24.9, 1.3, 33.1),
        .init("Fats & oils", "Butter", 717, 0.9, 0.1, 81.1),
        .init("Fats & oils", "Olive oil", 884, 0, 0, 100),
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
                    ForEach(CommonIngredient.categories, id: \.self) { group in
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
                            // The icon is drawn on the app's paper, so the
                            // tile it is on stays paper: the one picked is
                            // marked by its name and an ink frame.
                            VStack(spacing: 4) {
                                FoodIconView(food: item).frame(width: 72, height: 72)
                                Text(item.name).font(.caption.bold()).multilineTextAlignment(.center)
                                    .padding(.horizontal, 3)
                                    .background(selection?.id == item.id ? Poster.yellow : .clear)
                            }
                            .padding(6).frame(width: 112)
                            .overlay {
                                if selection?.id == item.id { Rectangle().strokeBorder(Poster.ink, lineWidth: 2.5) }
                            }
                            .contentShape(Rectangle())
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
