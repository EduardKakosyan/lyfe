import Foundation
import Testing

@testable import LyfeKit

@Suite struct FoodModelTests {
    @Test func foodFromTheBackendReads() throws {
        let home = try JSONDecoder.lyfe.decode(
            HomeSnapshot.self,
            from: Data(
                Fixture.home(food: Fixture.food(logged: ["breakfast"], days: 4, state: "kept", lastDays: "BBBKRKK")).utf8))
        let food = try #require(home.food)
        #expect(food.day == CalendarDay(year: 2026, month: 11, day: 17))
        #expect(food.target == .init(since: CalendarDay(year: 2026, month: 11, day: 2), kcal: 2500, proteinG: 170))
        #expect(food.kcal == 542)
        #expect(food.proteinG == 43.1)
        #expect(food.kcalLeft == 1958)
        #expect(food.proteinLeftG == 126.9)
        #expect(food.openSlots == [.lunch, .dinner])
        let entry = try #require(food.entries.first)
        #expect(entry.name == "Usual breakfast")
        #expect(entry.slot == .breakfast)
        #expect(entry.mealId == Fixture.breakfastID)
        #expect(entry.servings == 1)
        #expect(food.meals.map(\.name) == ["Usual breakfast", "Batch lunch"])
        #expect(food.meals[1].portions == 5)
        #expect(
            food.meals[0].ingredients.first == Ingredient(name: "Oats", grams: 80, kcalPer100g: 379, proteinPer100g: 13.2))
        #expect(food.streak.days == 4)
        #expect(food.streak.state == .kept)
        #expect(food.streak.loggedToday)
        #expect(food.streak.lastDays.map(\.state) == [.before, .before, .before, .kept, .recovered, .kept, .kept])
        #expect(food.streak.lastDays.last?.date == food.day)
    }

    @Test func homeFromBeforeFoodLoggingStillReads() throws {
        let old = try JSONDecoder.lyfe.decode(HomeSnapshot.self, from: Data(Fixture.home().utf8))
        #expect(old.food == nil)
    }

    @Test func aDayWithNoTargetAndNothingLoggedReads() {
        let food = Fixture.foodDay(meals: false, target: false)
        #expect(food.target == nil)
        #expect(food.kcalLeft == nil)
        #expect(food.proteinLeftG == nil)
        #expect(food.openSlots == [.breakfast, .lunch, .dinner])
        #expect(food.meals.isEmpty)
    }

    @Test func theCachedDayReadsBackTheSame() throws {
        // The recipe's per-100 g figures have digits in their names, which
        // the cache has to write and read back the same way.
        let food = Fixture.foodDay(logged: ["breakfast", "lunch"], days: 12, state: "kept", lastDays: "KKKKKKK")
        let data = try JSONEncoder.lyfe.encode(food)
        #expect(try JSONDecoder.lyfe.decode(FoodDay.self, from: data) == food)
    }
}

@MainActor
@Suite struct FoodLoggingTests {
    let breakfast = Fixture.foodDay().meals[0]
    let lunch = Fixture.foodDay().meals[1]

