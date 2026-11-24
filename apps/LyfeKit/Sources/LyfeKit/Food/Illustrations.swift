import Foundation
import SwiftUI

/// A meal's illustration as the backend has it now: whose it is, and a
/// version that moves on when the photo is drawn again in a new look.
public struct Illustration: Hashable, Sendable {
    public var meal: UUID
    public var version: Int

    public init(meal: UUID, version: Int) {
        self.meal = meal
        self.version = version
    }
}

/// Meal illustrations fetched from the backend, kept on this phone. One
/// version of a drawing never changes, so it is fetched once; they are
/// small (about 100 kB) and kept in the caches folder, which the system may
/// empty, after which they are fetched again.
public struct IllustrationStore: Sendable {
    private let folder: URL

    public init(directory: URL) {
        folder = directory.appending(path: "meal-illustrations", directoryHint: .isDirectory)
    }

    public static func standard() -> IllustrationStore {
        let base =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return IllustrationStore(directory: base.appending(path: "lyfe"))
    }

    public func picture(_ illustration: Illustration) -> Data? {
        try? Data(contentsOf: file(illustration))
    }

    /// Keeps a drawing, in place of any earlier version of the same meal's.
    public func keep(_ png: Data, for illustration: Illustration) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let meal = illustration.meal.uuidString.lowercased()
        for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix(meal) {
            try? FileManager.default.removeItem(at: old)
        }
        try? png.write(to: file(illustration), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func file(_ illustration: Illustration) -> URL {
        folder.appending(path: "\(illustration.meal.uuidString.lowercased())-\(illustration.version).png")
    }
}

/// Where the rows that show an illustration fetch it from: the app model,
/// or a made-up picture in the galleries.
struct IllustrationSource: Sendable {
    var fetch: @Sendable (Illustration) async -> Data?

    static let none = IllustrationSource { _ in nil }
}

extension EnvironmentValues {
    @Entry var mealIllustration: IllustrationSource = .none
}

/// A meal's illustration, once it has arrived. It is drawn on the app's
/// paper colour, so it sits on the screen without a frame; nothing shows
/// while it loads.
struct MealIllustration: View {
    let illustration: Illustration

    @Environment(\.mealIllustration) private var load
    @State private var picture: Data?

    var body: some View {
        Group {
            if let picture, let image = pictureImage(picture) {
                image.resizable().interpolation(.medium).scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: illustration) { picture = await load.fetch(illustration) }
        .accessibilityHidden(true)
    }
}

extension FoodDay.Entry {
    /// A photo, or a meal with one among its parts, still to be drawn. It
    /// is drawn after its estimate, once the image model is loaded, which
    /// can take a couple of minutes.
    var awaitsDrawing: Bool {
        if from == .built { return (parts ?? []).contains { $0.awaitsDrawing } }
        return from == .photo && photo?.hasPhoto == true && photo?.illustrated != true
    }
}

/// What a screen is waiting on the Spark for.
struct SparkWait: Hashable {
    /// A photo still with the vision model: looked at again every 4 s.
    var estimating = false
    /// Photos estimated but not drawn yet: every 15 s, for 5 minutes.
    var drawing: [UUID] = []

    init(_ entries: [FoodDay.Entry]) {
        estimating = entries.contains { $0.counted.contains { $0.figures == .estimating } }
        drawing = entries.filter(\.awaitsDrawing).map(\.id)
    }
}

extension View {
    /// Fetches the day again while something on screen waits on the Spark,
    /// so an estimate or a drawing shows up without leaving the screen.
    func followingTheSpark(_ wait: SparkWait, reload: @escaping () async -> Void) -> some View {
        task(id: wait) {
            var drawingLooks = 0
            while !Task.isCancelled {
                if wait.estimating {
                    try? await Task.sleep(for: .seconds(4))
                } else if !wait.drawing.isEmpty, drawingLooks < 20 {
                    drawingLooks += 1
                    try? await Task.sleep(for: .seconds(15))
                } else {
                    return
                }
                guard !Task.isCancelled else { return }
                await reload()
            }
        }
    }
}
