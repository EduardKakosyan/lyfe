import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import LyfeKit

/// Photo and barcode meals, in exactly the shape the backend sends them:
/// the usual breakfast, a photo lunch still being estimated, a photo
/// dinner estimated with oil asked about, and a protein bar by barcode.
enum CaptureFixture {
    static let lunchID = UUID(uuidString: "00000000-0000-4000-9000-000000000021")!
    static let dinnerID = UUID(uuidString: "00000000-0000-4000-9000-000000000022")!
    static let barID = UUID(uuidString: "00000000-0000-4000-9000-000000000031")!

    static let dinner = """
        {"id": "00000000-0000-4000-9000-000000000022", "slot": "dinner", "name": "stir fry, rice, some oil",
         "meal_id": null, "servings": 1.0, "kcal": 578, "protein_g": 33.0, "source": "photo", "figures": "known",
         "estimated": true, "kcal_low": 380, "kcal_high": 780,
         "photo": {"note": "stir fry, rice, some oil", "has_photo": true,
                   "items": [{"name": "Rice", "grams": 200.0, "grams_seen": 200.0, "kcal": 260, "protein_g": 5.4},
                             {"name": "Chicken", "grams": 120.0, "grams_seen": 120.0, "kcal": 198, "protein_g": 27.6}],
                   "oil_asked": true, "oil": null, "oil_counted": "some", "oil_kcal": 120, "typed": false, "problem": null}}
        """

    static func food(lunch: String = "estimating", products: String = bar) -> String {
        """
        {"day": "2026-11-17", "target": {"since": "2026-11-02", "kcal": 2500, "protein_g": 170},
         "kcal": 1330, "protein_g": 95.9, "kcal_measured": 752, "protein_measured_g": 62.9,
         "kcal_estimated": 578, "protein_estimated_g": 33.0, "kcal_low": 1132, "kcal_high": 1532,
         "unknown": \(lunch == "known" ? 0 : 1), "estimate_range_pct": 35, "kcal_left": 1170, "protein_left_g": 74.1,
         "open_slots": [],
         "entries": [
           {"id": "00000000-0000-4000-8000-000000000101", "slot": "breakfast", "name": "Usual breakfast",
            "meal_id": "00000000-0000-4000-9000-000000000001", "servings": 1.0, "kcal": 542, "protein_g": 43.1,
            "source": "saved", "figures": "known", "estimated": false},
           {"id": "00000000-0000-4000-9000-000000000021", "slot": "lunch", "name": "pho", "meal_id": null,
            "servings": 1.0, "kcal": 0, "protein_g": 0.0, "source": "photo", "figures": "\(lunch)", "estimated": true,
            "photo": {"note": "pho", "has_photo": false, "items": [], "oil_asked": false, "oil": null,
                      "oil_counted": "none", "oil_kcal": 0, "typed": false,
                      "problem": "The Spark is busy: 12 GB free, and the model needs 32. Trying again in a few minutes."}},
           \(dinner),
           {"id": "00000000-0000-4000-9000-000000000031", "slot": "snack", "name": "Protein bar", "meal_id": null,
            "servings": 1.0, "kcal": 210, "protein_g": 19.8, "source": "barcode", "figures": "known", "estimated": false,
            "barcode": {"code": "96385074", "grams": 60.0}}],
         "meals": [],
         "products": [\(products)],
         "streak": {"days": 1, "state": "kept", "previous_best": 0, "logged_today": true,
                    "last_days": [{"date": "2026-11-17", "state": "kept"}]}}
        """
    }

    static let bar = """
        {"code": "96385074", "name": "Protein bar", "kcal_per_100g": 350.0, "protein_per_100g": 33.0,
         "serving_g": 60.0, "origin": "database"}
        """

    static func day(lunch: String = "estimating") -> FoodDay {
        try! JSONDecoder.lyfe.decode(FoodDay.self, from: Data(food(lunch: lunch).utf8))
    }

    static func home(lunch: String = "estimating") -> StubBackend.Reply {
        .ok(Fixture.home(food: food(lunch: lunch)))
    }

