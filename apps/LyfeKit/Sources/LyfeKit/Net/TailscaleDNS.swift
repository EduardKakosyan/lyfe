import Foundation
import Network

extension NameLookup {
    /// Asks Tailscale's own resolver. It answers inside the tunnel whenever
    /// Tailscale is connected, whatever DNS the rest of the device uses.
    public static let tailscale = NameLookup { host in await TailscaleDNS.addresses(for: host) }
}

/// A one-question DNS client for Tailscale's resolver at 100.100.100.100.
enum TailscaleDNS {
    static let resolver: NWEndpoint.Host = "100.100.100.100"

    /// A query for the name's IPv4 addresses, or nil if the name cannot be
    /// put in a DNS question.
    static func query(for host: String, id: UInt16) -> Data? {
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return nil }
        for label in labels {
            let text = Array(label.utf8)
            guard (1...63).contains(text.count) else { return nil }
            bytes.append(UInt8(text.count))
            bytes.append(contentsOf: text)
        }
        bytes.append(contentsOf: [0, 0, 1, 0, 1])
        guard bytes.count <= 512 else { return nil }
        return Data(bytes)
    }

    /// The IPv4 addresses in an answer to the query with this id. Anything
    /// malformed, mismatched or reporting an error gives none.
    static func addresses(inAnswer answer: Data, id: UInt16) -> [String] {
        let bytes = [UInt8](answer)
        guard bytes.count >= 12,
            UInt16(bytes[0]) << 8 | UInt16(bytes[1]) == id,
            bytes[2] & 0x80 != 0,
            bytes[3] & 0x0F == 0
        else { return [] }
        let questions = Int(bytes[4]) << 8 | Int(bytes[5])
        let answers = Int(bytes[6]) << 8 | Int(bytes[7])
        var at = 12

        func skipName() -> Bool {
            while at < bytes.count {
                let length = Int(bytes[at])
                if length & 0xC0 == 0xC0 {
                    at += 2
                    return at <= bytes.count
                }
                at += 1 + length
                if length == 0 { return at <= bytes.count }
            }
            return false
        }

        for _ in 0..<questions {
            guard skipName() else { return [] }
            at += 4
        }
        var found: [String] = []
        for _ in 0..<answers {
            guard skipName(), at + 10 <= bytes.count else { return found }
            let type = Int(bytes[at]) << 8 | Int(bytes[at + 1])
            let length = Int(bytes[at + 8]) << 8 | Int(bytes[at + 9])
            at += 10
            guard at + length <= bytes.count else { return found }
            if type == 1, length == 4 {
                found.append(bytes[at..<at + 4].map { String($0) }.joined(separator: "."))
            }
            at += length
        }
        return found
    }

    /// Tailscale's answer for the name, or nothing if it has none in time:
    /// Tailscale is off, or does not know the name.
    static func addresses(for host: String, within seconds: Double = 2) async -> [String] {
        let id = UInt16.random(in: 1...UInt16.max)
        guard let query = query(for: host, id: id) else { return [] }
        let connection = NWConnection(host: resolver, port: 53, using: .udp)
        let answer = FirstAnswer<[String]>()
        let queue = DispatchQueue(label: "lyfe.tailscale-dns")

        let found: [String] = await withCheckedContinuation { continuation in
            answer.wait(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(
                        content: query,
                        completion: .contentProcessed { error in
                            if error != nil { answer.give([]) }
                        })
                    connection.receiveMessage { data, _, _, _ in
                        answer.give(data.map { addresses(inAnswer: $0, id: id) } ?? [])
                    }
                case .failed, .waiting:
                    answer.give([])
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + seconds) {
                answer.give([])
            }
        }
        connection.cancel()
        return found
    }
}
