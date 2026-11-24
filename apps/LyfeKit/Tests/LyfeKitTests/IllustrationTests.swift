import Foundation
import Testing

@testable import LyfeKit

/// Meal illustrations: a photo drawn on the Spark is shown in its place,
/// fetched once, and until it comes the photo is shown as before.
@MainActor
struct IllustrationTests {
    /// A photo meal as the backend sends it, drawn or not.
    func dinner(illustrated: Bool?, version: Int = 1_795_000_000_000) throws -> FoodDay.Entry {
        var json = CaptureFixture.dinner
        if let illustrated {
            json = json.replacingOccurrences(of: #""has_photo": true,"#, with: #""has_photo": true, "illustrated": \#(illustrated), "illustration_version": \#(illustrated ? "\(version)" : "null"),"#)
        }
        return try JSONDecoder.lyfe.decode(FoodDay.Entry.self, from: Data(json.utf8))
    }

    func breakfast(illustrated: Bool) throws -> FoodDay.Entry {
        let json = BuiltFixture.meal().replacingOccurrences(
            of: #""has_photo": true,"#,
            with: #""has_photo": true, "illustrated": \#(illustrated), "illustration_version": \#(illustrated ? "7" : "null"),"#)
        return try JSONDecoder.lyfe.decode(FoodDay.Entry.self, from: Data(json.utf8))
    }

    let dinnerDrawn = Illustration(meal: CaptureFixture.dinnerID, version: 1_795_000_000_000)
    let photoDrawn = Illustration(meal: BuiltFixture.photoID, version: 7)

    @Test func aDrawnPhotoMealIsShownByItsIllustration() throws {
        let drawn = try dinner(illustrated: true)
        #expect(drawn.photo?.illustrated == true)
        #expect(drawn.illustration == dinnerDrawn)
        // Not drawn yet, or from a backend before illustrations: the photo.
        #expect(try dinner(illustrated: false).illustration == nil)
        let older = try dinner(illustrated: nil)
        #expect(older.photo?.illustrated == nil)
        #expect(older.illustration == nil)
    }

    @Test func aBuiltMealIsShownByItsDrawnPhoto() throws {
        let meal = try breakfast(illustrated: true)
        #expect(meal.illustration == photoDrawn)
        #expect(try breakfast(illustrated: false).illustration == nil)
        // Only photos are drawn: a part that is not one never stands for it.
        #expect(meal.parts?.first?.illustration == nil)
    }

    @Test func aRowCarriesItsIllustrationWithoutChangingItsFigures() throws {
        let drawn = FoodText.entryRow(try dinner(illustrated: true))
        let plain = FoodText.entryRow(try dinner(illustrated: false))
        #expect(drawn.picture == dinnerDrawn)
        #expect(plain.picture == nil)
        #expect((drawn.mark, drawn.title, drawn.label, drawn.value) == (plain.mark, plain.title, plain.label, plain.value))
        #expect(FoodText.entryRow(try breakfast(illustrated: true)).picture == photoDrawn)
        // The parts on a logged meal's screen show theirs too.
        let parts = try breakfast(illustrated: true).parts ?? []
        #expect(parts.map { FoodText.entryRow($0).picture } == [nil, nil, nil, photoDrawn])
    }

    @Test func aDayCachedBeforeIllustrationsStillLoads() throws {
        // The phone keeps the last day it saw; one written by an older app
        // has no illustrated field and must read as nothing drawn.
        let day = CaptureFixture.day(lunch: "known")
        #expect(day.entries.allSatisfy { $0.illustration == nil })
    }

    @Test func screensFollowTheSparkUntilAPhotoIsDrawn() throws {
        // Being estimated: looked at often, and drawn afterwards.
        let day = CaptureFixture.day()
        let waiting = SparkWait(day.entries)
        #expect(waiting.estimating)
        #expect(waiting.drawing == [CaptureFixture.dinnerID])
        // A described meal has no photo to draw; a drawn one is done.
        let drawn = SparkWait([try dinner(illustrated: true)])
        #expect((drawn.estimating, drawn.drawing) == (false, []))
        // A built meal waits for its photo part.
        #expect(SparkWait([try breakfast(illustrated: false)]).drawing == [BuiltFixture.mealID])
        #expect(SparkWait([try breakfast(illustrated: true)]).drawing == [])
    }

    @Test func anIllustrationIsFetchedOnceAndKeptOnThePhone() async throws {
        let world = World.signedIn()
        let id = dinnerDrawn
        world.backend.on(route, .ok("png bytes"))
        let model = world.launch()

        #expect(await model.mealIllustration(id) == Data("png bytes".utf8))
        #expect(world.illustrations.picture(id) == Data("png bytes".utf8))
        // The version goes with the request, so nothing in between can
        // answer with an older drawing.
        #expect(world.backend.lastRequest(route)?.url?.query == "v=1795000000000")
        // One version never changes: the second look needs no backend.
        world.backend.goDown()
        #expect(await model.mealIllustration(id) == Data("png bytes".utf8))
        #expect(world.backend.requests.filter { $0 == route }.count == 1)
        // A new launch finds it on the phone.
        #expect(await world.launch().mealIllustration(id) == Data("png bytes".utf8))
    }

    @Test func aMealDrawnAgainIsFetchedAgainAndTheOldDrawingDropped() async throws {
        let world = World.signedIn()
        world.backend.on(route, .ok("first look"), .ok("second look"))
        let model = world.launch()
        let first = try #require(try dinner(illustrated: true, version: 100).illustration)
        let second = try #require(try dinner(illustrated: true, version: 200).illustration)
        #expect(first != second)

        #expect(await model.mealIllustration(first) == Data("first look".utf8))
        #expect(await model.mealIllustration(second) == Data("second look".utf8))
        #expect(world.backend.requests.filter { $0 == route }.count == 2)
        // Only the drawing of now is kept.
        #expect(world.illustrations.picture(first) == nil)
        #expect(world.illustrations.picture(second) == Data("second look".utf8))
        // A row for the meal changes with it, so it shows the new one.
        #expect(FoodText.entryRow(try dinner(illustrated: true, version: 100)).picture != FoodText.entryRow(try dinner(illustrated: true, version: 200)).picture)
    }

    var route: String { "GET /v1/food/entries/\(CaptureFixture.dinnerID.uuidString.lowercased())/illustration" }

    @Test func anIllustrationNotDrawnYetIsAskedForAgainLater() async throws {
        let world = World.signedIn()
        let id = dinnerDrawn
        world.backend.on(route, StubBackend.Reply(status: 404, body: "{}"))
        let model = world.launch()

        #expect(await model.mealIllustration(id) == nil)
        #expect(world.illustrations.picture(id) == nil)
        world.backend.on(route, .ok("png bytes"))
        #expect(await model.mealIllustration(id) == Data("png bytes".utf8))
        // Offline and never fetched: nothing, and the photo is shown.
        let other = Illustration(meal: UUID(), version: 1)
        world.backend.goDown()
        #expect(await model.mealIllustration(other) == nil)
    }

    @Test func signedOutNothingIsFetched() async throws {
        let world = World()
        let model = world.launch()
        #expect(await model.mealIllustration(dinnerDrawn) == nil)
        #expect(world.backend.requests.isEmpty)
    }
}
