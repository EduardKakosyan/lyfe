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

    /// The photo and barcode screens with made-up meals: a debug build shows
    /// one when launched with LYFE_DEBUG_FOOD set to `mixed` (the day with a
    /// saved, photo and barcode meal), `photo`, `estimate`, `estimating`,
    /// `failed`, `scan`, `product`, `notfound` or `label`.
    struct CaptureGallery: View {
        var screen: String

        static let screens: Set<String> = [
            "mixed", "photo", "estimate", "estimating", "failed", "scan", "product", "notfound", "label",
        ]

        static let bar = Product(
            code: "96385074", name: "Protein bar", kcalPer100g: 350, proteinPer100g: 33, servingG: 60, origin: "database")

        var body: some View {
            Group {
                switch screen {
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
                        ], onBack: {}, onLog: { _, _ in }, onTakeBack: { _ in nil }, onEditMeal: { _ in },
                        onTargets: {})
                }
            }
            .preferredColorScheme(.light)
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
            let breakfast = FoodGallery.breakfast
            let entries = [
                FoodDay.Entry(
                    id: UUID(), slot: .breakfast, name: breakfast.name, mealId: breakfast.id, servings: 1,
                    kcal: breakfast.kcal, proteinG: breakfast.proteinG, source: .saved, figures: .known, estimated: false),
                lunch(figures: .estimating),
                dinner(),
                FoodDay.Entry(
                    id: UUID(), slot: .snack, name: "Protein bar", mealId: nil, servings: 1, kcal: 210, proteinG: 19.8,
                    source: .barcode, figures: .known, estimated: false, barcode: .init(code: "96385074", grams: 60)),
            ]
            return FoodDay(
                day: FoodGallery.today, target: FoodGallery.target, kcal: 1330, proteinG: 95.9, kcalLeft: 1170,
                proteinLeftG: 74.1, openSlots: [], entries: entries,
                meals: [FoodGallery.breakfast, FoodGallery.lunch, FoodGallery.dinner],
                streak: .init(
                    days: 13, state: .kept, previousBest: 9, loggedToday: true,
                    lastDays: (11...17).map { .init(date: CalendarDay(year: 2026, month: 11, day: $0), state: .kept) }),
                kcalMeasured: 752, proteinMeasuredG: 62.9, kcalEstimated: 578, proteinEstimatedG: 33, kcalLow: 1132,
                kcalHigh: 1532, unknown: 1, estimateRangePct: 35, products: [bar])
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
