import Foundation
import Testing

@testable import LyfeKit

/// Food icons: each food in the ingredient catalogue is shown by a small
/// drawing made on the Spark, asked for when it is looked at, fetched once
/// and kept on the phone. Until its own comes a food shows its category's.
@MainActor
struct FoodIconTests {
    let route = "GET /v1/food/icons"
    let waiting = StubBackend.Reply(status: 202, body: #"{"state": "waiting"}"#)

    /// A signed-in phone that has seen a day from a backend drawing icons
    /// in `look`, or drawing none.
    func world(look: Int? = 1) async -> (World, AppModel) {
        let world = World.signedIn()
        await show(look, to: world)
        let model = world.launch()
        await model.refresh()
        return (world, model)
    }

    func show(_ look: Int?, to world: World) async {
        let day = Fixture.food().replacingOccurrences(
            of: #""day": "2026-11-17","#, with: #""day": "2026-11-17", "icon_look": \#(look.map(String.init) ?? "null"),"#)
        world.backend.on("GET /v1/home", .ok(Fixture.home(food: day)))
    }

    @Test func everyCatalogueFoodHasACategoryWithADrawingAndNoEmoji() {
        let foods = CommonIngredient.library
        #expect(foods.allSatisfy { $0.categoryPicture != nil })
        #expect(Set(foods.compactMap(\.category)) == Set(CommonIngredient.categories))
        #expect(CommonIngredient.categories.count == 17)
        // What a category is drawn as is asked for like any food's name.
        #expect(CommonIngredient.categoryPictures.values.allSatisfy { !$0.isEmpty && $0.count <= 80 })
        #expect(foods.allSatisfy { $0.name.count <= 80 })
        let staple = CommonIngredient.staples[0]
        #expect((staple.name, staple.category, staple.categoryPicture) == ("Pork tenderloin, roasted", "Pork", "raw pork chop"))
    }

    @Test func anIconIsAskedForByNameUntilTheSparkHasDrawnItThenKept() async throws {
        let (world, model) = await world()
        world.backend.on(route, waiting, waiting, .ok("png bytes"))

        // Nothing on the phone yet; asking is what gets it drawn.
        #expect(model.keptFoodIcon(named: "Potato, baked") == nil)
        #expect(await model.askForFoodIcon(named: "Potato, baked") == .waiting)
        #expect(await model.askForFoodIcon(named: "Potato, baked") == .waiting)
        #expect(model.keptFoodIcon(named: "Potato, baked") == nil)
        #expect(await model.askForFoodIcon(named: "Potato, baked") == .drawn(Data("png bytes".utf8)))
        let asked = try #require(world.backend.lastRequest(route)?.url)
        let query = URLComponents(url: asked, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query == [URLQueryItem(name: "name", value: "Potato, baked"), URLQueryItem(name: "v", value: "1")])

        // Kept: shown at once from then on, with no backend, and by a new
        // launch, however the name is spelled.
        #expect(model.keptFoodIcon(named: "Potato, baked") == Data("png bytes".utf8))
        world.backend.goDown()
        #expect(await model.askForFoodIcon(named: "Potato, baked") == .drawn(Data("png bytes".utf8)))
        #expect(world.backend.requests.filter { $0 == route }.count == 3)
        #expect(world.launch().keptFoodIcon(named: " potato,  BAKED") == Data("png bytes".utf8))
        // Another food is another icon.
        #expect(model.keptFoodIcon(named: "Potato, boiled") == nil)
        #expect(await model.askForFoodIcon(named: "Potato, boiled") == .none)
    }

    @Test func anIconTheBackendWillNotDrawIsNotComing() async {
        let (world, model) = await world()
        // Given up on, or a name it has no icon for: not found.
        #expect(await model.askForFoodIcon(named: "Almonds") == .none)
        #expect(world.icons.picture(FoodIcon(name: "Almonds", look: 1)) == nil)

        // A backend that draws none says so with the day, and is not asked.
        let (plain, older) = await self.world(look: nil)
        plain.backend.on(route, .ok("png bytes"))
        #expect(await older.askForFoodIcon(named: "Almonds") == .none)
        #expect(!plain.backend.requests.contains(route))

        // Signed out, nothing is asked either.
        let nobody = World()
        #expect(await nobody.launch().askForFoodIcon(named: "Almonds") == .none)
        #expect(nobody.backend.requests.isEmpty)
    }

    @Test func aNewLookIsFetchedAgainAndTheOldIconShownUntilItComes() async throws {
        let (world, model) = await world(look: 1)
        world.backend.on(route, .ok("first look"), waiting, .ok("second look"))
        #expect(await model.askForFoodIcon(named: "Butter") == .drawn(Data("first look".utf8)))

        // The backend moves on to a second look.
        await show(2, to: world)
        await model.refresh()
        // Still shown as it was, rather than as nothing, while it is drawn.
        #expect(model.keptFoodIcon(named: "Butter") == Data("first look".utf8))
        #expect(await model.askForFoodIcon(named: "Butter") == .waiting)
        #expect(model.keptFoodIcon(named: "Butter") == Data("first look".utf8))
        #expect(await model.askForFoodIcon(named: "Butter") == .drawn(Data("second look".utf8)))
        #expect(model.keptFoodIcon(named: "Butter") == Data("second look".utf8))
        // Only the icon of now is kept.
        #expect(world.icons.picture(FoodIcon(name: "Butter", look: 1)) == nil)
        #expect(world.icons.picture(FoodIcon(name: "Butter", look: 2)) == Data("second look".utf8))
    }

    @Test func iconsAreKeptApartByTheWholeName() {
        let store = FoodIconStore(directory: Fixture.temporaryDirectory())
        let rice = FoodIcon(name: "Rice", look: 1)
        let riceCooked = FoodIcon(name: "Rice, cooked", look: 1)
        store.keep(Data("rice".utf8), for: rice)
        store.keep(Data("cooked".utf8), for: riceCooked)
        store.keep(Data("rice again".utf8), for: FoodIcon(name: "rice", look: 3))
        #expect(store.picture(rice) == nil)
        #expect(store.anyPicture(named: "RICE") == Data("rice again".utf8))
        #expect(store.picture(riceCooked) == Data("cooked".utf8))
        #expect(store.anyPicture(named: "Rice, raw") == nil)
    }
}

/// Runs the app's own client against a backend started for the purpose:
/// a food's icon is asked for, drawn and fetched, and a food typed as its
/// macros is logged and read back. The backend's LYFE_ILLUSTRATOR should
/// be the stand-in (see the README), and its database a scratch one:
/// `LYFE_LOCAL_SERVER=http://127.0.0.1:8799 LYFE_LOCAL_PASSWORD=... swift test`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LYFE_LOCAL_SERVER"] != nil))
struct IconsAndMacrosAgainstARealBackendTests {
    func signedIn() async throws -> (World, AppModel) {
        let environment = ProcessInfo.processInfo.environment
        let world = World(address: environment["LYFE_LOCAL_SERVER"])
        let model = world.launch(transport: URLSessionTransport())
        world.time.now = Date()
        await model.signIn(password: environment["LYFE_LOCAL_PASSWORD"] ?? "")
        #expect(model.phase == .signedIn, "\(model.signInProblem ?? "")")
        return (world, model)
    }

    @Test func aFoodsIconIsDrawnOnceAskedForAndKept() async throws {
        let (world, model) = try await signedIn()
        let look = try #require(model.home?.food?.iconLook, "set LYFE_ILLUSTRATOR to the stand-in (see the README)")
        // A name of its own each run, as the catalogue spells them, so it
        // is drawn afresh.
        let name = "Client check, raw, with salt & 2% \(Int.random(in: 0..<1_000_000))"
        var answer = await model.askForFoodIcon(named: name)
        #expect(answer == .waiting)
        for _ in 0..<60 where answer == .waiting {
            try await Task.sleep(for: .milliseconds(500))
            answer = await model.askForFoodIcon(named: name)
        }
        guard case .drawn(let png) = answer else {
            Issue.record("the icon was not drawn: \(answer)")
            return
        }
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(world.icons.picture(FoodIcon(name: name, look: look)) == png)
        #expect(model.keptFoodIcon(named: name) == png)
    }

    @Test func tenGramsOfFatTypedAsMacrosIsLoggedAsNinetyKcal() async throws {
        let (_, model) = try await signedIn()
        let fat = try FoodTyping.macros(name: "", protein: "", carbs: "", fat: "10").get()
        model.openMealBuilder()
        model.addPart(MealPart(.food(fat)))
        #expect(await model.logMealDraft() == nil)
        let id = try #require(model.receipt?.id)
        let meal = try #require(model.home?.food?.entries.first { $0.id == id })
        #expect((meal.kcal, meal.proteinG) == (90, 0))
        #expect(meal.estimated != true)
        // The meal's carbs and fat are its parts', added up on the phone.
        let part = try #require(meal.parts?.first)
        #expect((part.name, part.kcal, part.fatG, part.carbsG) == ("10 g fat", 90, 10, 0))
        #expect(FoodText.macros(meal.parts ?? []) == "Carbs 0 g · Fat 10 g")
        // Taken back again, so the check can be run twice.
        #expect(await model.takeBackMeal(id) == nil)
    }
}