    /// A camera-sized JPEG with a location written into it.
    static func cameraJPEG(width: Int = 4032, height: Int = 3024) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 18.4655, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 66.1057, kCGImagePropertyGPSLongitudeRef: "W",
        ]
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func properties(_ data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }
}

@Suite struct CaptureModelTests {
    @Test func photoAndBarcodeMealsFromTheBackendRead() throws {
        let food = CaptureFixture.day()
        #expect((food.kcalMeasured, food.kcalEstimated, food.kcalLow, food.kcalHigh) == (752, 578, 1132, 1532))
        #expect((food.proteinMeasuredG, food.proteinEstimatedG) == (62.9, 33.0))
        #expect((food.unknown, food.estimateRangePct) == (1, 35))
        let lunch = food.entries[1]
        #expect((lunch.from, lunch.figures, lunch.isKnown) == (.photo, .estimating, false))
        #expect(lunch.photo?.problem?.hasPrefix("The Spark is busy") == true)
        let dinner = food.entries[2]
        #expect((dinner.kcalLow, dinner.kcalHigh, dinner.estimated) == (380, 780, true))
        let photo = try #require(dinner.photo)
        #expect((photo.oilAsked, photo.oil, photo.oilCounted, photo.oilKcal) == (true, nil, .aBit, 120))
        #expect(photo.items[1] == .init(name: "Chicken", grams: 120, gramsSeen: 120, kcal: 198, proteinG: 27.6))
        let bar = food.entries[3]
        #expect((bar.from, bar.barcode) == (.barcode, .init(code: "96385074", grams: 60)))
        #expect(
            food.products == [
                Product(code: "96385074", name: "Protein bar", kcalPer100g: 350, proteinPer100g: 33, servingG: 60, origin: "database")
            ])
        // The cache writes and reads it back the same.
        #expect(try JSONDecoder.lyfe.decode(FoodDay.self, from: JSONEncoder.lyfe.encode(food)) == food)
    }

    @Test func aDayCachedBeforePhotoMealsStillReadsAsSavedMeals() {
        let old = Fixture.foodDay(logged: ["breakfast"])
        #expect(old.entries[0].source == nil)
        #expect(old.entries[0].from == .saved)
        #expect(old.entries[0].isKnown)
        #expect(old.kcalEstimated == nil)
        #expect(FoodText.split(old, kcal: true) == (542, 0))
    }

    @Test func aProductsGramsComeToTheLabelsFigures() {
        let bar = CaptureFixture.day().products![0]
        #expect(bar.amount(grams: 60) == (210, 19.8))
        #expect(bar.amount(grams: 30) == (105, 9.9))
    }
}

@Suite struct CaptureStoreTests {
    @Test func aMealAndItsPhotoAreKeptUntilSentAndThePhotoAWhileAfter() {
        let store = CaptureStore(directory: Fixture.temporaryDirectory())
        let photo = FoodCapture(eatenAt: Date(timeIntervalSince1970: 1_795_000_000), slot: .dinner, kind: .photo(note: "pho", hasPhoto: true))
        let bar = FoodCapture(
            eatenAt: Date(timeIntervalSince1970: 1_795_000_100), slot: .snack,
            kind: .barcode(code: "96385074", grams: 60, product: nil))
        store.enqueue(photo, jpeg: Data([0xFF, 0xD8, 0xFF]))
        store.enqueue(bar)
        store.enqueue(photo, jpeg: Data([0x00]))
        #expect(store.outbox() == [photo, bar])
        #expect(store.photo(photo.id) == Data([0xFF, 0xD8, 0xFF]))

        store.remove(photo.id)
        #expect(store.outbox() == [bar])
        // Kept for showing the estimate.
        #expect(store.photo(photo.id) != nil)
        store.prunePhotos(olderThan: 3 * 86_400, now: Date().addingTimeInterval(4 * 86_400))
        #expect(store.photo(photo.id) == nil)

        // A meal taken back before it was sent leaves nothing behind.
        let other = FoodCapture(eatenAt: Date(), slot: .lunch, kind: .photo(note: "", hasPhoto: true))
        store.enqueue(other, jpeg: Data([0xFF, 0xD8, 0xFF]))
        store.remove(other.id, forget: true)
        #expect(store.photo(other.id) == nil)
        store.remove(bar.id)
        #expect(store.outbox().isEmpty)
    }

