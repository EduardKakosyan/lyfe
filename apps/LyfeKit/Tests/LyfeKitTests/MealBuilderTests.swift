import Foundation
import Testing

@testable import LyfeKit


@Test func weighedStapleKeepsMacrosWhenSavedAndReweighed() throws {
    let pork = try #require(CommonIngredient.staples.first { $0.name.contains("Pork") })
    let food = pork.weighed(150)
    #expect(food.kcal == 214.5)
    #expect(food.carbsG == 0)
    #expect(food.fatG == 5.25)
    let restored = try JSONDecoder().decode(Ingredient.self, from: JSONEncoder().encode(food))
    var fields = TypedFields(restored)
    fields.grams = "200"
    let changed = try fields.read().get()
    #expect(changed.fatG == 7)
    #expect(changed.carbsG == 0)
    #expect(FoodText.macros(carbs: [0, nil], fat: [nil, nil]) == "Carbs 0 g recorded · Fat —")
}

/// Meals built from parts, in exactly the shape the backend sends them: a
/// breakfast of a scanned bar, a typed banana, a coffee typed whole and a
/// photo, and a photo sent ahead of a meal still being built.
enum BuiltFixture {
    static let mealID = UUID(uuidString: "00000000-0000-4000-9000-000000000030")!
    static let barID = UUID(uuidString: "00000000-0000-4000-9000-000000000031")!
    static let photoID = UUID(uuidString: "00000000-0000-4000-9000-000000000034")!

    /// The photo of eggs on toast, as an entry: a part, or sent ahead.
    static func photo(_ figures: String = "known") -> String {
        let known = figures == "known"
        return """
            {"id": "00000000-0000-4000-9000-000000000034", "slot": "breakfast", "name": "eggs on toast",
             "meal_id": null, "servings": 1.0, "kcal": \(known ? 578 : 0), "protein_g": \(known ? 33.0 : 0.0),
             "source": "photo", "figures": "\(figures)", "estimated": true
             \(known ? #", "kcal_estimated": 578, "kcal_low": 380, "kcal_high": 780"# : ""),
             "photo": {"note": "eggs on toast", "has_photo": true,
                       "items": [\(known ? #"{"name": "Eggs", "grams": 100.0, "grams_seen": 100.0, "kcal": 458, "protein_g": 33.0}"# : "")],
                       "oil_asked": \(known), "oil": null, "oil_counted": "\(known ? "some" : "none")",
                       "oil_kcal": \(known ? 120 : 0), "typed": false, "problem": null}}
            """
    }

    static func meal(photo figures: String = "known") -> String {
        let known = figures == "known"
        return """
            {"id": "00000000-0000-4000-9000-000000000030", "slot": "breakfast", "name": "Breakfast", "meal_id": null,
             "servings": 1.0, "kcal": \(known ? 1015 : 437), "protein_g": \(known ? 60.1 : 27.1), "source": "built",
             "figures": "\(figures)", "estimated": true
             \(known ? #", "kcal_estimated": 578, "kcal_low": 817, "kcal_high": 1217"# : ""),
             "parts": [
               {"id": "00000000-0000-4000-9000-000000000031", "slot": "breakfast", "name": "Protein bar",
                "meal_id": null, "servings": 1.0, "kcal": 210, "protein_g": 19.8, "source": "barcode",
                "figures": "known", "estimated": false, "barcode": {"code": "96385074", "grams": 60.0},
                "weighed": {"grams": 60.0, "kcal_per_100g": 350.0, "protein_per_100g": 33.0}},
               {"id": "00000000-0000-4000-9000-000000000032", "slot": "breakfast", "name": "Banana", "meal_id": null,
                "servings": 1.0, "kcal": 107, "protein_g": 1.3, "source": "typed", "figures": "known",
                "estimated": false, "weighed": {"grams": 120.0, "kcal_per_100g": 89.0, "protein_per_100g": 1.1}},
               {"id": "00000000-0000-4000-9000-000000000033", "slot": "breakfast", "name": "Flat white",
                "meal_id": null, "servings": 1.0, "kcal": 120, "protein_g": 6.0, "source": "typed", "figures": "known",
                "estimated": false},
               \(photo(figures))]}
            """
    }

    /// A saved meal with a photo's estimate among its ingredients.
    static let cafe = """
        {"id": "00000000-0000-4000-9000-000000000003", "name": "Café breakfast", "slot": "breakfast", "portions": 1,
         "kcal": 423, "protein_g": 48.3, "kcal_estimated": 192,
         "ingredients": [
           {"name": "Greek yogurt", "grams": 175.0, "kcal_per_100g": 63.0, "protein_per_100g": 11.0, "code": "064200115896"},
           {"name": "Flat white", "kcal": 120.0, "protein_g": 6.0},
           {"name": "Eggs on toast", "kcal": 192.4, "protein_g": 23.0, "estimated": true}]}
        """

    /// Food with these entries and photos sent ahead.
    static func food(entries: [String] = [], drafts: [String] = [], meals: [String] = []) -> String {
        """
        {"day": "2026-11-17", "target": {"since": "2026-11-02", "kcal": 2500, "protein_g": 170},
         "kcal": 0, "protein_g": 0.0, "kcal_left": 2500, "protein_left_g": 170.0,
         "open_slots": ["lunch", "dinner"], "entries": [\(entries.joined(separator: ","))],
         "drafts": [\(drafts.joined(separator: ","))], "meals": [\(meals.joined(separator: ","))],
         "streak": {"days": 1, "state": "kept", "previous_best": 0, "logged_today": true,
                    "last_days": [{"date": "2026-11-17", "state": "kept"}]}}
        """
    }

    static func day(entries: [String] = [], drafts: [String] = [], meals: [String] = []) -> FoodDay {
        try! JSONDecoder.lyfe.decode(FoodDay.self, from: Data(food(entries: entries, drafts: drafts, meals: meals).utf8))
    }

    static func home(entries: [String] = [], drafts: [String] = [], meals: [String] = []) -> StubBackend.Reply {
        .ok(Fixture.home(food: food(entries: entries, drafts: drafts, meals: meals)))
    }

    static let bar = Product(
        code: "96385074", name: "Protein bar", kcalPer100g: 350, proteinPer100g: 33, servingG: 60, origin: "database")
    static let banana = Ingredient(name: "Banana", grams: 120, kcalPer100g: 89, proteinPer100g: 1.1)
    static let coffee = Ingredient(name: "Flat white", kcal: 120, proteinG: 6)
}

