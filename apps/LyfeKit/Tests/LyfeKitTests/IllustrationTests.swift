import Foundation
import Testing

@testable import LyfeKit

/// Meal illustrations: a photo drawn on the Spark is shown in its place,
/// fetched once, and until it comes the photo is shown as before.
@MainActor
struct IllustrationTests {
    /// A photo meal as the backend sends it, drawn or not.
    func dinner(illustrated: Bool?) throws -> FoodDay.Entry {
        var json = CaptureFixture.dinner
        if let illustrated {
            json = json.replacingOccurrences(of: #""has_photo": true,"#, with: #""has_photo": true, "illustrated": \#(illustrated),"#)
        }
        return try JSONDecoder.lyfe.decode(FoodDay.Entry.self, from: Data(json.utf8))
    }

    func breakfast(illustrated: Bool) throws -> FoodDay.Entry {
        let json = BuiltFixture.meal().replacingOccurrences(
            of: #""has_photo": true,"#, with: #""has_photo": true, "illustrated": \#(illustrated),"#)
        return try JSONDecoder.lyfe.decode(FoodDay.Entry.self, from: Data(json.utf8))
    }

    @Test func aDrawnPhotoMealIsShownByItsIllustration() throws {
        let drawn = try dinner(illustrated: true)
        #expect(drawn.photo?.illustrated == true)
        #expect(drawn.illustrationID == CaptureFixture.dinnerID)
        // Not drawn yet, or from a backend before illustrations: the photo.
        #expect(try dinner(illustrated: false).illustrationID == nil)
        let older = try dinner(illustrated: nil)
        #expect(older.photo?.illustrated == nil)
        #expect(older.illustrationID == nil)
    }

    @Test func aBuiltMealIsShownByItsDrawnPhoto() throws {
        let meal = try breakfast(illustrated: true)
        #expect(meal.illustrationID == BuiltFixture.photoID)
        #expect(try breakfast(illustrated: false).illustrationID == nil)
        // Only photos are drawn: a part that is not one never stands for it.
        #expect(meal.parts?.first?.illustrationID == nil)
    }

    @Test func aRowCarriesItsIllustrationWithoutChangingItsFigures() throws {
        let drawn = FoodText.entryRow(try dinner(illustrated: true))
        let plain = FoodText.entryRow(try dinner(illustrated: false))
        #expect(drawn.picture == CaptureFixture.dinnerID)
        #expect(plain.picture == nil)
        #expect((drawn.mark, drawn.title, drawn.label, drawn.value) == (plain.mark, plain.title, plain.label, plain.value))
        #expect(FoodText.entryRow(try breakfast(illustrated: true)).picture == BuiltFixture.photoID)
        // The parts on a logged meal's screen show theirs too.
        let parts = try breakfast(illustrated: true).parts ?? []
        #expect(parts.map { FoodText.entryRow($0).picture } == [nil, nil, nil, BuiltFixture.photoID])
    }

    @Test func aDayCachedBeforeIllustrationsStillLoads() throws {
        // The phone keeps the last day it saw; one written by an older app
        // has no illustrated field and must read as nothing drawn.
        let day = CaptureFixture.day(lunch: "known")
        #expect(day.entries.allSatisfy { $0.illustrationID == nil })
    }

    @Test func anIllustrationIsFetchedOnceAndKeptOnThePhone() async throws {
        let world = World.signedIn()
        let id = CaptureFixture.dinnerID
        let route = "GET /v1/food/entries/\(id.uuidString.lowercased())/illustration"
        world.backend.on(route, .ok("png bytes"))
        let model = world.launch()

        #expect(await model.mealIllustration(id) == Data("png bytes".utf8))
        #expect(world.illustrations.illustration(id) == Data("png bytes".utf8))
        // Drawn once, it never changes: the second look needs no backend.
        world.backend.goDown()
        #expect(await model.mealIllustration(id) == Data("png bytes".utf8))
        #expect(world.backend.requests.filter { $0 == route }.count == 1)
        // A new launch finds it on the phone.
        #expect(await world.launch().mealIllustration(id) == Data("png bytes".utf8))
    }

    @Test func anIllustrationNotDrawnYetIsAskedForAgainLater() async throws {
        let world = World.signedIn()
        let id = CaptureFixture.dinnerID
        let route = "GET /v1/food/entries/\(id.uuidString.lowercased())/illustration"
        world.backend.on(route, StubBackend.Reply(status: 404, body: "{}"))
        let model = world.launch()

        #expect(await model.mealIllustration(id) == nil)
        #expect(world.illustrations.illustration(id) == nil)
        world.backend.on(route, .ok("png bytes"))
        #expect(await model.mealIllustration(id) == Data("png bytes".utf8))
        // Offline and never fetched: nothing, and the photo is shown.
        let other = UUID()
        world.backend.goDown()
        #expect(await model.mealIllustration(other) == nil)
    }

    @Test func signedOutNothingIsFetched() async throws {
        let world = World()
        let model = world.launch()
        #expect(await model.mealIllustration(CaptureFixture.dinnerID) == nil)
        #expect(world.backend.requests.isEmpty)
    }
}