    @Test func aPhotoWaitingToBeSentIsNeverPruned() {
        let store = CaptureStore(directory: Fixture.temporaryDirectory())
        let photo = FoodCapture(eatenAt: Date(), slot: .dinner, kind: .photo(note: "pho", hasPhoto: true))
        store.enqueue(photo, jpeg: Data([0xFF, 0xD8, 0xFF]))
        store.prunePhotos(olderThan: 0, now: Date().addingTimeInterval(30 * 86_400))
        #expect(store.photo(photo.id) != nil)
    }

    @Test func aCaptureIsNamedByWhatIsKnownOfIt() {
        let at = Date()
        #expect(FoodCapture(eatenAt: at, slot: .dinner, kind: .photo(note: " pho ", hasPhoto: true)).name == "pho")
        #expect(FoodCapture(eatenAt: at, slot: .dinner, kind: .photo(note: "", hasPhoto: true)).name == "Photo meal")
        let bar = CaptureFixture.day().products![0]
        #expect(FoodCapture(eatenAt: at, slot: .snack, kind: .barcode(code: "96385074", grams: 60, product: bar)).name == "Protein bar")
        #expect(FoodCapture(eatenAt: at, slot: .snack, kind: .barcode(code: "96385074", grams: 60, product: nil)).name == "Barcode 96385074")
    }
}

@Suite struct MealPhotoTests {
    @Test func aCameraPictureIsShrunkAndLosesItsLocation() throws {
        let original = CaptureFixture.cameraJPEG()
        #expect(CaptureFixture.properties(original)[kCGImagePropertyGPSDictionary] != nil)

        let sent = try #require(MealPhoto.prepare(original))
        let properties = CaptureFixture.properties(sent)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1280)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 960)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(sent.starts(with: [0xFF, 0xD8, 0xFF]))
        #expect(sent.count < 400_000)
    }

    @Test func somethingThatIsNotAPictureIsNotSent() {
        #expect(MealPhoto.prepare(Data("not a picture".utf8)) == nil)
    }
}

@Suite struct CaptureTypingTests {
    @Test func theLikelyPartOfTheDayFollowsTheClock() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Puerto_Rico")!
        func at(_ hour: Int, _ minute: Int = 0) -> MealSlot {
            .likely(at: calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: hour, minute: minute))!, calendar: calendar)
        }
        #expect(at(7) == .breakfast)
        #expect(at(10, 29) == .breakfast)
        #expect(at(10, 30) == .lunch)
        #expect(at(13) == .lunch)
        #expect(at(15) == .snack)
        #expect(at(19) == .dinner)
        #expect(at(23) == .snack)
        #expect(at(2) == .snack)
    }

    @Test func aBarcodeTypedByHandIsItsDigits() {
        #expect(FoodTyping.barcode("0 64200 11589 6") == "064200115896")
        #expect(FoodTyping.barcode("9638-5074") == "96385074")
        #expect(FoodTyping.barcode("1234567") == nil)
        #expect(FoodTyping.barcode("12345678x") == nil)
        #expect(FoodTyping.barcode("１２３４５６７８") == nil)
    }

    @Test func gramsAndLabelsAndFiguresAreReadOrSaidToBeWrong() throws {
        #expect(try FoodTyping.grams("45").get() == 45)
        #expect(try FoodTyping.grams("22,5").get() == 22.5)
        #expect((try? FoodTyping.grams("0").get()) == nil)
        #expect((try? FoodTyping.grams("3001").get()) == nil)

        let label = try FoodTyping.label(code: "96385074", name: " Skyr cup ", kcal: "63", protein: "11", serving: "175").get()
        #expect(label == Product(code: "96385074", name: "Skyr cup", kcalPer100g: 63, proteinPer100g: 11, servingG: 175, origin: "label"))
        #expect(try FoodTyping.label(code: "96385074", name: "Skyr", kcal: "63", protein: "11", serving: " ").get().servingG == nil)
        #expect((try? FoodTyping.label(code: "1", name: "", kcal: "63", protein: "11", serving: "").get()) == nil)
        #expect((try? FoodTyping.label(code: "1", name: "Skyr", kcal: "630x", protein: "11", serving: "").get()) == nil)
        #expect((try? FoodTyping.label(code: "1", name: "Skyr", kcal: "63", protein: "110", serving: "").get()) == nil)

        let typed = try FoodTyping.mealFigures(kcal: "650", protein: "41,5").get()
        #expect((typed.kcal, typed.proteinG) == (650, 41.5))
        #expect((try? FoodTyping.mealFigures(kcal: "650.5", protein: "40").get()) == nil)
        #expect((try? FoodTyping.mealFigures(kcal: "6500", protein: "40").get()) == nil)
    }
}

