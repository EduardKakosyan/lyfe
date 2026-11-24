import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A meal built from parts, or one thing logged from a photo and a line, a
/// barcode or typed figures, as it is kept on this phone until the backend
/// has it.
public struct FoodCapture: Codable, Equatable, Sendable, Identifiable {
    /// Made here when the meal is logged, so sending it twice logs it once.
    public var id: UUID
    public var eatenAt: Date
    public var slot: MealSlot
    public var kind: Kind
    /// The built meal this is a part of: one already logged, which it
    /// joins, or one still being built here, which a photo is sent ahead of.
    public var partOf: UUID?

    public enum Kind: Codable, Equatable, Sendable {
        /// The photo itself is kept beside the list, as a file named by the
        /// capture's id; `hasPhoto` is false for a meal described in words.
        case photo(note: String, hasPhoto: Bool)
        /// `product` is what this phone knew of the code when it was
        /// scanned, to show until the backend has it.
        case barcode(code: String, grams: Double, product: Product?)
        /// A food typed by hand, weighed or whole.
        case typed(Ingredient)
        /// A meal built from parts, in the order added. Its photos are
        /// captures of their own, sent ahead of it.
        case built(name: String, parts: [MealPart])
    }

    public init(id: UUID = UUID(), eatenAt: Date, slot: MealSlot, kind: Kind, partOf: UUID? = nil) {
        self.id = id
        self.eatenAt = eatenAt
        self.slot = slot
        self.kind = kind
        self.partOf = partOf
    }

    /// What the meal is called while it waits to be sent.
    public var name: String {
        switch kind {
        case .photo(let note, _):
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Photo meal" : trimmed
        case .barcode(let code, _, let product):
            return product?.name ?? "Barcode \(code)"
        case .typed(let food):
            return food.name
        case .built(let name, _):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? slot.title : trimmed
        }
    }
}

/// Photo and barcode meals logged on this phone that the backend has not
/// confirmed yet, and the photos that go with them.
///
/// A meal is written here before anything is sent, so one logged with no
/// connection is not lost and still counts for the day it was eaten on.
/// A photo is kept for a few days after it is sent, so the estimate can be
/// shown with it without fetching it back.
public struct CaptureStore: Sendable {
    private let file: URL
    private let photos: URL

    public init(directory: URL) {
        file = directory.appending(path: "food-captures.json")
        photos = directory.appending(path: "food-photos", directoryHint: .isDirectory)
    }

    public static func standard() -> CaptureStore {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return CaptureStore(directory: base.appending(path: "lyfe"))
    }

    /// Oldest first.
    public func outbox() -> [FoodCapture] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? Self.decoder.decode([FoodCapture].self, from: data)) ?? []
    }

    /// Keeps a meal, and its photo when it has one, until it is sent.
    public func enqueue(_ capture: FoodCapture, jpeg: Data? = nil) {
        var all = outbox()
        guard !all.contains(where: { $0.id == capture.id }) else { return }
        if let jpeg {
            try? FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
            try? jpeg.write(to: photoFile(capture.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        all.append(capture)
        write(all)
    }

    /// Called once the backend has answered for a meal. Its photo stays for
    /// showing; `forget` drops that too, for a meal taken back.
    public func remove(_ id: UUID, forget: Bool = false) {
        let rest = outbox().filter { $0.id != id }
        if rest.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else {
            write(rest)
        }
        if forget {
            try? FileManager.default.removeItem(at: photoFile(id))
        }
    }

    /// The photo of a meal logged on this phone, while it is kept.
    public func photo(_ id: UUID) -> Data? {
        try? Data(contentsOf: photoFile(id))
    }

    /// Drops photos of sent meals older than `age`. Photos of meals still
    /// waiting to be sent are kept whatever their age.
    public func prunePhotos(olderThan age: TimeInterval, now: Date = Date()) {
        let waiting = Set(outbox().map(\.id))
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: photos, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !waiting.contains(id) else {
                continue
            }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > age {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func photoFile(_ id: UUID) -> URL {
        photos.appending(path: "\(id.uuidString.lowercased()).jpg")
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private func write(_ all: [FoodCapture]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(all) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Making a camera picture into what is sent: a JPEG no larger than the
/// model needs, upright, and without the location and other details the
/// camera writes into the file.
public enum MealPhoto {
    /// The longest side, in pixels. The model sees less than this.
    public static let maxSide = 1280

    /// The picture as a JPEG to send, or nil when it is not a picture.
    public static func prepare(_ data: Data, maxSide: Int = maxSide, quality: Double = 0.72) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Turned the way the camera was held.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        // Only the pixels go in: no location, time or camera details.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

extension MealSlot {
    /// The part of the day a meal eaten at `date` most likely belongs to,
    /// as a starting point the owner can change.
    public static func likely(at date: Date, calendar: Calendar = .current) -> MealSlot {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (parts.hour ?? 12) * 60 + (parts.minute ?? 0)
        switch minutes {
        case 4 * 60..<(10 * 60 + 30): return .breakfast
        case (10 * 60 + 30)..<(14 * 60 + 30): return .lunch
        case (14 * 60 + 30)..<(17 * 60): return .snack
        case 17 * 60..<(22 * 60): return .dinner
        default: return .snack
        }
    }
}

extension FoodTyping {
    /// A barcode typed by hand: its digits, from EAN-8 to GTIN-14.
    public static func barcode(_ text: String) -> String? {
        let digits = text.filter { !$0.isWhitespace && $0 != "-" }
        guard (8...14).contains(digits.count), digits.allSatisfy(\.isASCIIDigitCharacter) else { return nil }
        return digits
    }

    /// Grams eaten, as typed.
    public static func grams(_ text: String) -> Result<Double, FoodSlip> {
        guard let grams = number(text), grams > 0, grams <= 3000 else {
            return .failure(FoodSlip("Type the grams eaten, like 45"))
        }
        return .success(grams)
    }

    /// The fields of a label typed by hand, or the first thing wrong.
    public static func label(code: String, name: String, kcal: String, protein: String, serving: String)
        -> Result<Product, FoodSlip>
    {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(FoodSlip("Name the product")) }
        guard name.count <= MealDraft.maxNameLength else { return .failure(FoodSlip("That name is too long")) }
        guard let kcal = number(kcal), kcal <= 900 else {
            return .failure(FoodSlip("Type the kcal in 100 g from the label, 0 to 900"))
        }
        guard let protein = number(protein), protein <= 100 else {
            return .failure(FoodSlip("Type the protein in 100 g from the label, 0 to 100"))
        }
        var servingG: Double?
        if !serving.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let grams = number(serving), grams > 0, grams <= 2000 else {
                return .failure(FoodSlip("Type the serving in grams, or leave it empty"))
            }
            servingG = grams
        }
        return .success(
            Product(code: code, name: name, kcalPer100g: kcal, proteinPer100g: protein, servingG: servingG, origin: "label"))
    }

    /// A whole meal's figures typed instead of the model's.
    public static func mealFigures(kcal: String, protein: String) -> Result<(kcal: Int, proteinG: Double), FoodSlip> {
        guard let kcal = number(kcal), kcal == kcal.rounded(), kcal <= 5000 else {
            return .failure(FoodSlip("Type the meal's kcal, 0 to 5000"))
        }
        guard let protein = number(protein), protein <= 400 else {
            return .failure(FoodSlip("Type the meal's protein in grams, 0 to 400"))
        }
        return .success((Int(kcal), protein))
    }
}

extension Character {
    fileprivate var isASCIIDigitCharacter: Bool { isASCII && isNumber }
}
