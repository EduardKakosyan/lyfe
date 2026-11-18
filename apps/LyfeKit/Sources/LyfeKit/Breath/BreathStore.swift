import Foundation

/// Breath sessions kept on this phone: the one in progress, and the
/// finished ones the backend has not confirmed yet.
///
/// A session is written here the moment it starts and after every tap, so
/// closing the app or losing the connection never loses a hold. A finished
/// session stays in the outbox until the backend has answered for it.
public struct BreathStore: Sendable {
    private let activeFile: URL
    private let outboxFile: URL

    public init(directory: URL) {
        activeFile = directory.appending(path: "breath-active.json")
        outboxFile = directory.appending(path: "breath-outbox.json")
    }

    /// The app's own Application Support folder.
    public static func standard() -> BreathStore {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return BreathStore(directory: base.appending(path: "lyfe"))
    }

    // MARK: The session in progress

    public func loadActive() -> BreathRun? {
        read(BreathRun.self, from: activeFile)
    }

    public func saveActive(_ run: BreathRun) {
        write(run, to: activeFile)
    }

    public func clearActive() {
        try? FileManager.default.removeItem(at: activeFile)
    }

    // MARK: Finished, not yet confirmed

    /// Oldest first.
    public func outbox() -> [BreathRun] {
        read([BreathRun].self, from: outboxFile) ?? []
    }

    public func enqueue(_ run: BreathRun) {
        var runs = outbox()
        guard !runs.contains(where: { $0.id == run.id }) else { return }
        runs.append(run)
        write(runs, to: outboxFile)
    }

    /// Called once the backend has confirmed a session.
    public func remove(_ id: UUID) {
        let runs = outbox().filter { $0.id != id }
        if runs.isEmpty {
            try? FileManager.default.removeItem(at: outboxFile)
        } else {
            write(runs, to: outboxFile)
        }
    }

    // Times are kept to the millisecond here, unlike in what is sent.
    private func read<Value: Decodable>(_ type: Value.Type, from file: URL) -> Value? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(type, from: data)
    }

    private func write<Value: Encodable>(_ value: Value, to file: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
