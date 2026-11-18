import Foundation

/// The HTTP/1.1 text sent and read by `DirectTLSTransport`, which cannot
/// use URLSession because it connects to an address it chose itself.
struct HTTPMessage: Equatable {
    var status: Int
    /// Header names in lower case. A repeated header keeps its last value.
    var headers: [String: String]
    var body: Data

    struct Malformed: Error {}

    /// The bytes of a request, asking the server to close afterwards so the
    /// end of the answer is unambiguous.
    static func request(_ request: URLRequest) -> Data? {
        guard let url = request.url, let host = url.host(percentEncoded: true),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        else { return nil }
        let method = request.httpMethod ?? "GET"
        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery {
            target += "?" + query
        }
        let body = request.httpBody ?? Data()

        var lines = ["\(method) \(target) HTTP/1.1"]
        lines.append("Host: " + (url.port.map { "\(host):\($0)" } ?? host))
        let reserved: Set<String> = ["host", "content-length", "connection", "accept-encoding", "transfer-encoding"]
        for (name, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) {
            let breaksLine = (name + value).contains { $0.isNewline }
            guard !reserved.contains(name.lowercased()), !breaksLine, !name.contains(":") else { continue }
            lines.append("\(name): \(value)")
        }
        if !body.isEmpty || !["GET", "HEAD"].contains(method.uppercased()) {
            lines.append("Content-Length: \(body.count)")
        }
        lines.append("Accept-Encoding: identity")
        lines.append("Connection: close")
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        return data
    }

    /// Reads a response from what has arrived so far. Returns nil when more
    /// is needed; `atEnd` says the connection has closed and no more will come.
    static func response(from received: Data, atEnd: Bool) throws -> HTTPMessage? {
        var data = received[...]
        while true {
            guard let headEnd = data.firstRange(of: Data("\r\n\r\n".utf8)) else {
                if atEnd { throw Malformed() }
                return nil
            }
            let head = String(decoding: data[..<headEnd.lowerBound], as: UTF8.self)
            let rest = data[headEnd.upperBound...]
            var lines = head.components(separatedBy: "\r\n")[...]
            let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2)
            guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."), let status = Int(statusLine[1]),
                (100...599).contains(status)
            else { throw Malformed() }
            if (100..<200).contains(status) {
                // An interim answer; the real one follows.
                data = rest
                continue
            }

            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { throw Malformed() }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }

            if status == 204 || status == 304 {
                return HTTPMessage(status: status, headers: headers, body: Data())
            }
            if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
                guard let body = try dechunk(rest) else {
                    if atEnd { throw Malformed() }
                    return nil
                }
                return HTTPMessage(status: status, headers: headers, body: body)
            }
            if let length = headers["content-length"] {
                guard let count = Int(length), count >= 0 else { throw Malformed() }
                guard rest.count >= count else {
                    if atEnd { throw Malformed() }
                    return nil
                }
                return HTTPMessage(status: status, headers: headers, body: Data(rest.prefix(count)))
            }
            // No length given: the body runs until the server closes.
            return atEnd ? HTTPMessage(status: status, headers: headers, body: Data(rest)) : nil
        }
    }

    /// The body of a chunked answer, or nil if its last chunk has not arrived.
    private static func dechunk(_ chunked: Data.SubSequence) throws -> Data? {
        var rest = chunked
        var body = Data()
        let lineEnd = Data("\r\n".utf8)
        while true {
            guard let sizeEnd = rest.firstRange(of: lineEnd) else { return nil }
            let sizeLine = String(decoding: rest[..<sizeEnd.lowerBound], as: UTF8.self)
            let sizeText = sizeLine.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                throw Malformed()
            }
            rest = rest[sizeEnd.upperBound...]
            if size == 0 {
                return body
            }
            guard rest.count >= size + 2 else { return nil }
            body.append(rest.prefix(size))
            rest = rest.dropFirst(size)
            guard rest.starts(with: lineEnd) else { throw Malformed() }
            rest = rest.dropFirst(2)
        }
    }
}