@Suite struct BuiltMealModelTests {
    @Test func aMealBuiltFromPartsReads() throws {
        let food = BuiltFixture.day(entries: [BuiltFixture.meal()], meals: [BuiltFixture.cafe])
        let meal = try #require(food.entries.first)
        #expect((meal.from, meal.name, meal.kcal, meal.isKnown) == (.built, "Breakfast", 1015, true))
        #expect((meal.kcalEstimated, meal.kcalLow, meal.kcalHigh) == (578, 817, 1217))
        let parts = try #require(meal.parts)
        #expect(parts.map(\.from) == [.barcode, .typed, .typed, .photo])
        #expect(parts[0].weighed == .init(grams: 60, kcalPer100g: 350, proteinPer100g: 33))
        #expect(parts[2].weighed == nil)
        #expect(meal.counted.map(\.name) == ["Protein bar", "Banana", "Flat white", "eggs on toast"])
        // A part is found by its id, and so is its meal.
        #expect(food.entry(BuiltFixture.photoID)?.name == "eggs on toast")
        #expect(food.meal(holding: BuiltFixture.photoID)?.id == BuiltFixture.mealID)
        #expect(food.meal(holding: BuiltFixture.mealID) == nil)
        // The cache writes and reads it back the same.
        #expect(try JSONDecoder.lyfe.decode(FoodDay.self, from: JSONEncoder.lyfe.encode(food)) == food)
    }

    @Test func aSavedMealReadsItsIngredientsAsWhatTheyAre() throws {
        let cafe = try #require(BuiltFixture.day(meals: [BuiltFixture.cafe]).meals.first)
        #expect(cafe.kcalEstimated == 192)
        #expect(
            cafe.ingredients == [
                Ingredient(name: "Greek yogurt", grams: 175, kcalPer100g: 63, proteinPer100g: 11, code: "064200115896"),
                Ingredient(name: "Flat white", kcal: 120, proteinG: 6),
                Ingredient(name: "Eggs on toast", kcal: 192.4, proteinG: 23, estimated: true),
            ])
        #expect((cafe.ingredients[0].kcal, cafe.ingredients[0].grams) == (110.25, 175))
        #expect((cafe.ingredients[2].kcal, cafe.ingredients[2].grams) == (192.4, nil))
        // A meal weighed before any of this reads as it always did.
        #expect(Fixture.foodDay().meals[0].kcalEstimated == nil)
        #expect(Fixture.foodDay().drafts == nil)
    }

    @Test func aPhotoSentAheadIsOnNoDay() {
        let food = BuiltFixture.day(drafts: [BuiltFixture.photo("estimating")])
        #expect(food.entries.isEmpty)
        #expect(food.drafts?.map(\.id) == [BuiltFixture.photoID])
        #expect(food.entry(BuiltFixture.photoID)?.figures == .estimating)
        #expect(FoodText.unknownNotice(food) == nil)
    }

    @Test func eachPartOfALoggedMealBecomesAnIngredient() throws {
        let meal = try #require(BuiltFixture.day(entries: [BuiltFixture.meal()]).entries.first)
        let draft = try #require(MealDraft(saving: meal))
        #expect((draft.purpose, draft.isNew, draft.name, draft.slot) == (.recipe, true, "Breakfast", .breakfast))
        #expect(
            draft.foods == [
                // Scanned: its label and its code. Typed: as typed.
                Ingredient(name: "Protein bar", grams: 60, kcalPer100g: 350, proteinPer100g: 33, code: "96385074"),
                BuiltFixture.banana,
                BuiltFixture.coffee,
                // The photo's estimate as it stands, still an estimate.
                Ingredient(name: "eggs on toast", kcal: 578, proteinG: 33, estimated: true),
            ])
        // Not while the photo is still with the model.
        let waiting = try #require(BuiltFixture.day(entries: [BuiltFixture.meal(photo: "estimating")]).entries.first)
        #expect(MealDraft(saving: waiting) == nil)
        #expect(MealDraft(saving: Fixture.foodDay(logged: ["breakfast"]).entries[0]) == nil)
    }
}

@Suite struct MealDraftTests {
    @Test func theRunningTotalAddsUpWhatIsKnownAndCountsWhatIsNot() throws {
        var draft = MealDraft(slot: .breakfast, purpose: .log)
        #expect(draft.total() == .init(kcal: 0, proteinG: 0, kcalEstimated: 0, unknown: 0))
        let photo = MealPart(id: BuiltFixture.photoID, .photo(note: "eggs on toast", hasPhoto: true))
        draft.parts = [
            .scanned(code: "96385074", grams: 60, product: BuiltFixture.bar),
            MealPart(.food(BuiltFixture.banana)),
            MealPart(.food(BuiltFixture.coffee)),
            photo,
            // Scanned with no connection: looked up once sent.
            .scanned(code: "0628915423456", grams: 175, product: nil),
        ]
        // The photo and the unknown code are left out, not counted as zero.
        #expect(draft.total() == .init(kcal: 437, proteinG: 27.1, kcalEstimated: 0, unknown: 2))
        #expect(draft.ingredients() == nil)

        // The estimate arrives.
        let estimate = try #require(BuiltFixture.day(drafts: [BuiltFixture.photo()]).drafts?.first)
        let estimates = [photo.id: estimate]
        #expect(draft.total(estimates: estimates) == .init(kcal: 1015, proteinG: 60.1, kcalEstimated: 578, unknown: 1))
        draft.parts.removeLast()
        #expect(draft.total(estimates: estimates).unknown == 0)
        #expect(draft.ingredients(estimates: estimates)?.last == Ingredient(name: "eggs on toast", kcal: 578, proteinG: 33, estimated: true))

        // A photo still being estimated is not known yet either.
        let estimating = try #require(BuiltFixture.day(drafts: [BuiltFixture.photo("estimating")]).drafts?.first)
        #expect(draft.total(estimates: [photo.id: estimating]).unknown == 1)
    }

    @Test func aScannedPartKeepsItsCodeAndALoggedMealHasADefaultName() {
        let bar = MealPart.scanned(code: "96385074", grams: 60, product: BuiltFixture.bar)
        #expect(bar.kind == .food(Ingredient(name: "Protein bar", grams: 60, kcalPer100g: 350, proteinPer100g: 33, code: "96385074")))
        #expect(bar.name == "Protein bar")
        let unknown = MealPart.scanned(code: "0628915423456", grams: 175, product: nil)
        #expect(unknown.kind == .scan(code: "0628915423456", grams: 175))
        #expect(unknown.name == "Barcode 0628915423456")
        #expect(MealPart(.photo(note: " ", hasPhoto: true)).name == "Photo meal")

        var draft = MealDraft(slot: .dinner, purpose: .log)
        #expect(draft.title == "Dinner")
        draft.name = " Ramen night "
        #expect(draft.title == "Ramen night")
    }