@MainActor
@Suite struct CaptureLoggingTests {
    func sent(_ world: World, _ route: String) -> [[String: Any]] {
        world.backend.bodies(route).compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    @Test func aPhotoMealIsSentWithItsPhotoAndItsEstimateOpens() async throws {
        let world = World.signedIn()
        world.backend.on("POST /v1/food/photo-entries", CaptureFixture.home())
        let model = world.launch()

        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        #expect(await model.logPhotoMeal(note: " pho ", photo: jpeg, slot: .lunch) == .sent)

        let body = try #require(sent(world, "POST /v1/food/photo-entries").first)
        #expect(Set(body.keys) == ["id", "eaten_at", "slot", "note", "photo_jpeg"])
        #expect(body["slot"] as? String == "lunch")
        #expect(body["note"] as? String == "pho")
        #expect(body["photo_jpeg"] as? String == jpeg.base64EncodedString())
        #expect(body["eaten_at"] as? String == "2026-11-18T11:06:40Z")
        let id = try #require(UUID(uuidString: body["id"] as? String ?? ""))
        #expect(model.foodFlow == .estimate(id))
        #expect(model.unsentCaptures.isEmpty)
        #expect(model.home?.food?.unknown == 1)
        // The photo stays on the phone to show with the estimate.
        #expect(await model.mealPhoto(id) == jpeg)
    }

    @Test func aMealDescribedWithoutAPhotoSendsNone() async throws {
        let world = World.signedIn()
        world.backend.on("POST /v1/food/photo-entries", CaptureFixture.home())
        let model = world.launch()
        await model.logPhotoMeal(note: "pho", photo: nil, slot: .lunch)
        let body = try #require(sent(world, "POST /v1/food/photo-entries").first)
        #expect(body["photo_jpeg"] == nil)
    }

    @Test func aPhotoMealLoggedOfflineIsKeptAndSentOnTheNextRefresh() async throws {
        let world = World.signedIn()
        world.backend.goDown()
        let model = world.launch()

        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        #expect(await model.logPhotoMeal(note: "pho", photo: jpeg, slot: .lunch) == .saved)
        // Back to Food, where it shows as waiting.
        #expect(model.foodFlow == nil)
        let kept = try #require(model.unsentCaptures.first)
        #expect(world.captures.outbox() == [kept])
        #expect(world.captures.photo(kept.id) == jpeg)
        #expect(FoodText.captureRow(kept).label == "ON THIS PHONE · ESTIMATED ONCE SENT")

        world.time.advance(3600)
        let relaunched = world.launch()
        #expect(relaunched.unsentCaptures == [kept])
        world.backend.goDown(false)
        world.backend.on("POST /v1/food/photo-entries", CaptureFixture.home())
        world.backend.on("GET /v1/home", CaptureFixture.home())
        world.backend.on("POST /v1/sync", .ok(Fixture.sources()))
        await relaunched.refresh()

        let body = try #require(sent(world, "POST /v1/food/photo-entries").last)
        #expect(body["id"] as? String == kept.id.uuidString)
        // When it was eaten, not when it was sent.
        #expect(body["eaten_at"] as? String == "2026-11-18T11:06:40Z")
        #expect(body["photo_jpeg"] as? String == jpeg.base64EncodedString())
        #expect(relaunched.unsentCaptures.isEmpty)
        #expect(world.captures.outbox().isEmpty)
    }

    @Test func aMealTheServerRefusesIsDroppedAndSaid() async throws {
        let world = World.signedIn()
        world.backend.on("POST /v1/food/photo-entries", .init(status: 400, body: #"{"error": "bad_request"}"#))
        let model = world.launch()
        #expect(await model.logPhotoMeal(note: "pho", photo: nil, slot: .lunch) == .refused)
        #expect(model.unsentCaptures.isEmpty)
        #expect(model.foodProblem == "The server would not log pho (400).")
    }

    @Test func aMealStillOnThePhoneIsTakenBackWithoutTheServer() async {
        let world = World.signedIn()
        world.backend.goDown()
        let model = world.launch()
        await model.logPhotoMeal(note: "pho", photo: Data([0xFF, 0xD8, 0xFF]), slot: .lunch)
        let id = model.unsentCaptures[0].id
        #expect(await model.takeBackMeal(id) == nil)
        #expect(model.unsentCaptures.isEmpty)
        #expect(world.captures.photo(id) == nil)
    }

    @Test func aBarcodeIsLookedUpOnThePhoneFirstThenTheServer() async {
        let world = World.signedIn()
        world.backend.on("GET /v1/home", CaptureFixture.home())
        world.backend.on("POST /v1/sync", .ok(Fixture.sources()))
        world.backend.on("GET /v1/food/products/5449000000996", .ok(
            #"{"code": "5449000000996", "name": "Cola", "kcal_per_100g": 43.0, "protein_per_100g": 0.0, "serving_g": null, "origin": "database"}"#))
        let model = world.launch()
        await model.refresh()

        let bar = CaptureFixture.day().products![0]
        // Logged lately, so known here; the server is not asked.
        #expect(await model.lookUp(code: "96385074") == .found(bar))
        #expect(!world.backend.requests.contains("GET /v1/food/products/96385074"))
        guard case .found(let cola) = await model.lookUp(code: "5449000000996") else {
            Issue.record("not found")
            return
        }
        #expect(cola.name == "Cola")
        // The stand-in answers 404 for anything else.
        #expect(await model.lookUp(code: "0628915423456") == .notFound)
        world.backend.goDown()
        #expect(await model.lookUp(code: "0628915423456") == .offline)
        // Known here even with no connection.
        #expect(await model.lookUp(code: "96385074") == .found(bar))
    }

    @Test func aUPCAndItsEANAreOneCode() {
        #expect(AppModel.sameCode("064200115896", "0064200115896"))
        #expect(AppModel.sameCode("96385074", "96385074"))
        #expect(!AppModel.sameCode("96385074", "96385075"))
    }

    @Test func aScannedBarcodeIsSentWithTheGramsEaten() async throws {
        let world = World.signedIn()
        world.backend.on("POST /v1/food/barcode-entries", CaptureFixture.home())
        let model = world.launch()
        let bar = CaptureFixture.day().products![0]
        #expect(await model.logBarcode(code: "96385074", grams: 60, slot: .snack, product: bar) == .sent)
        let body = try #require(sent(world, "POST /v1/food/barcode-entries").first)
        #expect(Set(body.keys) == ["id", "eaten_at", "slot", "code", "grams"])
        #expect((body["code"] as? String, body["grams"] as? Double, body["slot"] as? String) == ("96385074", 60, "snack"))
        // Back to Food.
        #expect(model.foodFlow == nil)
    }

    @Test func aBarcodeScannedOfflineWaitsWithWhatThePhoneKnew() async throws {
        let world = World.signedIn()
        world.backend.goDown()
        let model = world.launch()
        let bar = CaptureFixture.day().products![0]
        #expect(await model.logBarcode(code: "96385074", grams: 30, slot: .snack, product: bar) == .saved)
        let kept = try #require(model.unsentCaptures.first)
        #expect(FoodText.captureRow(kept).value == "105")
        await model.logBarcode(code: "0628915423456", grams: 45, slot: .snack, product: nil)
        #expect(FoodText.captureRow(model.unsentCaptures[1]).label == "ON THIS PHONE · 45 G · LOOKED UP ONCE SENT")
    }

    @Test func anEstimateIsCorrectedByPortionsOilOrTypedFigures() async throws {
        let world = World.signedIn()
        let route = "PUT /v1/food/entries/\(CaptureFixture.dinnerID.uuidString.lowercased())/estimate"
        world.backend.on(route, CaptureFixture.home())
        let model = world.launch()

        #expect(await model.correctEstimate(CaptureFixture.dinnerID, .portions(grams: [300, 120], oil: nil)) == nil)
        #expect(await model.correctEstimate(CaptureFixture.dinnerID, .portions(grams: nil, oil: .aLot)) == nil)
        #expect(await model.correctEstimate(CaptureFixture.dinnerID, .typed(kcal: 650, proteinG: 41.5)) == nil)
        let bodies = sent(world, route)
        #expect(bodies[0]["grams"] as? [Double] == [300, 120])
        #expect(bodies[0]["oil"] == nil)
        #expect(Set(bodies[1].keys) == ["oil"])
        #expect(bodies[1]["oil"] as? String == "a_lot")
        #expect(bodies[2]["kcal"] as? Int == 650)
        #expect(bodies[2]["protein_g"] as? Double == 41.5)
        #expect(Set(bodies[2].keys) == ["kcal", "protein_g"])
    }

    @Test func aTypedLabelIsSentForItsCode() async throws {
        let world = World.signedIn()
        world.backend.on("PUT /v1/food/products/0628915423456", CaptureFixture.home())
        let model = world.launch()
        model.openLabel(code: "0628915423456")
        let label = Product(code: "0628915423456", name: "Skyr cup", kcalPer100g: 63, proteinPer100g: 11, servingG: nil, origin: "label")
        #expect(await model.setLabel(label) == nil)
        let body = try #require(sent(world, "PUT /v1/food/products/0628915423456").first)
        #expect(Set(body.keys) == ["name", "kcal_per_100g", "protein_per_100g"])
        #expect(body["kcal_per_100g"] as? Double == 63)
    }

    @Test func anEstimateBeingMadeIsFollowedWithoutAskingGarmin() async {
        let world = World.signedIn()
        world.backend.on("GET /v1/home", CaptureFixture.home(lunch: "estimating"), CaptureFixture.home(lunch: "known"))
        let model = world.launch()
        await model.reloadHome()
        #expect(model.home?.food?.unknown == 1)
        await model.reloadHome()
        #expect(model.home?.food?.unknown == 0)
        #expect(!world.backend.requests.contains("POST /v1/sync"))
    }
}

@Suite struct CaptureTextTests {
    let food = CaptureFixture.day()

    @Test func eachKindOfMealHasItsRow() {
        let rows = FoodText.rows(food, unsent: [])
        #expect(rows.map(\.mark) == [.solid, .striped, .striped, .solid])
        #expect(rows[1].label == "PHOTO · WAITING FOR THE SPARK")
        #expect(rows[1].value == "…")
        #expect(rows[1].tap == .estimate(CaptureFixture.lunchID))
        #expect(rows[2].label == "PHOTO · 380–780 · 33 G")
        #expect(rows[2].value == "578")
        #expect(rows[2].tap == .estimate(CaptureFixture.dinnerID))
        #expect(rows[3].label == "LABEL · 60 G · 20 G PROTEIN")
        #expect(rows[3].tap == .takeBack)
        #expect(rows[0].tap == .takeBack)
        #expect(rows[1].spoken == "pho, PHOTO · WAITING FOR THE SPARK, being estimated")
    }

    @Test func aMealWithoutFiguresIsAQuestionMarkToTap() throws {
        var failed = food.entries[1]
        failed.figures = .failed
        #expect(FoodText.entryRow(failed).label == "PHOTO · NO ESTIMATE · TAP TO TYPE IT")
        #expect(FoodText.entryRow(failed).value == "?")
        var unknown = food.entries[3]
        unknown.figures = .needsLabel
        #expect(FoodText.entryRow(unknown).tap == .label("96385074"))
        #expect(FoodText.entryRow(unknown).mark == .outline)
        var typed = food.entries[2]
        typed.photo?.typed = true
        #expect(FoodText.entryRow(typed).label == "PHOTO · TYPED · 33 G PROTEIN")
    }

    @Test func theHeaderSaysWhatIsEstimatedAndWhatIsNotInTheTotal() {
        #expect(FoodText.estimateLine(food) == "578 ESTIMATED · DAY 1,132–1,532")
        #expect(FoodText.split(food, kcal: true) == (752, 578))
        #expect(FoodText.split(food, kcal: false) == (62.9, 33.0))
        #expect(FoodText.unknownNotice(food) == "1 photo is being estimated. Not in the total until then.")
        #expect(FoodText.unknownNotice(CaptureFixture.day(lunch: "known")) == nil)
        #expect(FoodText.estimateLine(Fixture.foodDay(logged: ["breakfast"])) == nil)
    }

    @Test func aMealOnThePhoneFillsItsSlotForTheBar() {
        let morning = Fixture.foodDay()
        let photo = FoodCapture(eatenAt: Date(), slot: .breakfast, kind: .photo(note: "eggs", hasPhoto: true))
        #expect(FoodText.bar(morning, unsent: []).big == "USUAL BREAKFAST")
        #expect(FoodText.bar(morning, unsent: [], captures: [photo]).big == "BATCH LUNCH")
        let rows = FoodText.rows(morning, unsent: [], captures: [photo])
        #expect(rows[0].title == "eggs")
        #expect(rows[0].dim)
    }

    @Test func theEstimateScreenSaysWhereTheEstimateStands() {
        let dinner = CaptureText.estimate(food.entries[2])
        #expect(dinner == .init(
            label: "Estimate · kcal", giant: "578", rangeLabel: "Range", range: "380–780", protein: "33 G",
            words: "Includes 120 kcal of oil or sauce"))
        let lunch = CaptureText.estimate(food.entries[1])
        #expect(lunch.giant == "…")
        #expect(lunch.words?.hasPrefix("The Spark is busy") == true)
        var failed = food.entries[1]
        failed.figures = .failed
        failed.photo?.problem = nil
        #expect(CaptureText.estimate(failed).words == "Type what it came to below.")
        #expect(CaptureText.estimate(failed).giant == "?")
    }

    @Test func eachItemSaysWhetherItWasCorrected() {
        let rice = FoodDay.EstimateItem(name: "Rice", grams: 200, gramsSeen: 200, kcal: 260, proteinG: 5.4)
        #expect(CaptureText.itemRow(0, rice).label == "260 KCAL · 5 G PROTEIN · TAP TO CHANGE")
        #expect(CaptureText.itemRow(0, rice).value == "200 G")
        #expect(CaptureText.itemRow(0, rice).mark == .striped)
        let more = FoodDay.EstimateItem(name: "Rice", grams: 300, gramsSeen: 200, kcal: 390, proteinG: 8.1)
        #expect(CaptureText.itemRow(0, more).label == "390 KCAL · YOU SAID · MODEL 200 G")
        let gone = FoodDay.EstimateItem(name: "Rice", grams: 0, gramsSeen: 200, kcal: 0, proteinG: 0)
        #expect(CaptureText.itemRow(0, gone).dim)
    }

    @Test func theScanScreenSaysWhatTheGramsComeTo() {
        let bar = food.products![0]
        #expect(CaptureText.scanBar(lookup: .found(bar), grams: 60, busy: false) == ("MEASURED · 210 KCAL · 20 G PROTEIN", "LOG IT"))
        #expect(CaptureText.scanBar(lookup: .found(bar), grams: nil, busy: false).small == "TYPE THE GRAMS EATEN")
        #expect(CaptureText.scanBar(lookup: .offline, grams: 45, busy: true) == ("45 G · COUNTED ONCE SENT", "LOGGING"))
        #expect(CaptureText.scanBar(lookup: .notFound, grams: 45, busy: false).small == "SAVES THE LABEL, THEN LOGS 45 G")
        #expect(CaptureText.servings(1, of: 60) == "1 SERVING · 60 G")
        #expect(CaptureText.servings(0.5, of: 60) == "½ SERVING · 30 G")
        #expect(CaptureText.product(.found(bar)).detail == "FOOD DATABASE · 350 KCAL · 33 G PROTEIN PER 100 G")
    }
}

/// Runs the app's own client against a backend started for the purpose,
/// for photo and barcode meals: what is sent, and that the answers read.
/// The backend's LYFE_OLLAMA_URL should point at a stand-in that answers
/// every chat with rice and chicken (see the README). It logs meals and
/// stores labels, so point it at a scratch database:
/// `LYFE_LOCAL_SERVER=http://127.0.0.1:8799 LYFE_LOCAL_PASSWORD=... swift test`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LYFE_LOCAL_SERVER"] != nil))
struct CapturesAgainstARealBackendTests {
    @Test func aPhotoMealIsEstimatedAndCorrectedAndABarcodeIsLogged() async throws {
        let environment = ProcessInfo.processInfo.environment
        let world = World(address: environment["LYFE_LOCAL_SERVER"])
        let model = world.launch(transport: URLSessionTransport())
        world.time.now = Date()
        await model.signIn(password: environment["LYFE_LOCAL_PASSWORD"] ?? "")
        #expect(model.phase == .signedIn, "\(model.signInProblem ?? "")")

        // A real picture, shrunk the way the camera's is.
        let jpeg = try #require(MealPhoto.prepare(CaptureFixture.cameraJPEG()))
        #expect(await model.logPhotoMeal(note: "client check stir fry", photo: jpeg, slot: .dinner) == .sent)
        guard case .estimate(let id) = model.foodFlow else {
            Issue.record("the estimate did not open: \(model.foodProblem ?? model.offlineReason ?? "")")
            return
        }
        var entry = try #require(model.home?.food?.entries.first { $0.id == id })
        #expect((entry.from, entry.estimated, entry.photo?.hasPhoto) == (.photo, true, true))

        // Followed until the model has answered.
        for _ in 0..<40 where entry.figures == .estimating {
            try await Task.sleep(for: .milliseconds(250))
            await model.reloadHome()
            entry = try #require(model.home?.food?.entries.first { $0.id == id })
        }
        #expect(entry.figures == .known, "\(entry.photo?.problem ?? "")")
        let items = try #require(entry.photo?.items)
        #expect(items.map(\.name) == ["Rice", "Chicken"])
        #expect(entry.kcal == 578)
        #expect((entry.kcalLow, entry.kcalHigh) == (380, 780))
        // The photo comes back from the server as sent.
        let world2 = World(address: environment["LYFE_LOCAL_SERVER"])
        let other = world2.launch(transport: URLSessionTransport())
        await other.signIn(password: environment["LYFE_LOCAL_PASSWORD"] ?? "")
        #expect(await other.mealPhoto(id) == jpeg)

        #expect(await model.correctEstimate(id, .portions(grams: [300, 120], oil: .nothing)) == nil)
        entry = try #require(model.home?.food?.entries.first { $0.id == id })
        #expect((entry.kcal, entry.photo?.oil) == (588, Oil.nothing))
        #expect(await model.correctEstimate(id, .typed(kcal: 650, proteinG: 41.5)) == nil)
        entry = try #require(model.home?.food?.entries.first { $0.id == id })
        #expect((entry.kcal, entry.proteinG, entry.photo?.typed, entry.kcalLow) == (650, 41.5, true, nil))

        // A code nobody knows: logged, then its label typed.
        let code = String(format: "0628%09d", Int.random(in: 0..<1_000_000_000))
        #expect(await model.lookUp(code: code) == .notFound)
        #expect(await model.logBarcode(code: code, grams: 175, slot: .snack, product: nil) == .sent)
        var cup = try #require(model.home?.food?.entries.first { $0.barcode?.code == code })
        #expect((cup.figures, cup.kcal) == (.needsLabel, 0))
        let label = try FoodTyping.label(code: code, name: "Client check skyr", kcal: "63", protein: "11", serving: "175").get()
        #expect(await model.setLabel(label) == nil)
        cup = try #require(model.home?.food?.entries.first { $0.barcode?.code == code })
        #expect((cup.figures, cup.name, cup.kcal, cup.proteinG) == (.known, "Client check skyr", 110, 19.3))
        guard case .found(let found) = await model.lookUp(code: code) else {
            Issue.record("the label was not found")
            return
        }
        #expect((found.origin, found.servingG) == ("label", 175))
        #expect(model.home?.food?.products?.contains { $0.code == code } == true)

        // Taken back again, so the check can be run twice.
        #expect(await model.takeBackMeal(id) == nil)
        #expect(await model.takeBackMeal(cup.id) == nil)
    }
}
