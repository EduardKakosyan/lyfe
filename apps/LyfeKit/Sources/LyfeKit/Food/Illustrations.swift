import Foundation
import SwiftUI

/// Meal illustrations fetched from the backend, kept on this phone. One
/// never changes once drawn, so it is fetched once; they are small (a
/// five-colour PNG is about 10 kB) and kept in the caches folder, which the
/// system may empty, after which they are fetched again.
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

    public func illustration(_ id: UUID) -> Data? {
        try? Data(contentsOf: file(id))
    }

    public func keep(_ png: Data, for id: UUID) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? png.write(to: file(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func file(_ id: UUID) -> URL {
        folder.appending(path: "\(id.uuidString.lowercased()).png")
    }
}

/// Where the rows that show an illustration fetch it from: the app model,
/// or a made-up picture in the galleries.
struct IllustrationSource: Sendable {
    var fetch: @Sendable (UUID) async -> Data?

    static let none = IllustrationSource { _ in nil }
}

extension EnvironmentValues {
    @Entry var mealIllustration: IllustrationSource = .none
}

/// A meal's illustration, once it has arrived. It is drawn on the app's
/// paper colour, so it sits on the screen without a frame; nothing shows
/// while it loads.
struct MealIllustration: View {
    let id: UUID

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
        .task(id: id) { picture = await load.fetch(id) }
        .accessibilityHidden(true)
    }
}