    @Test func savingNeedsANameAndEveryPartsFigures() {
        var draft = MealDraft(slot: .breakfast, purpose: .log)
        draft.name = "Breakfast bowl"
        draft.parts = [MealPart(.food(BuiltFixture.banana)), .scanned(code: "0628915423456", grams: 175, product: nil)]
        #expect(draft.missing() == "A part's figures are not known yet")
        draft.parts.removeLast()
        #expect(draft.missing() == nil)
    }

    @Test func aFoodTypedWholeIsReadFromItsThreeFields() {
        #expect(FoodTyping.whole(name: " Flat white ", kcal: "120", protein: "6") == .success(BuiltFixture.coffee))
        func slip(_ name: String, _ kcal: String, _ protein: String) -> String? {
            if case .failure(let slip) = FoodTyping.whole(name: name, kcal: kcal, protein: protein) { return slip.message }
            return nil
        }
        #expect(slip("", "120", "6") == "Name it")
        #expect(slip("Flat white", "", "6") == "Type the kcal it comes to, 0 to 10000")
        #expect(slip("Flat white", "12000", "6") == "Type the kcal it comes to, 0 to 10000")
        #expect(slip("Flat white", "120", "") == "Type the protein it comes to in grams, 0 to 1000")
    }

    @Test func theMealBeingBuiltIsKeptOnThePhone() {
        let store = DraftStore(directory: Fixture.temporaryDirectory())
        #expect(store.load() == nil)
        var draft = MealDraft(slot: .breakfast, purpose: .log, startedAt: Date(timeIntervalSince1970: 1_795_000_000))
        draft.name = "Breakfast bowl"
        draft.parts = [
            MealPart(.food(BuiltFixture.banana)), MealPart(.food(BuiltFixture.coffee)),
            .scanned(code: "96385074", grams: 60, product: BuiltFixture.bar),
            .scanned(code: "0628915423456", grams: 175, product: nil),
            MealPart(.photo(note: "eggs on toast", hasPhoto: true)),
        ]
        store.save(draft)
        #expect(store.load() == draft)
        store.save(nil)
        #expect(store.load() == nil)
    }

    @Test func aMealWaitingToBeSentIsKeptWithItsParts() throws {
        let store = CaptureStore(directory: Fixture.temporaryDirectory())
        let at = Date(timeIntervalSince1970: 1_795_000_000)
        let meal = FoodCapture(
            eatenAt: at, slot: .breakfast,
            kind: .built(name: "", parts: [MealPart(.food(BuiltFixture.banana)), MealPart(.photo(note: "eggs", hasPhoto: true))]))
        let joining = FoodCapture(eatenAt: at, slot: .breakfast, kind: .typed(BuiltFixture.coffee), partOf: BuiltFixture.mealID)
        store.enqueue(meal)
        store.enqueue(joining)
        #expect(store.outbox() == [meal, joining])
        #expect((meal.name, joining.name) == ("Breakfast", "Flat white"))

        // A meal kept by a build from before parts existed still reads.
        let old = #"[{"id": "00000000-0000-4000-9000-000000000099", "eatenAt": 1795000000000, "slot": "lunch", "kind": {"photo": {"note": "pho", "hasPhoto": false}}}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let kept = try decoder.decode([FoodCapture].self, from: Data(old.utf8))
        #expect((kept[0].name, kept[0].partOf) == ("pho", nil))
    }
}

