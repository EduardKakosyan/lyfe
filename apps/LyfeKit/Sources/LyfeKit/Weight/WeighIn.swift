import Foundation

/// The morning prompt, as the app registers it with the system. The
/// backend sends the prompt under the same category name, which is what
/// gives it a field to type the weight into.
public enum WeighInPrompt {
    public static let category = "WEIGH_IN"
    public static let replyAction = "WEIGH_IN_REPLY"
}

/// One weight the owner typed, as it is kept on this phone and sent.
public struct WeighIn: Codable, Equatable, Sendable, Identifiable {
    /// Made here when the weight is typed, so sending it twice stores it once.
    public var id: UUID
    public var measuredAt: Date
    public var value: Double
    /// "kg" or "lb".
    public var unit: String

    public init(id: UUID = UUID(), measuredAt: Date, value: Double, unit: String) {
        self.id = id
        self.measuredAt = measuredAt
        self.value = value
        self.unit = unit
    }
}

/// A weight read from what was typed: "82.4", "82,4", "82.4 kg", "181lb".
public struct TypedWeight: Equatable, Sendable {
    public var value: Double
    public var unit: String

    /// The lightest and heaviest weights taken in each unit; anything else
    /// is a slip (a missing or extra digit), and is refused before it can
    /// pull the average.
    static let plausible: [String: ClosedRange<Double>] = ["kg": 20...400, "lb": 44...880]

    init(value: Double, unit: String) {
        self.value = value
        self.unit = unit
    }

    /// Nil when the text is not a weight. A unit typed after the number
    /// wins over `unit`, the one lyfe shows.
    public init?(_ text: String, unit: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let match = cleaned.wholeMatch(of: /([0-9]{1,3}(?:[.,][0-9]{1,2})?)\s*(kg|kgs|lb|lbs)?/),
            let value = Double(match.1.replacingOccurrences(of: ",", with: "."))
        else { return nil }
        let typedUnit = match.2.map { $0.hasPrefix("kg") ? "kg" : "lb" } ?? unit
        guard let range = Self.plausible[typedUnit], range.contains(value) else { return nil }
        self.value = value
        self.unit = typedUnit
    }
}

/// Weigh-ins typed on this phone that the backend has not confirmed yet.
///
/// A weight is written here the moment it is typed, before anything is
/// sent, so a reply typed with no connection is not lost. It stays until
/// the backend has answered for it.
public struct WeighInStore: Sendable {
    private let file: URL

    public init(directory: URL) {
        file = directory.appending(path: "weigh-in-outbox.json")
    }

    /// The app's own Application Support folder.
    public static func standard() -> WeighInStore {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return WeighInStore(directory: base.appending(path: "lyfe"))
    }

    /// Oldest first.
    public func outbox() -> [WeighIn] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? Self.decoder.decode([WeighIn].self, from: data)) ?? []
    }

    public func enqueue(_ weighIn: WeighIn) {
        var all = outbox()
        guard !all.contains(where: { $0.id == weighIn.id }) else { return }
        all.append(weighIn)
        write(all)
    }

    /// Called once the backend has answered for a weigh-in.
    public func remove(_ id: UUID) {
        let rest = outbox().filter { $0.id != id }
        if rest.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else {
            write(rest)
        }
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private func write(_ all: [WeighIn]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(all) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Readable while the phone is locked (after its first unlock), since
        // a reply typed on the lock screen is handled without unlocking.
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// What became of a weight typed into the prompt or the app.
public enum WeighInOutcome: Equatable, Sendable {
    /// The backend has it.
    case sent
    /// Kept on this phone; sent when the backend can be reached.
    case saved
    /// Not a weight; nothing was kept.
    case unreadable
    /// The backend would not take it; nothing was kept.
    case refused
}
