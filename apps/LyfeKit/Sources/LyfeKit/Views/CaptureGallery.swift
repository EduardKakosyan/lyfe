#if DEBUG
    import CoreGraphics
    import Foundation
    import ImageIO
    import SwiftUI
    import UniformTypeIdentifiers

    /// A made-up plate, for a development build to log as a photo meal.
    public enum DebugSample {
        public static func plate() -> Data? { CaptureGallery.plate() }
    }

    /// The builder, photo and barcode screens with made-up meals: a debug
    /// build shows one when launched with LYFE_DEBUG_FOOD set to `mixed`
    /// (the day with a saved, photo, barcode and built meal), `builder`
    /// (a meal being built from four parts), `building` (one with a photo
    /// still being estimated), `logged` (a built meal after logging),
    /// `photo`, `estimate`, `estimating`, `failed`, `scan`, `product`,
    /// `notfound` or `label`.
    struct CaptureGallery: View {
        var screen: String

        static let screens: Set<String> = [
            "mixed", "builder", "building", "logged", "photo", "estimate", "estimating", "failed", "scan", "product",
            "notfound", "label",
        ]

        static let bar = Product(
            code: "96385074", name: "Protein bar", kcalPer100g: 350, proteinPer100g: 33, servingG: 60, origin: "database")

        var body: some View {
            Group {
                switch screen {
                case "builder":
                    Builder(draft: Self.draft(), estimates: [Self.eggsID: Self.eggs(figures: .known)])
                case "building":
                    Builder(draft: Self.draft(), estimates: [Self.eggsID: Self.eggs(figures: .estimating)])
                case "logged":
                    LoggedMealView(meal: Self.builtBreakfast(), onTakeBack: { _ in nil }, onClose: {})
                case "photo":
                    PhotoMealView(
                        start: .dinner, photo: Self.plate(), note: "stir fry, rice, some oil", opensCamera: false,
                        onLog: { _, _, _ in }, onClose: {})
                case "estimate":
                    estimate(Self.dinner())
                case "estimating":
                    estimate(Self.lunch(figures: .estimating))
                case "failed":
                    estimate(Self.lunch(figures: .failed))
                case "scan":
                    ScanView(lookUp: { _ in .notFound }, onSetLabel: { _ in nil }, onLog: { _, _, _, _ in }, onClose: {})
                case "product":
                    ScanView(
                        start: .snack, code: Self.bar.code, lookup: .found(Self.bar), lookUp: { _ in .found(Self.bar) },
                        onSetLabel: { _ in nil }, onLog: { _, _, _, _ in }, onClose: {})
                case "notfound":
                    ScanView(
                        start: .snack, code: "0628915423456", lookup: .notFound, lookUp: { _ in .notFound },
                        onSetLabel: { _ in nil }, onLog: { _, _, _, _ in }, onClose: {})
                case "label":
                    LabelView(code: "0628915423456", onSave: { _ in nil }, onClose: {})
                default:
                    FoodScreen(
                        food: Self.day(),
                        captures: [
                            FoodCapture(
                                eatenAt: Date(), slot: .snack,
                                kind: .barcode(code: "0628915423456", grams: 175, product: nil))
                        ], building: .init(parts: 2, kcal: 313), onBack: {}, onLog: { _, _ in },
                        onTakeBack: { _ in nil }, onEditMeal: { _ in }, onTargets: {})
                }
            }
            .preferredColorScheme(.light)
        }

        /// The builder holding a draft that its buttons really change.
        private struct Builder: View {
            @State var draft: MealDraft
            var estimates: [UUID: FoodDay.Entry]

            var body: some View {
                MealBuilderView(
                    draft: draft, estimates: estimates, onChange: { $0(&draft) }, onSave: { nil }, onClose: {})
            }
        }

        static let eggsID = UUID(uuidString: "00000000-0000-4000-9000-000000000034")!

        /// A breakfast being built: yogurt and granola scanned, a banana
        /// typed, and eggs on toast from a photo.
        static func draft() -> MealDraft {
            var draft = MealDraft(slot: .breakfast, purpose: .log)
            draft.parts = [
                MealPart(.food(Ingredient(name: "Greek yogurt", grams: 175, kcalPer100g: 63, proteinPer100g: 11, code: "064200115896"))),
                MealPart(.food(Ingredient(name: "Granola", grams: 45, kcalPer100g: 451, proteinPer100g: 10.5, code: "0055577105019"))),
                MealPart(.food(Ingredient(name: "Banana", grams: 120, kcalPer100g: 89, proteinPer100g: 1.1))),
                MealPart(id: eggsID, .photo(note: "eggs on toast", hasPhoto: true)),
            ]
            return draft
        }

        /// The photo of eggs on toast, as the backend has it.
        static func eggs(figures: FoodDay.Figures) -> FoodDay.Entry {
            let known = figures == .known
            return FoodDay.Entry(
                id: eggsID, slot: .breakfast, name: "eggs on toast", mealId: nil, servings: 1, kcal: known ? 312 : 0,
                proteinG: known ? 23 : 0, source: .photo, figures: figures, estimated: true, kcalLow: known ? 200 : nil,
                kcalHigh: known ? 420 : nil,
                photo: .init(
                    note: "eggs on toast", hasPhoto: true,
                    items: known
                        ? [
                            .init(name: "Fried eggs", grams: 100, gramsSeen: 100, kcal: 155, proteinG: 13),
                            .init(name: "Toast", grams: 60, gramsSeen: 60, kcal: 157, proteinG: 10),
                        ] : [], oilAsked: false, oil: nil, oilCounted: .nothing, oilKcal: 0, typed: false, problem: nil),
                kcalEstimated: known ? 312 : nil)
        }

        /// The same breakfast once logged, as the backend sends it.
        static func builtBreakfast() -> FoodDay.Entry {
            func part(_ n: Int, _ name: String, _ source: FoodDay.FoodSource, _ kcal: Int, _ protein: Double, grams: Double, per100: (Double, Double), code: String? = nil) -> FoodDay.Entry {
                FoodDay.Entry(
                    id: UUID(uuidString: "00000000-0000-4000-9000-00000000003\(n)")!, slot: .breakfast, name: name,
                    mealId: nil, servings: 1, kcal: kcal, proteinG: protein, source: source, figures: .known,
                    estimated: false, barcode: code.map { .init(code: $0, grams: grams) },
                    weighed: .init(grams: grams, kcalPer100g: per100.0, proteinPer100g: per100.1))
            }
            return FoodDay.Entry(
                id: UUID(uuidString: "00000000-0000-4000-9000-000000000030")!, slot: .breakfast, name: "Breakfast",
                mealId: nil, servings: 1, kcal: 732, proteinG: 48.3, source: .built, figures: .known, estimated: true,
                kcalLow: 620, kcalHigh: 840, kcalEstimated: 312,
                parts: [
                    part(1, "Greek yogurt", .barcode, 110, 19.3, grams: 175, per100: (63, 11), code: "064200115896"),
                    part(2, "Granola", .barcode, 203, 4.7, grams: 45, per100: (451, 10.5), code: "0055577105019"),
                    part(3, "Banana", .typed, 107, 1.3, grams: 120, per100: (89, 1.1)),
                    eggs(figures: .known),
                ])
        }

        private func estimate(_ entry: FoodDay.Entry) -> some View {
            EstimateView(
                entry: entry, loadPhoto: { Self.plate() }, onCorrect: { _ in nil }, onReload: {}, onTakeBack: { nil },
                onClose: {})
        }

        static func dinner() -> FoodDay.Entry {
            FoodDay.Entry(
                id: UUID(uuidString: "00000000-0000-4000-9000-000000000022")!, slot: .dinner,
                name: "stir fry, rice, some oil", mealId: nil, servings: 1, kcal: 578, proteinG: 33, source: .photo,
                figures: .known, estimated: true, kcalLow: 380, kcalHigh: 780,
                photo: .init(
                    note: "stir fry, rice, some oil", hasPhoto: true,
                    items: [
                        .init(name: "Rice", grams: 200, gramsSeen: 200, kcal: 260, proteinG: 5.4),
                        .init(name: "Chicken", grams: 120, gramsSeen: 120, kcal: 198, proteinG: 27.6),
                    ], oilAsked: true, oil: nil, oilCounted: .aBit, oilKcal: 120, typed: false, problem: nil))
        }

        static func lunch(figures: FoodDay.Figures) -> FoodDay.Entry {
            FoodDay.Entry(
                id: UUID(uuidString: "00000000-0000-4000-9000-000000000021")!, slot: .lunch, name: "pho, extra brisket",
                mealId: nil, servings: 1, kcal: 0, proteinG: 0, source: .photo, figures: figures, estimated: true,
                photo: .init(
                    note: "pho, extra brisket", hasPhoto: true, items: [], oilAsked: false, oil: nil,
                    oilCounted: .nothing, oilKcal: 0, typed: false,
                    problem: figures == .failed
                        ? "The model's answer could not be used: the answer was not the JSON asked for." : nil))
        }

        static func day() -> FoodDay {
            let entries = [
                builtBreakfast(),
                lunch(figures: .estimating),
                dinner(),
                FoodDay.Entry(
                    id: UUID(), slot: .snack, name: "Protein bar", mealId: nil, servings: 1, kcal: 210, proteinG: 19.8,
                    source: .barcode, figures: .known, estimated: false, barcode: .init(code: "96385074", grams: 60)),
            ]
            return FoodDay(
                day: FoodGallery.today, target: FoodGallery.target, kcal: 1520, proteinG: 101.1, kcalLeft: 980,
                proteinLeftG: 68.9, openSlots: [], entries: entries,
                meals: [FoodGallery.breakfast, FoodGallery.lunch, FoodGallery.dinner],
                streak: .init(
                    days: 13, state: .kept, previousBest: 9, loggedToday: true,
                    lastDays: (11...17).map { .init(date: CalendarDay(year: 2026, month: 11, day: $0), state: .kept) }),
                kcalMeasured: 630, proteinMeasuredG: 45.1, kcalEstimated: 890, proteinEstimatedG: 56, kcalLow: 1210,
                kcalHigh: 1830, unknown: 1, estimateRangePct: 35, products: [bar])
        }

        /// A made-up plate seen from above, as the drawn screen has it.
        nonisolated static func plate() -> Data? {
            let (width, height) = (900, 600)
            guard
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            func fill(_ r: Int, _ g: Int, _ b: Int, _ rect: CGRect) {
                context.setFillColor(CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
                context.fillEllipse(in: rect)
            }
            context.setFillColor(CGColor(red: 0x26 / 255, green: 0x22 / 255, blue: 0x1c / 255, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            fill(0xd6, 0xd0, 0xc2, CGRect(x: 225, y: 75, width: 450, height: 450))
            fill(0xe9, 0xe4, 0xd8, CGRect(x: 260, y: 110, width: 380, height: 380))
            fill(0xf6, 0xf1, 0xe2, CGRect(x: 300, y: 270, width: 180, height: 165))
            fill(0xb5, 0x64, 0x2a, CGRect(x: 420, y: 200, width: 200, height: 170))
            fill(0x4f, 0x7d, 0x3a, CGRect(x: 340, y: 160, width: 130, height: 100))
            guard let image = context.makeImage() else { return nil }
            let data = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            return data as Data
        }
    }
#endif