@MainActor
@Suite struct MealBuildingTests {
    func sent(_ world: World, _ route: String) -> [[String: Any]] {
        world.backend.bodies(route).compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])

    @Test func aMealIsBuiltFromPartsAndLoggedAsOne() async throws {
        let world = World.signedIn()
        world.backend.on("POST /v1/food/built-entries", BuiltFixture.home(entries: [BuiltFixture.meal()]))
        let model = world.launch()

        model.openMealBuilder()
        let draft = try #require(model.mealDraft)
        #expect((draft.purpose, draft.isNew, draft.portions, model.screen) == (.log, true, 1, .food))
        // Scanning opens over the builder and comes back to it.
        model.openScan()
        #expect(model.foodFlow == .scan(into: nil))
        model.addScan(code: "96385074", grams: 60, product: BuiltFixture.bar)
        #expect(model.foodFlow == nil)
        model.addPart(MealPart(.food(BuiltFixture.banana)))
        model.addPart(MealPart(.food(BuiltFixture.coffee)))
        model.addScan(code: "0628915423456", grams: 175, product: nil)
        model.changeDraft { $0.slot = .breakfast }
        #expect(model.mealDraft?.total().kcal == 437)
        // Nothing is sent while it is built.
        #expect(world.backend.requests.isEmpty)

        #expect(await model.logMealDraft() == nil)

        let body = try #require(sent(world, "POST /v1/food/built-entries").first)
        #expect(Set(body.keys) == ["id", "eaten_at", "slot", "name", "parts"])
        #expect(body["id"] as? String == draft.id.uuidString)
        #expect((body["slot"] as? String, body["name"] as? String) == ("breakfast", ""))
        #expect(body["eaten_at"] as? String == "2026-11-18T11:06:40Z")
        let parts = try #require(body["parts"] as? [[String: Any]])
        // Scanned: the code and the grams; the backend reads the label.
        #expect(Set(parts[0].keys) == ["id", "code", "grams"])
        #expect((parts[0]["code"] as? String, parts[0]["grams"] as? Double) == ("96385074", 60))
        // Typed: weighed with its label's figures, or whole.
        #expect(Set(parts[1].keys) == ["id", "name", "grams", "kcal_per_100g", "protein_per_100g"])
        #expect((parts[1]["name"] as? String, parts[1]["kcal_per_100g"] as? Double) == ("Banana", 89))
        #expect(Set(parts[2].keys) == ["id", "name", "kcal", "protein_g"])
        #expect((parts[2]["kcal"] as? Double, parts[2]["protein_g"] as? Double) == (120, 6))
        #expect((parts[3]["code"] as? String, parts[3]["grams"] as? Double) == ("0628915423456", 175))
        #expect(Set(parts.compactMap { $0["id"] as? String }).count == 4)

        #expect(model.mealDraft == nil)
        #expect(model.parkedMeal == nil)
        #expect(model.unsentCaptures.isEmpty)
        #expect(world.drafts.load() == nil)
        #expect(model.home?.food?.entries.first?.from == .built)
    }

    @Test func aPhotoIsSentAheadAndItsEstimateShowsWhileTheMealIsBuilt() async throws {
        let world = World.signedIn()
        world.backend.on("POST /v1/food/photo-entries", BuiltFixture.home(drafts: [BuiltFixture.photo("estimating")]))
        let model = world.launch()

        model.openPhotoMeal()
        // The photo screen is over a meal that was started for it.
        #expect(model.foodFlow == .photo(into: nil))
        let draft = try #require(model.mealDraft)
        model.changeDraft { $0.slot = .breakfast }
        // The stand-in's photo has this id, as the phone's part will not:
        // answer for whatever id is sent by reading it back.
        #expect(await model.addPhoto(note: " eggs on toast ", photo: jpeg) == .sent)

        let body = try #require(sent(world, "POST /v1/food/photo-entries").first)
        #expect(Set(body.keys) == ["id", "eaten_at", "slot", "note", "photo_jpeg", "part_of"])
        #expect(body["part_of"] as? String == draft.id.uuidString)
        #expect((body["note"] as? String, body["slot"] as? String) == ("eggs on toast", "breakfast"))
        let part = try #require(model.mealDraft?.parts.first)
        #expect(body["id"] as? String == part.id.uuidString)
        #expect(part.kind == .photo(note: "eggs on toast", hasPhoto: true))
        // Back on the builder, and not a meal of the day.
        #expect(model.foodFlow == nil)
        #expect(model.unsentCaptures.isEmpty)
        #expect(model.home?.food?.entries.isEmpty == true)
        #expect(await model.mealPhoto(part.id) == jpeg)
    }

    /// A model with a meal on the builder whose photo has the fixture's id,
    /// as the backend knows it.
    func building(_ world: World, photo figures: String = "known") async throws -> AppModel {
        world.backend.on("POST /v1/food/photo-entries", BuiltFixture.home(drafts: [BuiltFixture.photo(figures)]))
        let model = world.launch()
        model.openMealBuilder()
        model.changeDraft { $0.slot = .breakfast }
        model.addPart(MealPart(.food(BuiltFixture.banana)))
        await model.addPhoto(note: "eggs on toast", photo: jpeg)
        // The part takes the id the stand-in backend answers with.
        let made = try #require(model.mealDraft?.parts.last?.id)
        model.changeDraft { $0.parts[1].id = BuiltFixture.photoID }
        world.captures.remove(made, forget: true)
        return model
    }

    @Test func theEstimateJoinsTheRunningTotalAndIsLoggedByItsId() async throws {
        let world = World.signedIn()
        let model = try await building(world)
        let draft = try #require(model.mealDraft)

        #expect(model.draftEstimates[BuiltFixture.photoID]?.kcal == 578)
        #expect(draft.total(estimates: model.draftEstimates) == .init(kcal: 685, proteinG: 34.3, kcalEstimated: 578, unknown: 0))

        world.backend.on("POST /v1/food/built-entries", BuiltFixture.home(entries: [BuiltFixture.meal()]))
        #expect(await model.logMealDraft() == nil)
        let parts = try #require(sent(world, "POST /v1/food/built-entries").first?["parts"] as? [[String: Any]])
        // The photo went ahead; the meal only names it.
        #expect(Set(parts[1].keys) == ["id"])
        #expect(parts[1]["id"] as? String == BuiltFixture.photoID.uuidString)
        #expect(model.draftEstimates.isEmpty)
    }

    @Test func aMealBuiltWithNoConnectionIsKeptAndSentPhotoFirst() async throws {
        let world = World.signedIn()
        world.backend.goDown()
        let model = world.launch()

        model.openMealBuilder()
        model.changeDraft { $0.slot = .breakfast }
        #expect(await model.addPhoto(note: "eggs on toast", photo: jpeg) == .saved)
        model.addPart(MealPart(.food(BuiltFixture.banana)))
        // The photo waits on the phone, and is not a meal of the day.
        #expect(model.unsentCaptures.count == 1)
        #expect(model.unsentMeals.isEmpty)
        let draft = try #require(model.mealDraft)

        #expect(await model.logMealDraft() == nil)
        #expect(model.mealDraft == nil)
        // The meal is one row on the day, marked as not counted yet.
        let meal = try #require(model.unsentMeals.first)
        #expect(model.unsentMeals.count == 1)
        #expect(meal.id == draft.id)
        let row = FoodText.captureRow(meal)
        #expect((row.title, row.label, row.value, row.mark) == ("Breakfast", "ON THIS PHONE · 2 PARTS · NOT COUNTED YET", "107", .striped))

        // Opened again a day later, with the server back.
        world.time.advance(86_400)
        let relaunched = world.launch()
        #expect(relaunched.unsentCaptures.count == 2)
        #expect(relaunched.parkedMeal == nil)
        world.backend.goDown(false)
        world.backend.on("POST /v1/food/photo-entries", BuiltFixture.home(drafts: [BuiltFixture.photo("estimating")]))
        world.backend.on("POST /v1/food/built-entries", BuiltFixture.home(entries: [BuiltFixture.meal(photo: "estimating")]))
        world.backend.on("GET /v1/home", BuiltFixture.home(entries: [BuiltFixture.meal(photo: "estimating")]))
        world.backend.on("POST /v1/sync", .ok(Fixture.sources()))
        await relaunched.refresh()

        // The photo first, so the meal finds it there. (The tries made
        // with no connection are in the list too, before these.)
        let food = world.backend.requests.filter { $0.hasPrefix("POST /v1/food/") }
        #expect(food.suffix(2) == ["POST /v1/food/photo-entries", "POST /v1/food/built-entries"])
        let photo = try #require(sent(world, "POST /v1/food/photo-entries").last)
        #expect(photo["part_of"] as? String == draft.id.uuidString)
        let built = try #require(sent(world, "POST /v1/food/built-entries").last)
        // When it was logged, not when it was sent.
        #expect(built["eaten_at"] as? String == "2026-11-18T11:06:40Z")
        #expect((built["parts"] as? [[String: Any]])?.first?["id"] as? String == photo["id"] as? String)
        #expect(relaunched.unsentCaptures.isEmpty)
    }

    @Test func aMealLeftHalfBuiltIsThereToCarryOnWith() async throws {
        let world = World.signedIn()
        let model = world.launch()
        model.openMealBuilder()
        model.addPart(MealPart(.food(BuiltFixture.banana)))
        let draft = try #require(model.mealDraft)

        model.closeMealEditor()
        #expect(model.mealDraft == nil)
        #expect(model.parkedMeal == draft)
        #expect(FoodText.buildingLine(.init(parts: 1, kcal: 107)) == "MEAL IN PROGRESS · 1 PART · 107 KCAL")

        // Typing a recipe meanwhile does not lose it.
        model.openMealEditor()
        model.closeMealEditor()
        #expect(model.parkedMeal == draft)

        // lyfe is closed and opened again: it is still there.
        let relaunched = world.launch()
        #expect(relaunched.parkedMeal == draft)
        relaunched.openMealBuilder()
        #expect(relaunched.mealDraft == draft)
        #expect(relaunched.parkedMeal == nil)
        relaunched.closeFood()
        #expect(relaunched.parkedMeal == draft)

        // Three days on it is not the meal in front of anyone any more.
        world.time.advance(3 * 86_400 + 1)
        #expect(world.launch().parkedMeal == nil)
        #expect(world.drafts.load() == nil)
    }

    @Test func aMealWithNothingInItIsNotKeptOrLogged() async {
        let world = World.signedIn()
        let model = world.launch()
        model.openMealBuilder()
        #expect(await model.logMealDraft() == "Add what you ate first.")
        #expect(model.mealDraft != nil)
        model.closeMealEditor()
        #expect(model.parkedMeal == nil)
        #expect(world.drafts.load() == nil)
        #expect(world.backend.requests.isEmpty)
    }

    @Test func throwingAMealAwayDropsThePhotosSentForIt() async throws {
        let world = World.signedIn()
        let model = try await building(world)
        let route = "DELETE /v1/food/entries/\(BuiltFixture.photoID.uuidString.lowercased())"
        world.backend.on(route, BuiltFixture.home())

        await model.discardMeal()

        #expect(world.backend.requests.last == route)
        #expect(model.mealDraft == nil)
        #expect(model.parkedMeal == nil)
        #expect(world.drafts.load() == nil)
        #expect(model.home?.food?.drafts?.isEmpty == true)
    }

    @Test func aPhotoStillOnThePhoneIsDroppedWithoutTheServer() async {
        let world = World.signedIn()
        world.backend.goDown()
        let model = world.launch()
        model.openMealBuilder()
        await model.addPhoto(note: "eggs on toast", photo: jpeg)
        let id = model.unsentCaptures[0].id

        await model.discardMeal()

        #expect(model.unsentCaptures.isEmpty)
        #expect(world.captures.photo(id) == nil)
        #expect(!world.backend.requests.contains { $0.hasPrefix("DELETE") })
    }

    @Test func aPhotoPartTakenOutIsTakenOffTheServerToo() async throws {
        let world = World.signedIn()
        let model = try await building(world)
        let route = "DELETE /v1/food/entries/\(BuiltFixture.photoID.uuidString.lowercased())"
        world.backend.on(route, BuiltFixture.home())
        // From its estimate screen.
        model.openEstimate(BuiltFixture.photoID)

        #expect(await model.takeBackMeal(BuiltFixture.photoID) == nil)

        #expect(model.mealDraft?.parts.map(\.name) == ["Banana"])
        model.closeFoodFlow()
        #expect(model.foodFlow == nil)
        #expect(model.mealDraft != nil)
    }

    @Test func savingForOneTapKeepsThePhotosEstimateAndTheMealCanStillBeLogged() async throws {
        let world = World.signedIn()
        let model = try await building(world)
        let draft = try #require(model.mealDraft)
        #expect(await model.saveMeal() == "Give the meal a name.")
        model.changeDraft { $0.name = "Café breakfast" }

        let saved = """
            {"id": "\(draft.mealId.uuidString.lowercased())", "name": "Café breakfast", "slot": "breakfast",
             "portions": 1, "kcal": 685, "protein_g": 34.3, "kcal_estimated": 578, "ingredients": []}
            """
        let route = "PUT /v1/food/meals/\(draft.mealId.uuidString.lowercased())"
        world.backend.on(route, BuiltFixture.home(drafts: [BuiltFixture.photo()], meals: [saved]))
        #expect(await model.saveMeal() == nil)

        let body = try #require(sent(world, route).first)
        #expect((body["name"] as? String, body["portions"] as? Int) == ("Café breakfast", 1))
        let ingredients = try #require(body["ingredients"] as? [[String: Any]])
        #expect(Set(ingredients[0].keys) == ["name", "grams", "kcal_per_100g", "protein_per_100g"])
        // What the photo was estimated at, saved as an estimate.
        #expect(Set(ingredients[1].keys) == ["name", "kcal", "protein_g", "estimated"])
        #expect((ingredients[1]["name"] as? String, ingredients[1]["kcal"] as? Double) == ("eggs on toast", 578))
        #expect(ingredients[1]["estimated"] as? Bool == true)

        // The builder stays, to log the meal as well.
        #expect(model.mealDraft?.isSaved == true)
        #expect(FoodText.logBar(model.mealDraft!, total: model.mealDraft!.total(), logging: false).small == "SAVED · LOGS ONE PORTION AS BREAKFAST")
        world.backend.on("POST /v1/food/entries", BuiltFixture.home(drafts: [BuiltFixture.photo()], meals: [saved]))
        world.backend.on("DELETE /v1/food/entries/\(BuiltFixture.photoID.uuidString.lowercased())", BuiltFixture.home(meals: [saved]))
        #expect(await model.logMealDraft() == nil)
        // Logged as the one tap it now is; the photo sent ahead is dropped.
        let tap = try #require(sent(world, "POST /v1/food/entries").first)
        #expect(tap["meal_id"] as? String == draft.mealId.uuidString)
        #expect(world.backend.requests.suffix(2) == ["POST /v1/food/entries", "DELETE /v1/food/entries/\(BuiltFixture.photoID.uuidString.lowercased())"])
        #expect(!world.backend.requests.contains("POST /v1/food/built-entries"))
        #expect(model.mealDraft == nil)
        #expect(model.parkedMeal == nil)
    }

    @Test func aSavedMealChangedAgainIsNoLongerWhatWasSaved() async throws {
        let world = World.signedIn()
        let model = world.launch()
        model.openMealBuilder()
        model.changeDraft {
            $0.name = "Snack"
            $0.foods = [BuiltFixture.coffee]
        }
        let draft = try #require(model.mealDraft)
        world.backend.on("PUT /v1/food/meals/\(draft.mealId.uuidString.lowercased())", BuiltFixture.home())
        #expect(await model.saveMeal() == nil)
        #expect(model.mealDraft?.isSaved == true)
        // Saved and closed: there is nothing left to carry on with.
        model.closeMealEditor()
        #expect(model.parkedMeal == nil)

        model.openMealBuilder()
        model.changeDraft {
            $0.foods = [BuiltFixture.coffee]
            $0.isSaved = true
        }
        model.addPart(MealPart(.food(BuiltFixture.banana)))
        #expect(model.mealDraft?.isSaved == false)
    }

    @Test func aMealCannotBeSavedWhileAPartIsUnknown() async throws {
        let world = World.signedIn()
        let model = try await building(world, photo: "estimating")
        model.changeDraft { $0.name = "Café breakfast" }
        #expect(await model.saveMeal() == "A part's figures are not known yet.")
        #expect(!world.backend.requests.contains { $0.hasPrefix("PUT") })
        // It can be logged all the same.
        world.backend.on("POST /v1/food/built-entries", BuiltFixture.home(entries: [BuiltFixture.meal(photo: "estimating")]))
        #expect(await model.logMealDraft() == nil)
        #expect(model.home?.food?.entries.first?.isKnown == false)
    }

    @Test func aMealTheServerRefusesIsStillThereToPutRight() async throws {
        let world = World.signedIn()
        world.backend.on("POST /v1/food/built-entries", .init(status: 400, body: #"{"error": "bad_request"}"#))
        let model = world.launch()
        model.openMealBuilder()
        model.changeDraft { $0.slot = .snack }
        model.addPart(MealPart(.food(BuiltFixture.coffee)))
        let draft = try #require(model.mealDraft)

        #expect(await model.logMealDraft() == "The server would not log Snack (400).")
        #expect(model.mealDraft == draft)
        #expect(model.unsentCaptures.isEmpty)
    }

    @Test func aPartJoinsAMealAlreadyLogged() async throws {
        let world = World.signedIn()
        let logged = BuiltFixture.home(entries: [BuiltFixture.meal()])
        world.backend.on("GET /v1/home", logged)
        world.backend.on("POST /v1/food/barcode-entries", logged)
        world.backend.on("POST /v1/food/typed-entries", logged)
        world.backend.on("POST /v1/food/photo-entries", logged)
        let model = world.launch()
        await model.reloadHome()
        let meal = BuiltFixture.mealID

        model.openMeal(meal)
        model.openScan(into: meal)
        #expect(model.foodFlow == .scan(into: meal))
        // No meal is started for it: it joins the one on the day.
        #expect(model.mealDraft == nil)
        #expect(await model.logBarcode(code: "96385074", grams: 60, slot: .breakfast, product: BuiltFixture.bar, partOf: meal) == .sent)
        #expect(sent(world, "POST /v1/food/barcode-entries").first?["part_of"] as? String == meal.uuidString)
        // Back to the meal it joined.
        #expect(model.foodFlow == .meal(meal))

        #expect(await model.logTyped(BuiltFixture.coffee, slot: .breakfast, partOf: meal) == .sent)
        let typed = try #require(sent(world, "POST /v1/food/typed-entries").first)
        #expect(Set(typed.keys) == ["id", "eaten_at", "slot", "part_of", "name", "kcal", "protein_g"])
        #expect((typed["name"] as? String, typed["part_of"] as? String) == ("Flat white", meal.uuidString))

        // A photo opens its estimate, and closing that leads back to the meal.
        model.openPhotoMeal(into: meal)
        #expect(model.foodFlow == .photo(into: meal))
        await model.logPhotoMeal(note: "toast", photo: nil, slot: .breakfast, partOf: meal)
        #expect(sent(world, "POST /v1/food/photo-entries").first?["part_of"] as? String == meal.uuidString)
        model.openEstimate(BuiltFixture.photoID)
        model.closeFoodFlow()
        #expect(model.foodFlow == .meal(meal))
        model.closeFoodFlow()
        #expect(model.foodFlow == nil)
    }

    @Test func aPartAddedOfflineWaitsToJoinItsMeal() async throws {
        let world = World.signedIn()
        world.backend.on("GET /v1/home", BuiltFixture.home(entries: [BuiltFixture.meal()]))
        let model = world.launch()
        await model.reloadHome()
        world.backend.goDown()

        #expect(await model.logTyped(BuiltFixture.coffee, slot: .breakfast, partOf: BuiltFixture.mealID) == .saved)
        // It shows on the day, since its meal is there.
        let kept = try #require(model.unsentMeals.first)
        #expect(FoodText.captureRow(kept).label == "ON THIS PHONE · JOINS ITS MEAL ONCE SENT")
        #expect(await model.takeBackMeal(kept.id) == nil)
        #expect(model.unsentCaptures.isEmpty)
    }

    @Test func aLoggedMealIsSavedForOneTapOnceItsPartsAreKnown() async throws {
        let world = World.signedIn()
        world.backend.on(
            "GET /v1/home", BuiltFixture.home(entries: [BuiltFixture.meal(photo: "estimating")]),
            BuiltFixture.home(entries: [BuiltFixture.meal()]))
        let model = world.launch()
        await model.reloadHome()
        model.openMeal(BuiltFixture.mealID)

        #expect(!model.openMealEditor(savingLogged: BuiltFixture.mealID))
        #expect(model.foodFlow == .meal(BuiltFixture.mealID))
        await model.reloadHome()
        #expect(model.openMealEditor(savingLogged: BuiltFixture.mealID))
        let draft = try #require(model.mealDraft)
        #expect((draft.purpose, draft.parts.count, model.foodFlow) == (.recipe, 4, nil))
        #expect(draft.portion() == (1015, 60.1))
    }

    @Test func takingABuiltMealBackOnThePhoneTakesItsPhotosToo() async throws {
        let world = World.signedIn()
        world.backend.goDown()
        let model = world.launch()
        model.openMealBuilder()
        await model.addPhoto(note: "eggs on toast", photo: jpeg)
        let photo = model.unsentCaptures[0].id
        await model.logMealDraft()
        let meal = try #require(model.unsentMeals.first)

        #expect(await model.takeBackMeal(meal.id) == nil)

        #expect(model.unsentCaptures.isEmpty)
        #expect(world.captures.outbox().isEmpty)
        #expect(world.captures.photo(photo) == nil)
    }

    @Test func signingOutSetsTheMealAsideRatherThanLosingIt() async {
        let world = World.signedIn()
        world.backend.on("POST /v1/auth/sign-out", .init(status: 204, body: ""))
        let model = world.launch()
        model.openMealBuilder()
        model.addPart(MealPart(.food(BuiltFixture.banana)))
        await model.signOut()
        #expect(model.mealDraft == nil)
        #expect(model.parkedMeal?.parts.count == 1)
    }
}

@Suite struct BuiltMealTextTests {
    let meal = BuiltFixture.day(entries: [BuiltFixture.meal()]).entries[0]
    let waiting = BuiltFixture.day(entries: [BuiltFixture.meal(photo: "estimating")]).entries[0]

    @Test func aBuiltMealIsOneRowThatOpensItsParts() {
        let row = FoodText.builtRow(meal)
        #expect((row.title, row.label, row.value) == ("Breakfast", "4 PARTS · 817–1,217 · 60 G", "1,015"))
        // A photo among the parts stripes the meal.
        #expect((row.mark, row.tap) == (.striped, .meal(BuiltFixture.mealID)))
        #expect(FoodText.entryRow(meal) == row)

        // With the photo still out, what is known is shown and said to be part.
        let partly = FoodText.builtRow(waiting)
        #expect((partly.label, partly.value, partly.mark) == ("4 PARTS · 1 STILL UNKNOWN · 27 G", "437", .striped))

        // All measured: solid, with no range.
        var measured = meal
        measured.parts?.removeLast()
        measured.estimated = false
        measured.kcalLow = nil
        measured.kcalHigh = nil
        measured.kcal = 437
        measured.proteinG = 27.1
        #expect((FoodText.builtRow(measured).label, FoodText.builtRow(measured).mark) == ("3 PARTS · 27 G PROTEIN", .solid))

        var alone = measured
        alone.parts = [waiting.parts![3]]
        alone.figures = .estimating
        #expect((FoodText.builtRow(alone).label, FoodText.builtRow(alone).value) == ("1 PART · 1 STILL UNKNOWN · 27 G", "…"))
    }

    @Test func eachPartOfALoggedMealHasItsRow() {
        let rows = (meal.parts ?? []).map(FoodText.entryRow)
        #expect(rows.map(\.label) == [
            "LABEL · 60 G · 20 G PROTEIN", "TYPED · 120 G · 1 G PROTEIN", "TYPED · 6 G PROTEIN", "PHOTO · 380–780 · 33 G",
        ])
        #expect(rows.map(\.mark) == [.solid, .solid, .solid, .striped])
        #expect(rows.map(\.tap) == [.takeBack, .takeBack, .takeBack, .estimate(BuiltFixture.photoID)])
        #expect(FoodText.mealLine(meal) == "4 PARTS · 60 G PROTEIN · 578 ESTIMATED · 817–1,217")
        #expect(FoodText.mealLine(waiting) == "4 PARTS · 27 G PROTEIN · 1 STILL UNKNOWN")
    }

    @Test func theDaySaysWhenAPartOfAMealIsStillUnknown() {
        let food = BuiltFixture.day(entries: [BuiltFixture.meal(photo: "estimating")])
        #expect(FoodText.unknownNotice(food) == "1 photo is being estimated. Not in the total until then.")
        #expect(FoodText.unknownNotice(BuiltFixture.day(entries: [BuiltFixture.meal()])) == nil)
        let rows = FoodText.rows(food, unsent: [])
        // One row for breakfast, and the other meals still open.
        #expect(rows.map(\.title) == ["Breakfast", "LUNCH", "DINNER", "SNACKS"])
    }

    @Test func aPartOnTheBuilderShowsWhatIsKnownOfIt() throws {
        let bar = FoodText.partRow(.scanned(code: "96385074", grams: 60, product: BuiltFixture.bar))
        #expect((bar.title, bar.label, bar.value, bar.mark) == ("Protein bar", "LABEL · 60 G · 20 G PROTEIN", "210", .solid))
        let banana = FoodText.partRow(MealPart(.food(BuiltFixture.banana)))
        #expect((banana.label, banana.value) == ("120 G · 89 KCAL · 1.1 G PER 100 G", "107"))
        let coffee = FoodText.partRow(MealPart(.food(BuiltFixture.coffee)))
        #expect((coffee.label, coffee.value, coffee.mark) == ("TYPED WHOLE · 6 G PROTEIN", "120", .solid))
        let unknown = FoodText.partRow(.scanned(code: "0628915423456", grams: 175, product: nil))
        #expect((unknown.title, unknown.label, unknown.value, unknown.mark) == ("Barcode 0628915423456", "175 G · LOOKED UP ONCE SENT", "?", .outline))
        // What a photo in a saved meal was estimated at stays striped.
        let fixed = FoodText.partRow(MealPart(.food(Ingredient(name: "Eggs on toast", kcal: 192.4, proteinG: 23, estimated: true))))
        #expect((fixed.label, fixed.value, fixed.mark) == ("PHOTO ESTIMATE · 23 G PROTEIN", "192", .striped))

        let photo = MealPart(id: BuiltFixture.photoID, .photo(note: "eggs on toast", hasPhoto: true))
        #expect(FoodText.partRow(photo, unsent: true).label == "PHOTO · ON THIS PHONE · ESTIMATED ONCE SENT")
        #expect((FoodText.partRow(photo).label, FoodText.partRow(photo).value) == ("PHOTO · SENT TO THE SPARK", "…"))
        let estimating = try #require(BuiltFixture.day(drafts: [BuiltFixture.photo("estimating")]).drafts?.first)
        #expect(FoodText.partRow(photo, estimate: estimating).label == "PHOTO · ESTIMATING ON THE SPARK")
        let known = try #require(BuiltFixture.day(drafts: [BuiltFixture.photo()]).drafts?.first)
        let row = FoodText.partRow(photo, estimate: known)
        #expect((row.label, row.value, row.mark) == ("PHOTO · 380–780 · 33 G", "578", .striped))
    }

    @Test func theBuildersBarSaysWhatTheMealComesToSoFar() {
        var draft = MealDraft(slot: .breakfast, purpose: .log)
        #expect(FoodText.logBar(draft, total: draft.total(), logging: false) == ("SCAN, PHOTOGRAPH OR TYPE WHAT YOU ATE", "LOG IT"))
        draft.parts = [
            .scanned(code: "96385074", grams: 60, product: BuiltFixture.bar), MealPart(.food(BuiltFixture.banana)),
            MealPart(.photo(note: "eggs", hasPhoto: true)),
        ]
        #expect(FoodText.logBar(draft, total: draft.total(), logging: false) == ("BREAKFAST · 317 KCAL · 21 G · 1 TO COME", "LOG IT"))
        #expect(FoodText.logBar(draft, total: draft.total(), logging: true).big == "LOGGING")
        #expect(FoodText.totalLine(draft.total(), parts: 3) == "3 PARTS · 21 G PROTEIN · 1 STILL UNKNOWN")
        #expect(
            FoodText.totalLine(.init(kcal: 1015, proteinG: 60.1, kcalEstimated: 578, unknown: 0), parts: 4)
                == "4 PARTS · 60 G PROTEIN · 578 ESTIMATED")
        // Saving it says what a portion comes to, or what is missing.
        #expect(FoodText.editorBar(draft, saving: false).small == "GIVE THE MEAL A NAME")
        draft.name = "Breakfast bowl"
        #expect(FoodText.editorBar(draft, saving: false).small == "A PART'S FIGURES ARE NOT KNOWN YET")
        draft.parts.removeLast()
        draft.portions = 2
        #expect(FoodText.portionLine(draft) == "EACH OF 2 PORTIONS · 158 KCAL · 11 G PROTEIN")
    }

    @Test func aSavedMealWithAPhotoInItStaysMarkedAsPartlyEstimated() {
        let food = BuiltFixture.day(meals: [BuiltFixture.cafe])
        #expect(FoodText.mealRow(food.meals[0]).label == "BREAKFAST · 48 G PROTEIN · PART ESTIMATED")
        // Logged with one tap: striped, and it says how much is estimated.
        let logged = FoodDay.Entry(
            id: UUID(), slot: .breakfast, name: "Café breakfast", mealId: food.meals[0].id, servings: 1, kcal: 423,
            proteinG: 48.3, source: .saved, figures: .known, estimated: true, kcalLow: 351, kcalHigh: 491,
            kcalEstimated: 192)
        let row = FoodText.entryRow(logged)
        #expect((row.label, row.mark, row.tap) == ("SAVED · 192 ESTIMATED · 48 G", .striped, .takeBack))
        // A meal that was all weighed reads as it did.
        #expect(FoodText.entryRow(Fixture.foodDay(logged: ["breakfast"]).entries[0]).label == "WEIGHED · 43 G PROTEIN")
        #expect(FoodText.ingredientLabel(food.meals[0].ingredients[0]) == "LABEL · 175 G · 19 G PROTEIN")
    }

    @Test func addingAPartSaysAddNotLog() {
        #expect(
            CaptureText.scanBar(lookup: .found(BuiltFixture.bar), grams: 60, busy: false, adding: true)
                == ("MEASURED · 210 KCAL · 20 G PROTEIN", "ADD IT"))
        #expect(CaptureText.scanBar(lookup: .notFound, grams: 45, busy: true, adding: true) == ("SAVES THE LABEL, THEN ADDS 45 G", "ADDING"))
    }
}

