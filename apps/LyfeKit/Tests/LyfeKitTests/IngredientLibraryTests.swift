import Testing

@testable import LyfeKit

@Test func bundledFoodsAreSearchableByPreparationAndCategory() {
    let foods = CommonIngredient.library
    #expect(foods.count > 3700)
    #expect(Set(foods.map(\.id)).count == foods.count)
    let matches = CommonIngredient.matches(query: " RAW  spinach ", category: "Vegetables")
    #expect(matches.contains { $0.name == "Spinach, raw" && $0.weighed(200).kcal == 46 })
    #expect(CommonIngredient.matches(query: "spinach", category: "Pork").isEmpty)
}