    /// The bodies sent to a route so far, as JSON objects.
    func sent(_ world: World, _ route: String) -> [[String: Any]] {
        world.backend.bodies(route).compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    func logged(_ meals: [String], state: String = "kept") -> StubBackend.Reply {
        .ok(Fixture.home(food: Fixture.food(logged: meals, days: 1, state: state, lastDays: "BBBBBBK")))
    }

    @Test func oneTapLogsAMealAndTheDayComesBack() async throws {
        let world = World.signedIn()
        world.backend.on("POST /v1/food/entries", logged(["breakfast"]))
        let model = world.launch()

        let outcome = await model.logMeal(breakfast)

        #expect(outcome == .sent)
        let body = try #require(sent(world, "POST /v1/food/entries").first)
        #expect(UUID(uuidString: body["id"] as? String ?? "") != nil)
        #expect(UUID(uuidString: body["meal_id"] as? String ?? "") == Fixture.breakfastID)
        #expect(body["eaten_at"] as? String == "2026-11-18T11:06:40Z")
        #expect(body["servings"] as? Double == 1)
        // Only the tap is sent: the backend works out the figures.
        #expect(Set(body.keys) == ["id", "meal_id", "eaten_at", "servings"])
        let request = try #require(world.backend.lastRequest("POST /v1/food/entries"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer device-token")
        #expect(model.home?.food?.kcal == 542)
        #expect(model.home?.food?.openSlots == [.lunch, .dinner])
        #expect(model.unsentFood.isEmpty)
        #expect(world.food.outbox().isEmpty)
    }

    @Test func aMealTappedWithNoConnectionIsKeptAndSentOnceOnTheNextRefresh() async throws {
        let world = World.signedIn()
        world.backend.goDown()
        let model = world.launch()

        #expect(await model.logMeal(breakfast) == .saved)
        #expect(model.isOffline)
        let kept = try #require(world.food.outbox().first)
        #expect(model.unsentFood == [kept])
        // Enough is kept to show it while it waits.
        #expect(kept.name == "Usual breakfast")
        #expect(kept.slot == .breakfast)
        #expect(kept.kcal == 542)

        // The app is closed and opened again a day later, with the server back.
        world.time.advance(86_400)
        let relaunched = world.launch()
        #expect(relaunched.unsentFood == [kept])
        world.backend.goDown(false)
        world.backend.on("POST /v1/food/entries", logged([], state: "on_track"))
        world.backend.on("GET /v1/home", logged([], state: "on_track"))
        world.backend.on("POST /v1/sync", .ok(Fixture.sources()))
        await relaunched.refresh()

        let bodies = sent(world, "POST /v1/food/entries")
        #expect(bodies.last?["id"] as? String == kept.id.uuidString)
        // The time is when it was tapped, so it counts for that day.
        #expect(bodies.last?["eaten_at"] as? String == "2026-11-18T11:06:40Z")
        #expect(relaunched.unsentFood.isEmpty)
        #expect(world.food.outbox().isEmpty)
    }

    @Test func anotherPortionIsSentAsThatManyServings() async throws {
        let world = World.signedIn()
        world.backend.goDown()
        let model = world.launch()

        await model.logMeal(lunch, servings: 1.5)

        let tap = try #require(model.unsentFood.first)
        #expect(tap.servings == 1.5)
        #expect(tap.kcal == 842)
        #expect(tap.proteinG == 73.5)
        #expect(sent(world, "POST /v1/food/entries").first?["servings"] as? Double == 1.5)
    }

    @Test func aMealTheServerRefusesIsDroppedAndSaidOutLoud() async {
        let world = World.signedIn()
        world.backend.on("POST /v1/food/entries", .init(status: 400, body: #"{"error": "bad_request"}"#))
        let model = world.launch()
        #expect(await model.logMeal(breakfast) == .refused)
        #expect(world.food.outbox().isEmpty)
        #expect(model.unsentFood.isEmpty)
        #expect(model.foodProblem == "The server would not log Usual breakfast (400).")
    }

    @Test func aServerFaultKeepsTheTapForLater() async {
        let world = World.signedIn()
        world.backend.on("POST /v1/food/entries", .init(status: 500, body: #"{"error": "internal"}"#))
        let model = world.launch()
        #expect(await model.logMeal(breakfast) == .saved)
        #expect(world.food.outbox().count == 1)
        #expect(model.foodProblem == "The server could not log a meal just now (500). It stays on this phone.")
    }

    @Test func aTapWhoseAnswerWasUnreadableIsNotSentAgain() async {
        let world = World.signedIn()
        world.backend.on("POST /v1/food/entries", .ok("<html>new server</html>"))
        let model = world.launch()
        #expect(await model.logMeal(breakfast) == .sent)
        #expect(world.food.outbox().isEmpty)
        #expect(model.refreshProblem != nil)
    }

    @Test func twoMealsWaitingAreSentInTheOrderTapped() async throws {
        let world = World.signedIn()
        world.backend.goDown()
        let model = world.launch()
        await model.logMeal(breakfast)
        world.time.advance(3600)
        await model.logMeal(lunch)
        #expect(model.unsentFood.map(\.name) == ["Usual breakfast", "Batch lunch"])

        world.backend.goDown(false)
        world.backend.on("POST /v1/food/entries", logged(["breakfast", "lunch"]))
        await model.sendUnsentFood()

        let meals = sent(world, "POST /v1/food/entries").suffix(2).compactMap { UUID(uuidString: $0["meal_id"] as? String ?? "") }
        #expect(meals == [Fixture.breakfastID, Fixture.lunchID])
        #expect(model.unsentFood.isEmpty)
        #expect(model.home?.food?.kcal == 1103)
    }

    @Test func aTapStillOnThisPhoneIsTakenBackWithoutTheServer() async {
        let world = World.signedIn()
        world.backend.goDown()
        let model = world.launch()
        await model.logMeal(breakfast)
        let tap = model.unsentFood[0]
        let before = world.backend.requests.count

        #expect(await model.takeBackMeal(tap.id) == nil)

        #expect(model.unsentFood.isEmpty)
        #expect(world.food.outbox().isEmpty)
        #expect(world.backend.requests.count == before)
    }

    @Test func aLoggedMealIsTakenBackOnTheServer() async throws {
        let world = World.signedIn()
        world.backend.on("POST /v1/food/entries", logged(["breakfast"]))
        let model = world.launch()
        await model.logMeal(breakfast)
        let entry = try #require(model.home?.food?.entries.first)
        let route = "DELETE /v1/food/entries/\(entry.id.uuidString.lowercased())"
        world.backend.on(route, logged([], state: "not_started"))

        #expect(await model.takeBackMeal(entry.id) == nil)

        #expect(world.backend.requests.last == route)
        #expect(model.home?.food?.entries.isEmpty == true)

        // With no connection it stays, and says why.
        world.backend.goDown()
        let problem = await model.takeBackMeal(entry.id)
        #expect(problem?.hasPrefix("Could not take that back: can't reach the server") == true)
    }

    @Test func savingAMealSendsTheRecipeAndClosesTheEditor() async throws {
        let world = World.signedIn()
        let model = world.launch()
        model.openMealEditor()
        var draft = try #require(model.mealDraft)
        #expect(draft.isNew)
        #expect(model.screen == .food)
        draft.name = " Usual breakfast "
        draft.slot = .breakfast
        draft.ingredients = [Ingredient(name: "Oats", grams: 80, kcalPer100g: 379, proteinPer100g: 13.2)]
        let route = "PUT /v1/food/meals/\(draft.id.uuidString.lowercased())"
        world.backend.on(route, .ok(Fixture.home(food: Fixture.food())))

        #expect(await model.saveMeal(draft) == nil)

        let body = try #require(sent(world, route).first)
        #expect(body["name"] as? String == "Usual breakfast")
        #expect(body["slot"] as? String == "breakfast")
        #expect(body["portions"] as? Int == 1)
        let ingredient = try #require((body["ingredients"] as? [[String: Any]])?.first)
        #expect(ingredient["name"] as? String == "Oats")
        #expect(ingredient["grams"] as? Double == 80)
        #expect(ingredient["kcal_per_100g"] as? Double == 379)
        #expect(ingredient["protein_per_100g"] as? Double == 13.2)
        #expect(model.mealDraft == nil)
        #expect(model.home?.food?.meals.count == 2)
    }

    @Test func aMealWithNothingInItIsNotSent() async {
        let world = World.signedIn()
        let model = world.launch()
        model.openMealEditor()
        var draft = model.mealDraft!
        #expect(await model.saveMeal(draft) == "Give the meal a name.")
        draft.name = "Oats"
        #expect(await model.saveMeal(draft) == "Add what goes into it.")
        #expect(world.backend.requests.isEmpty)
        #expect(model.mealDraft != nil)
    }

    @Test func savingAMealNeedsAConnectionAndKeepsTheEditorOpenWithoutOne() async {
        let world = World.signedIn()
        world.backend.goDown()
        let model = world.launch()
        model.openMealEditor(lunch)
        let draft = model.mealDraft!
        #expect(!draft.isNew)
        #expect(draft.id == Fixture.lunchID)
        #expect(draft.portions == 5)

        let problem = await model.saveMeal(draft)

        #expect(problem?.hasPrefix("Could not save the meal: can't reach the server") == true)
        #expect(model.mealDraft != nil)
        #expect(model.isOffline)
    }

    @Test func aRecipeTheServerRefusesIsSaidOutLoud() async {
        let world = World.signedIn()
        let model = world.launch()
        model.openMealEditor(lunch)
        let draft = model.mealDraft!
        world.backend.on(
            "PUT /v1/food/meals/\(draft.id.uuidString.lowercased())", .init(status: 400, body: #"{"error": "bad_request"}"#))
        #expect(await model.saveMeal(draft) == "The server would not save the meal (400).")
        #expect(model.mealDraft != nil)
    }

    @Test func removingAMealClosesTheEditor() async {
        let world = World.signedIn()
        let model = world.launch()
        model.openMealEditor(lunch)
        let route = "DELETE /v1/food/meals/\(Fixture.lunchID.uuidString.lowercased())"
        world.backend.on(route, .ok(Fixture.home(food: Fixture.food(meals: false))))

        #expect(await model.removeMeal(Fixture.lunchID) == nil)

        #expect(world.backend.requests == [route])
        #expect(model.mealDraft == nil)
        #expect(model.home?.food?.meals.isEmpty == true)
    }

    @Test func settingTheTargetsSendsBothFiguresAndClosesTheEntry() async throws {
        let world = World.signedIn()
        world.backend.on("PUT /v1/food/targets", .ok(Fixture.home(food: Fixture.food())))
        let model = world.launch()
        model.openTargets()
        #expect(model.isEnteringTargets)

        #expect(await model.setFoodTargets(FoodTargets(kcal: 2500, proteinG: 170)) == nil)

        let body = try #require(sent(world, "PUT /v1/food/targets").first)
        #expect(body["kcal"] as? Int == 2500)
        #expect(body["protein_g"] as? Int == 170)
        #expect(!model.isEnteringTargets)
        #expect(model.home?.food?.target?.kcal == 2500)
    }

    @Test func foodOpensFromHomeAndClosesBackToIt() async {
        let world = World.signedIn()
        world.backend.on("POST /v1/auth/sign-out", .init(status: 204, body: ""))
        let model = world.launch()
        model.openFood()
        #expect(model.screen == .food)
        model.openMealEditor()
        model.closeMealEditor()
        #expect(model.screen == .food)
        #expect(model.mealDraft == nil)
        model.openTargets()
        model.closeFood()
        #expect(model.screen == .home)
        #expect(!model.isEnteringTargets)

        model.openMealEditor()
        await model.signOut()
        #expect(model.screen == .home)
        #expect(model.mealDraft == nil)
    }

    @Test func aSessionThatHasEndedSignsOutInsteadOfLogging() async {
        let world = World.signedIn()
        world.backend.on("POST /v1/food/entries", .init(status: 401, body: #"{"error": "unauthorized"}"#))
        let model = world.launch()
        await model.logMeal(breakfast)
        #expect(model.phase == .signedOut)
        // The tap is still on the phone for after signing in again.
        #expect(world.food.outbox().count == 1)
    }
}

@Suite struct FoodTypingTests {
    @Test func figuresAreReadHoweverTheDecimalIsTyped() {
        #expect(FoodTyping.number("80") == 80)
        #expect(FoodTyping.number(" 13,2 ") == 13.2)
        #expect(FoodTyping.number("50.4") == 50.4)
        for slip in ["", "abc", "-5", "1.234", "1e3", "12 g", "123456"] {
            #expect(FoodTyping.number(slip) == nil, "\(slip)")
        }
    }

    @Test func anIngredientIsReadFromItsFourFields() {
        let oats = FoodTyping.ingredient(name: " Oats ", grams: "80", kcal: "379", protein: "13,2")
        #expect(oats == .success(Ingredient(name: "Oats", grams: 80, kcalPer100g: 379, proteinPer100g: 13.2)))
        // Oil has no protein; zero is a figure, not a gap.
        let oil = FoodTyping.ingredient(name: "Olive oil", grams: "15", kcal: "884", protein: "0")
        #expect(oil == .success(Ingredient(name: "Olive oil", grams: 15, kcalPer100g: 884, proteinPer100g: 0)))
    }

    @Test func aSlipInAnIngredientIsNamed() {
        func slip(_ name: String, _ grams: String, _ kcal: String, _ protein: String) -> String? {
            if case .failure(let slip) = FoodTyping.ingredient(name: name, grams: grams, kcal: kcal, protein: protein) {
                return slip.message
            }
            return nil
        }
        #expect(slip(" ", "80", "379", "13.2") == "Name the ingredient")
        #expect(slip("Oats", "", "379", "13.2") == "Type its weight in grams, like 80")
        #expect(slip("Oats", "0", "379", "13.2") == "Type its weight in grams, like 80")
        // The decimal point slipped: nothing has 3790 kcal in 100 g.
        #expect(slip("Oats", "80", "3790", "13.2") == "Type the kcal in 100 g from the label, 0 to 900")
        #expect(slip("Oats", "80", "379", "132") == "Type the protein in 100 g from the label, 0 to 100")
        #expect(slip("Oats", "80", "379", "") == "Type the protein in 100 g from the label, 0 to 100")
    }

    @Test func targetsAreTwoWholeFiguresInRange() {
        #expect(FoodTyping.targets(kcal: "2500", protein: "170") == .success(FoodTargets(kcal: 2500, proteinG: 170)))
        func slip(_ kcal: String, _ protein: String) -> String? {
            if case .failure(let slip) = FoodTyping.targets(kcal: kcal, protein: protein) { return slip.message }
            return nil
        }
        #expect(slip("250", "170") == "Type the calories for a day, 800 to 10000")
        #expect(slip("", "170") == "Type the calories for a day, 800 to 10000")
        #expect(slip("2500.5", "170") == "Type the calories for a day, 800 to 10000")
        #expect(slip("2500", "1700") == "Type the protein for a day in grams, 20 to 500")
        #expect(slip("2500", "") == "Type the protein for a day in grams, 20 to 500")
    }

    @Test func theEditorPreviewsAPortionTheWayTheServerWorksItOut() {
        // The same recipes as the backend's tests, and the same answers.
        var breakfast = MealDraft()
        breakfast.ingredients = [
            Ingredient(name: "Oats", grams: 80, kcalPer100g: 379, proteinPer100g: 13.2),
            Ingredient(name: "Milk 2%", grams: 250, kcalPer100g: 50.4, proteinPer100g: 3.4),
            Ingredient(name: "Whey", grams: 30, kcalPer100g: 377, proteinPer100g: 80),
        ]
        #expect(breakfast.portion == (542, 43.1))

        var lunch = MealDraft()
        lunch.portions = 5
        lunch.ingredients = [
            Ingredient(name: "Chicken thigh", grams: 900, kcalPer100g: 177, proteinPer100g: 24),
            Ingredient(name: "Rice, dry", grams: 300, kcalPer100g: 360, proteinPer100g: 7),
            Ingredient(name: "Olive oil", grams: 15, kcalPer100g: 884, proteinPer100g: 0),
            Ingredient(name: "Frozen vegetables", grams: 400, kcalPer100g: 0, proteinPer100g: 2),
        ]
        #expect(lunch.portion == (561, 49.0))
        #expect(MealDraft.kcal(of: lunch.ingredients[0]) == 1593)
        #expect(MealDraft().portion == (0, 0))
    }

    @Test func aDraftSaysWhatStillStopsItBeingSaved() {
        var draft = MealDraft()
        #expect(draft.missing == "Give the meal a name")
        draft.name = String(repeating: "x", count: 61)
        #expect(draft.missing == "The name is too long")
        draft.name = "Oats"
        #expect(draft.missing == "Add what goes into it")
        draft.ingredients = [Ingredient(name: "Oats", grams: 80, kcalPer100g: 379, proteinPer100g: 13.2)]
        #expect(draft.missing == nil)
    }

    @Test func changingASavedMealKeepsItsIdSoTheRecipeIsReplaced() {
        let meal = Fixture.foodDay().meals[1]
        let draft = MealDraft(editing: meal)
        #expect(draft.id == meal.id)
        #expect(!draft.isNew)
        #expect(draft.name == "Batch lunch")
        #expect(draft.slot == .lunch)
        #expect(draft.portions == 5)
        #expect(draft.ingredients == meal.ingredients)
        #expect(MealDraft().id != MealDraft().id)
    }
}

@Suite struct FoodStoreTests {
    @Test func tapsAreKeptOldestFirstUntilConfirmed() {
        let store = FoodStore(directory: Fixture.temporaryDirectory())
        let meals = Fixture.foodDay().meals
        let first = MealTap(eatenAt: Date(timeIntervalSince1970: 1_795_000_000.123), meal: meals[0])
        let second = MealTap(eatenAt: Date(timeIntervalSince1970: 1_795_003_600), meal: meals[1], servings: 2)
        store.enqueue(first)
        store.enqueue(second)
        store.enqueue(first)
        #expect(store.outbox() == [first, second])
        store.remove(first.id)
        #expect(store.outbox() == [second])
        store.remove(second.id)
        #expect(store.outbox().isEmpty)
    }
}

@Suite struct FoodTextTests {
    typealias Row = FoodText.Row

    @Test func caloriesAreSetWithACommaWhateverTheRegion() {
        #expect(FoodText.kcal(0) == "0")
        #expect(FoodText.kcal(542) == "542")
        #expect(FoodText.kcal(1640) == "1,640")
        #expect(FoodText.kcal(10_000) == "10,000")
        #expect(FoodText.kcal(-305) == "−305")
        #expect(FoodText.grams(43.1) == "43")
        #expect(FoodText.grams(49.5) == "50")
        #expect(FoodText.plain(80) == "80")
        #expect(FoodText.plain(13.2) == "13.2")
        #expect(FoodText.plain(50.45) == "50.45")
    }

    @Test func portionsAreSaidTheWayTheyAreEaten() {
        #expect(FoodText.portions(0.5) == "½ PORTION")
        #expect(FoodText.portions(1) == "1 PORTION")
        #expect(FoodText.portions(1.5) == "1½ PORTIONS")
        #expect(FoodText.portions(2) == "2 PORTIONS")
        #expect(FoodText.portions(4) == "4 PORTIONS")
    }

    @Test func theHeaderSetsTheDayAgainstItsTargets() {
        let day = Fixture.foodDay(logged: ["breakfast", "lunch"])
        #expect(FoodText.targetLabel(day) == "TUE · TARGET 2,500")
        #expect(FoodText.leftLine(day) == "1,397 KCAL LEFT")
        #expect(FoodText.proteinLine(day) == "92 OF 170 G")
        #expect(FoodText.openLine(day) == "DINNER OPEN")
        #expect(FoodText.openLine(Fixture.foodDay(logged: ["breakfast"])) == "LUNCH, DINNER OPEN")
        #expect(FoodText.openLine(Fixture.foodDay()) == "NOTHING LOGGED YET")

        var over = day
        over.kcalLeft = -140
        #expect(FoodText.leftLine(over) == "140 KCAL OVER")
        over.kcalLeft = 0
        over.openSlots = []
        #expect(FoodText.leftLine(over) == "KCAL · ON TARGET")
        #expect(FoodText.openLine(over) == "ALL MEALS LOGGED")
    }

    @Test func withoutTargetsTheHeaderOnlyCounts() {
        let day = Fixture.foodDay(logged: ["breakfast"], target: false)
        #expect(FoodText.targetLabel(day) == "TUE · NO TARGET YET")
        #expect(FoodText.leftLine(day) == "KCAL LOGGED TODAY")
        #expect(FoodText.proteinLine(day) == "43 G")
        #expect(FoodText.targetsLine(nil) == "Targets · none yet")
        #expect(FoodText.targetsLine(Fixture.foodDay().target) == "Targets · 2,500 KCAL · 170 G PROTEIN")
    }

    @Test func barsFillTowardTheTargetAndStopThere() {
        #expect(FoodText.fraction(1250, of: 2500) == 0.5)
        #expect(FoodText.fraction(3000, of: 2500) == 1)
        #expect(FoodText.fraction(0, of: 2500) == 0)
        #expect(FoodText.fraction(100, of: 0) == 0)
    }

    @Test func aMealNotLoggedIsAQuestionMarkNeverZero() {
        let rows = FoodText.rows(Fixture.foodDay(logged: ["breakfast"]), unsent: [])
        #expect(rows.map(\.title) == ["Usual breakfast", "LUNCH", "DINNER", "SNACKS"])
        #expect(rows.map(\.value) == ["542", "?", "?", "?"])
        #expect(rows.map(\.label) == ["WEIGHED · 43 G PROTEIN", "NOTHING LOGGED", "NOTHING LOGGED", "NOTHING LOGGED"])
        #expect(rows.map(\.mark) == [.solid, .outline, .outline, .outline])
        #expect(rows.map(\.dim) == [false, true, true, true])
        // Only what was logged can be taken back.
        #expect(rows.map { $0.entry != nil } == [true, false, false, false])
        #expect(FoodText.entryLabel(servings: 1.5, proteinG: 73.5) == "WEIGHED · 1½ PORTIONS · 74 G PROTEIN")
    }

    @Test func aMealStillOnThisPhoneFillsItsSlotButIsMarkedAsNotCounted() {
        let day = Fixture.foodDay(logged: ["breakfast"])
        let tap = MealTap(eatenAt: Date(), meal: day.meals[1])
        let rows = FoodText.rows(day, unsent: [tap])
        #expect(rows.map(\.title) == ["Usual breakfast", "Batch lunch", "DINNER", "SNACKS"])
        #expect(rows[1].label == "ON THIS PHONE · NOT COUNTED YET")
        #expect(rows[1].value == "561")
        #expect(rows[1].dim)
        #expect(rows[1].entry == tap.id)
        #expect(FoodText.unsent(1) == "1 meal is saved on this phone. It is sent when the server can be reached.")
        #expect(FoodText.unsent(2) == "2 meals are saved on this phone. They are sent when the server can be reached.")
    }

    @Test func aSavedMealSaysWhatATapLogs() {
        let meals = Fixture.foodDay().meals
        let breakfast = FoodText.mealRow(meals[0])
        #expect(breakfast.title == "Usual breakfast")
        #expect(breakfast.label == "BREAKFAST · 43 G PROTEIN")
        #expect(breakfast.value == "542")
        #expect(FoodText.mealRow(meals[1]).label == "LUNCH · 1 OF 5 · 49 G PROTEIN")
    }

    @Test func theBarLogsTheNextOpenMealWithOneTap() {
        let morning = Fixture.foodDay()
        let first = FoodText.bar(morning, unsent: [])
        #expect(first.big == "USUAL BREAKFAST")
        #expect(first.small == "LOG BREAKFAST · 542 KCAL · 43 G · ONE TAP")
        #expect(first.action == .log(morning.meals[0]))
        #expect(first.mark == "+")

        let afterBreakfast = Fixture.foodDay(logged: ["breakfast"])
        let second = FoodText.bar(afterBreakfast, unsent: [])
        #expect(second.big == "BATCH LUNCH")
        #expect(second.action == .log(afterBreakfast.meals[1]))

        // Breakfast tapped with no connection: the bar still moves on.
        let tap = MealTap(eatenAt: Date(), meal: morning.meals[0])
        #expect(FoodText.bar(morning, unsent: [tap]).big == "BATCH LUNCH")
    }

    @Test func withNothingLeftToTapTheBarSaysWhereTheDayStands() {
        // Dinner has no saved meal, so it stays open and is said to be.
        let day = Fixture.foodDay(logged: ["breakfast", "lunch"])
        let bar = FoodText.bar(day, unsent: [])
        #expect(bar.big == "LOGGED SO FAR")
        #expect(bar.small == "DINNER OPEN · 1,397 KCAL LEFT")
        #expect(bar.action == .none)

        var done = day
        done.openSlots = []
        #expect(FoodText.bar(done, unsent: []) == .init(small: "1,103 KCAL · 1,397 KCAL LEFT", big: "DAY LOGGED", action: .none))
    }

    @Test func beforeAnythingIsSetUpTheBarLeadsThere() {
        let empty = Fixture.foodDay(meals: false, target: false)
        #expect(FoodText.bar(empty, unsent: []).action == .newMeal)
        #expect(FoodText.bar(empty, unsent: []).big == "ADD A SAVED MEAL")

        let noTarget = Fixture.foodDay(logged: ["breakfast", "lunch"], target: false)
        #expect(FoodText.bar(noTarget, unsent: []).action == .setTargets)
        #expect(FoodText.bar(noTarget, unsent: []).big == "SET YOUR TARGETS")
    }

    @Test func theBandOnHomeSaysWhereTheStreakStands() {
        func lines(_ state: String, days: Int, lastDays: String, best: Int = 0) -> [String?] {
            let band = FoodText.bandLines(
                Fixture.foodDay(days: days, state: state, lastDays: lastDays, previousBest: best))
            return [band.headline, band.detail]
        }
        #expect(lines("kept", days: 12, lastDays: "KKKKKKK") == ["DAYS IN A ROW", "TODAY LOGGED"])
        #expect(lines("kept", days: 1, lastDays: "BBBBBBK") == ["DAY IN A ROW", "TODAY LOGGED"])
        #expect(lines("on_track", days: 11, lastDays: "KKKKKKO") == ["DAYS IN A ROW", "LOG TODAY"])
        #expect(lines("recovering", days: 10, lastDays: "KKKKKAO") == ["RECOVERING", "ONE MEAL TODAY KEEPS IT"])
        #expect(lines("not_started", days: 0, lastDays: "BBBBBBO") == ["NO STREAK YET", "ONE MEAL LOGGED STARTS ONE"])
        #expect(lines("not_started", days: 0, lastDays: "KKKKMMO", best: 9) == ["STARTING AGAIN", "ONE MEAL LOGGED STARTS ONE"])
    }

    @Test func theLastSevenDaysAreSquaresWithStripesForARecoveredDay() {
        let streak = Fixture.foodDay(days: 4, state: "recovering", lastDays: "BMKRKAO").streak
        #expect(FoodText.squares(streak) == [.outline, .outline, .solid, .striped, .solid, .striped, .outline])
        #expect(FoodText.daysSpoken(streak) == "Last 7 days: 2 logged")
    }

    @Test func homeShowsTodayAgainstTheTargetsUnderTheBand() {
        #expect(FoodText.homeLine(Fixture.foodDay(logged: ["breakfast", "lunch"])) == "1,103 OF 2,500 KCAL · 92 OF 170 G")
        #expect(FoodText.homeLine(Fixture.foodDay(logged: ["breakfast"], target: false)) == "542 KCAL · 43 G LOGGED")
        #expect(
            FoodText.bandSpoken(Fixture.foodDay(days: 12, state: "kept", lastDays: "KKKKKKK"))
                == "Fuel: 12 days in a row. Today is logged.")
        #expect(
            FoodText.bandSpoken(Fixture.foodDay(days: 3, state: "recovering", lastDays: "BBKKKAO"))
                == "Fuel: 3 days in a row, recovering. Nothing logged today.")
    }

    @Test func weeklyBandsKeepTheirSquares() {
        #expect(HomeText.squares(done: 1, target: 4) == [.solid, .outline, .outline, .outline])
        // A fifth session shows as a fifth square.
        #expect(HomeText.squares(done: 5, target: 4) == [.solid, .solid, .solid, .solid, .solid])
    }

    @Test func theEditorsBarShowsThePortionOrWhatIsMissing() {
        var draft = MealDraft()
        #expect(FoodText.editorBar(draft, saving: false) == ("GIVE THE MEAL A NAME", "SAVE MEAL"))
        draft.name = "Batch lunch"
        draft.portions = 5
        draft.ingredients = [Ingredient(name: "Chicken thigh", grams: 900, kcalPer100g: 177, proteinPer100g: 24)]
        #expect(FoodText.editorBar(draft, saving: false) == ("EACH OF 5 PORTIONS · 319 KCAL · 43 G PROTEIN", "SAVE MEAL"))
        draft.portions = 1
        #expect(FoodText.editorBar(draft, saving: true) == ("THE PORTION · 1,593 KCAL · 216 G PROTEIN", "SAVING"))
        #expect(
            FoodText.ingredientLabel(draft.ingredients[0]) == "900 G · 177 KCAL · 24 G PER 100 G")
        #expect(FoodText.targetsNow(nil) == "No targets yet")
        #expect(FoodText.targetsNow(Fixture.foodDay().target) == "Now 2,500 KCAL · 170 G · since 2 NOV")
    }
}

/// Runs the app's own client against a backend started for the purpose,
/// to prove the two agree on what is sent and answered: the recipe's
/// field names, the portion the editor previews, and a tap counted once.
/// It saves a meal, sets targets and logs entries, so point it at a
/// scratch database, never the real one:
/// `LYFE_LOCAL_SERVER=http://127.0.0.1:8799 LYFE_LOCAL_PASSWORD=... swift test`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LYFE_LOCAL_SERVER"] != nil))
struct FoodAgainstARealBackendTests {
    @Test func aMealTypedHereIsWorkedOutThereAndATapIsLoggedOnce() async throws {
        let environment = ProcessInfo.processInfo.environment
        let world = World(address: environment["LYFE_LOCAL_SERVER"])
        let model = world.launch(transport: URLSessionTransport())
        world.time.now = Date()
        await model.signIn(password: environment["LYFE_LOCAL_PASSWORD"] ?? "")
        #expect(model.phase == .signedIn, "\(model.signInProblem ?? "")")

        // A batch typed the way the editor reads it.
        model.openMealEditor()
        var draft = try #require(model.mealDraft)
        draft.name = "Client check lunch"
        draft.slot = .lunch
        draft.portions = 5
        draft.ingredients = try [
            FoodTyping.ingredient(name: "Chicken thigh", grams: "900", kcal: "177", protein: "24").get(),
            FoodTyping.ingredient(name: "Rice, dry", grams: "300", kcal: "360", protein: "7").get(),
            FoodTyping.ingredient(name: "Olive oil", grams: "15", kcal: "884", protein: "0").get(),
            FoodTyping.ingredient(name: "Frozen vegetables", grams: "400", kcal: "0", protein: "2,0").get(),
        ]
        let problem = await model.saveMeal(draft)
        #expect(problem == nil)
        let meal = try #require(model.home?.food?.meals.first { $0.id == draft.id })
        #expect(meal.name == "Client check lunch")
        #expect(meal.ingredients == draft.ingredients)
        // The editor's preview and the backend's figure are the same.
        #expect(meal.kcal == draft.portion.kcal)
        #expect(meal.proteinG == draft.portion.proteinG)
        #expect((meal.kcal, meal.proteinG) == (561, 49.0))

        #expect(await model.setFoodTargets(FoodTargets(kcal: 2500, proteinG: 170)) == nil)
        let target = try #require(model.home?.food?.target)
        #expect((target.kcal, target.proteinG) == (2500, 170))
        let before = try #require(model.home?.food)

        // One tap.
        #expect(await model.logMeal(meal) == .sent, "\(model.foodProblem ?? model.offlineReason ?? "")")
        var food = try #require(model.home?.food)
        let entry = try #require(food.entries.first { $0.mealId == meal.id })
        #expect((entry.name, entry.slot, entry.kcal, entry.proteinG) == ("Client check lunch", .lunch, 561, 49.0))
        #expect(food.kcal == before.kcal + 561)
        #expect(food.kcalLeft == 2500 - food.kcal)
        #expect(!food.openSlots.contains(.lunch))
        #expect(food.streak.loggedToday)
        #expect(food.streak.lastDays.last?.state == .kept)

        // The same tap twice, as after a lost answer: logged once. It is
        // a minute after the first, so the two keep their order.
        world.time.advance(60)
        let tap = MealTap(eatenAt: world.time.now, meal: meal, servings: 1.5)
        world.food.enqueue(tap)
        await model.sendUnsentFood()
        world.food.enqueue(tap)
        await model.sendUnsentFood()
        food = try #require(model.home?.food)
        #expect(food.entries.filter { $0.mealId == meal.id }.map(\.kcal) == [561, tap.kcal])
        #expect(food.kcal == before.kcal + 561 + 842)

        // A slip taken back.
        #expect(await model.takeBackMeal(tap.id) == nil)
        #expect(await model.takeBackMeal(entry.id) == nil)
        food = try #require(model.home?.food)
        #expect(food.kcal == before.kcal)
        #expect(food.entries.filter { $0.mealId == meal.id }.isEmpty)

        // The meal removed again, so the check can be run twice.
        #expect(await model.removeMeal(meal.id) == nil)
        #expect(model.home?.food?.meals.contains { $0.id == meal.id } == false)
    }
}