/// Runs the app's own client against a backend started for the purpose,
/// for a meal built from parts: what is sent, and that the answers read.
/// The backend's LYFE_OLLAMA_URL should point at the stand-in that answers
/// every chat with rice and chicken (see the README). It logs a meal and
/// saves one, so point it at a scratch database:
/// `LYFE_LOCAL_SERVER=http://127.0.0.1:8799 LYFE_LOCAL_PASSWORD=... swift test --no-parallel`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LYFE_LOCAL_SERVER"] != nil))
struct BuiltMealsAgainstARealBackendTests {
    @Test func aMealIsBuiltEstimatedLoggedCorrectedAndSaved() async throws {
        let environment = ProcessInfo.processInfo.environment
        let world = World(address: environment["LYFE_LOCAL_SERVER"])
        let model = world.launch(transport: URLSessionTransport())
        world.time.now = Date()
        await model.signIn(password: environment["LYFE_LOCAL_PASSWORD"] ?? "")
        #expect(model.phase == .signedIn, "\(model.signInProblem ?? "")")
        let before = try #require(model.home?.food)

        // Typed both ways, a code nobody knows, and a photo sent ahead.
        model.openMealBuilder()
        model.changeDraft { $0.slot = .snack }
        model.addPart(MealPart(.food(BuiltFixture.banana)))
        model.addPart(MealPart(.food(BuiltFixture.coffee)))
        let code = String(format: "0629%09d", Int.random(in: 0..<1_000_000_000))
        model.addScan(code: code, grams: 175, product: nil)
        let jpeg = try #require(MealPhoto.prepare(CaptureFixture.cameraJPEG()))
        #expect(await model.addPhoto(note: "client check eggs", photo: jpeg) == .sent, "\(model.foodProblem ?? "")")
        let draft = try #require(model.mealDraft)
        let photo = try #require(draft.parts.last?.id)

        // The photo is estimated while the meal is not logged, and is on
        // no day meanwhile.
        for _ in 0..<40 where model.draftEstimates[photo]?.isKnown != true {
            try await Task.sleep(for: .milliseconds(250))
            await model.reloadHome()
        }
        #expect(model.draftEstimates[photo]?.kcal == 578)
        #expect(model.home?.food?.entries.contains { $0.id == photo || $0.id == draft.id } == false)
        #expect(model.home?.food?.kcal == before.kcal)
        #expect(draft.total(estimates: model.draftEstimates) == .init(kcal: 805, proteinG: 40.3, kcalEstimated: 578, unknown: 1))

        // Logged as one meal, the unknown code waiting for its label.
        #expect(await model.logMealDraft() == nil)
        var meal = try #require(model.home?.food?.entries.first { $0.id == draft.id })
        #expect((meal.from, meal.name, meal.slot) == (.built, "Snack", .snack))
        #expect(meal.parts?.map(\.name) == ["Banana", "Flat white", "Barcode \(code)", "client check eggs"])
        #expect((meal.kcal, meal.kcalEstimated, meal.figures) == (805, 578, .needsLabel))
        // The app's running total and the backend's figure are the same.
        #expect(model.home?.food?.kcal == before.kcal + 805)
        #expect(model.home?.food?.drafts?.contains { $0.id == photo } == false)

        let label = try FoodTyping.label(code: code, name: "Client check skyr", kcal: "63", protein: "11", serving: "").get()
        #expect(await model.setLabel(label) == nil)
        meal = try #require(model.home?.food?.entries.first { $0.id == draft.id })
        #expect((meal.kcal, meal.isKnown, meal.kcalLow, meal.kcalHigh) == (915, true, 337 + 380, 337 + 780))

        // A part joins it afterwards; the photo is corrected in place.
        let toast = Ingredient(name: "Client check toast", kcal: 80, proteinG: 3)
        #expect(await model.logTyped(toast, slot: meal.slot, partOf: meal.id) == .sent, "\(model.foodProblem ?? "")")
        #expect(await model.correctEstimate(photo, .portions(grams: nil, oil: .nothing)) == nil)
        meal = try #require(model.home?.food?.entries.first { $0.id == draft.id })
        #expect(meal.parts?.last?.name == "Client check toast")
        #expect((meal.kcal, meal.kcalEstimated) == (915 + 80 - 120, 458))

        // Saved for one tap: the photo's part stays an estimate.
        #expect(model.openMealEditor(savingLogged: meal.id))
        model.changeDraft { $0.name = "Client check snack" }
        let recipe = try #require(model.mealDraft)
        #expect(await model.saveMeal() == nil)
        let saved = try #require(model.home?.food?.meals.first { $0.id == recipe.mealId })
        #expect((saved.kcal, saved.kcalEstimated) == (875, 458))
        #expect(saved.kcal == recipe.portion().kcal)
        #expect(saved.ingredients.map(\.estimated) == [false, false, false, true, false])
        #expect(saved.ingredients[2].code == code)
        #expect(await model.logMeal(saved) == .sent)
        let tapped = try #require(model.home?.food?.entries.first { $0.mealId == saved.id })
        #expect((tapped.kcal, tapped.kcalEstimated, tapped.estimated) == (875, 458, true))

        // Taken back again, so the check can be run twice.
        #expect(await model.takeBackMeal(tapped.id) == nil)
        #expect(await model.takeBackMeal(meal.id) == nil)
        #expect(await model.removeMeal(saved.id) == nil)
        #expect(model.home?.food?.kcal == before.kcal)
    }
}
