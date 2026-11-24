import CryptoKit
import Foundation
import SwiftUI

/// The icon of a food in the ingredient catalogue: a small drawing of it,
/// made on the Spark from its name alone. `look` is the look the backend
/// draws icons in now; when it moves on, the icon is fetched again.
public struct FoodIcon: Hashable, Sendable {
    /// The food's name, as the catalogue has it.
    public var name: String
    public var look: Int

    public init(name: String, look: Int) {
        self.name = name
        self.look = look
    }

    /// What the icon is kept by: the name on one line and in lower case, as
    /// the backend keeps it, so a food spelled two ways is one icon.
    var key: String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}

/// The catalogue as the backend needs to know it to draw every icon ahead
/// of time, so that none is waited for on the phone.
public enum FoodCatalogue {
    /// Every name an icon is asked for by, in the order to draw them: what
    /// each category is drawn as, then the staples, which are the first
    /// tiles shown, then the rest as the catalogue lists them.
    public static var iconNames: [String] {
        CommonIngredient.categories.compactMap { CommonIngredient.categoryPictures[$0] }
            + CommonIngredient.library.map(\.name)
    }
}

/// What asking for a food's icon came to.
public enum FoodIconAnswer: Equatable, Sendable {
    case drawn(Data)
    /// The Spark has it to draw: worth asking again shortly.
    case waiting
    /// None is coming now: no connection, a backend that draws none, or a
    /// food the model could not draw.
    case none
}

/// Food icons fetched from the backend, kept on this phone. An icon in one
/// look never changes, so it is fetched once; they are small (about 10 kB)
/// and kept in the caches folder, which the system may empty, after which
/// they are fetched again.
public struct FoodIconStore: Sendable {
    private let folder: URL

    public init(directory: URL) {
        folder = directory.appending(path: "food-icons", directoryHint: .isDirectory)
    }

    public static func standard() -> FoodIconStore {
        let base =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return FoodIconStore(directory: base.appending(path: "lyfe"))
    }

    /// The icon in the look asked for.
    public func picture(_ icon: FoodIcon) -> Data? {
        try? Data(contentsOf: file(icon))
    }

    /// The icon in whatever look this phone has it: shown rather than
    /// nothing while a new look is drawn, or with no connection.
    public func anyPicture(named name: String) -> Data? {
        let stem = Self.stem(FoodIcon(name: name, look: 0))
        let kept = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return kept.first { $0.lastPathComponent.hasPrefix(stem) }.flatMap { try? Data(contentsOf: $0) }
    }

    /// Keeps an icon, in place of the same food's in any earlier look.
    public func keep(_ png: Data, for icon: FoodIcon) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = Self.stem(icon)
        for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix(stem) {
            try? FileManager.default.removeItem(at: old)
        }
        try? png.write(to: file(icon), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func file(_ icon: FoodIcon) -> URL {
        folder.appending(path: "\(Self.stem(icon))\(icon.look).png")
    }

    /// A food's name as a file name: a name can hold anything, so it is
    /// hashed. Ends in a dash, so one food's is never the start of another's.
    private static func stem(_ icon: FoodIcon) -> String {
        let digest = SHA256.hash(data: Data(icon.key.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined() + "-"
    }
}

/// Where the picker's tiles get a food's icon from: the app model, or
/// made-up pictures in the galleries.
struct FoodIconSource: Sendable {
    /// The icon as this phone already has it; asks nobody.
    var kept: @MainActor @Sendable (String) -> Data?
    /// Asks the backend, which is what gets an icon drawn.
    var ask: @MainActor @Sendable (String) async -> FoodIconAnswer

    static let none = FoodIconSource(kept: { _ in nil }, ask: { _ in .none })
}

extension EnvironmentValues {
    @Entry var foodIcons: FoodIconSource = .none
}

/// A food's picture on its tile in the picker: its own icon once the Spark
/// has drawn it, its category's until then, and an empty frame before
/// either. A food is asked for only once it has stayed on screen a moment,
/// so swiping through the catalogue does not have the Spark draw all of it.
struct FoodIconView: View {
    let food: CommonIngredient

    @Environment(\.foodIcons) private var source
    @State private var own: Data?
    @State private var category: Data?

    /// How long a tile stays on screen before its icon is asked for.
    static let linger = Duration.milliseconds(600)

    var body: some View {
        Group {
            if let image = (own ?? category).flatMap(pictureImage) {
                image.resizable().interpolation(.medium).scaledToFit()
            } else {
                Rectangle().strokeBorder(Poster.ink.opacity(0.18), lineWidth: 2).padding(10)
            }
        }
        .task(id: food.id) { await follow() }
        .accessibilityHidden(true)
    }

    /// Shows what this phone has, then asks the backend for the rest and
    /// keeps asking while the Spark draws: a few seconds each with the
    /// model loaded, a couple of minutes when it has to load first.
    private func follow() async {
        let subject = food.categoryPicture
        own = source.kept(food.name)
        category = own == nil ? subject.flatMap(source.kept) : nil
        try? await Task.sleep(for: Self.linger)
        // What is kept may be from an earlier look, so it is asked for
        // even so; one in the look of now is answered from this phone.
        var wantsOwn = true
        var wantsCategory = own == nil && subject != nil
        for attempt in 0..<40 where wantsOwn || wantsCategory {
            guard !Task.isCancelled else { return }
            if wantsCategory, let subject {
                switch await source.ask(subject) {
                case .drawn(let png): (category, wantsCategory) = (png, false)
                case .none: wantsCategory = false
                case .waiting: break
                }
            }
            if wantsOwn {
                switch await source.ask(food.name) {
                case .drawn(let png): (own, wantsOwn, wantsCategory) = (png, false, false)
                case .none: wantsOwn = false
                case .waiting: break
                }
            }
            guard wantsOwn || wantsCategory else { return }
            try? await Task.sleep(for: .seconds(attempt < 8 ? 2 : 8))
        }
    }
}
