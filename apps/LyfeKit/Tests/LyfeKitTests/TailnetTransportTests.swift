import Foundation
import Testing

@testable import LyfeKit

/// Stands in for the connection made to a chosen address.
private final class StubDirect: AddressedTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var failure: URLError.Code?

    var addresses: [String] { lock.withLock { log } }

    func fail(as code: URLError.Code) {
        lock.withLock { failure = code }
    }

    func send(_ request: URLRequest, to address: String) async throws -> (Data, HTTPURLResponse) {
        let failure = lock.withLock {
            log.append(address)
            return self.failure
        }
        if let failure { throw URLError(failure) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(#"{"token": "from-direct"}"#.utf8), response)
    }
}

private actor Asked {
    private(set) var hosts: [String] = []
    func note(_ host: String) { hosts.append(host) }
}

private let publicAnswer = ["199.38.181.54", "2607:f740:f::684"]
private let tailnetAnswer = ["100.101.102.103"]

@MainActor
@Suite struct TailnetTransportTests {
    let world = World()
    fileprivate let direct = StubDirect()

    private func model(system: [String], tailscale: [String], address: String = "lyfe.example.ts.net:8444")
        -> AppModel
    {
        world.backend.on("POST /v1/auth/sign-in", .ok(#"{"token": "from-system"}"#))
        world.backend.on("GET /v1/home", .ok(Fixture.home()))
        world.backend.on("POST /v1/sync", .ok(Fixture.sources()))
        let transport = TailnetTransport(
            system: world.backend, direct: direct,
            lookup: NameLookup { _ in system }, tailscale: NameLookup { _ in tailscale })
        let model = world.launch(transport: transport)
        model.serverAddress = address
        return model
    }

    @Test func aNameTheSystemResolvesInsideTheTailnetGoesTheUsualWay() async {
        let model = model(system: ["fd7a:115c:a1e0::1", "100.101.102.103"], tailscale: tailnetAnswer)
        await model.signIn(password: "a long password")
        #expect(model.phase == .signedIn)
        #expect(world.tokens.load() == "from-system")
        #expect(direct.addresses.isEmpty)
    }

    @Test func aNameLookedUpOutsideTailscaleIsReachedAtTailscalesAnswer() async {
        let model = model(system: publicAnswer, tailscale: tailnetAnswer)
        await model.signIn(password: "a long password")
        #expect(model.phase == .signedIn)
        #expect(world.tokens.load() == "from-direct")
        #expect(Set(direct.addresses) == ["100.101.102.103"])
        #expect(world.backend.requests.isEmpty)
    }

    @Test func aNameTheSystemCannotFindIsAlsoReachedAtTailscalesAnswer() async {
        let model = model(system: [], tailscale: tailnetAnswer)
        await model.signIn(password: "a long password")
        #expect(model.phase == .signedIn)
        #expect(Set(direct.addresses) == ["100.101.102.103"])
    }

    @Test func anAnswerFromTailscaleThatIsNotATailnetAddressIsNotUsed() async {
        let model = model(system: publicAnswer, tailscale: ["203.0.113.9"])
        await model.signIn(password: "a long password")
        #expect(direct.addresses.isEmpty)
        #expect(world.tokens.load() == "from-system")
    }

    @Test func withTailscaleOffTheMessageSaysSo() async {
        let model = model(system: publicAnswer, tailscale: [])
        world.backend.goDown(as: .timedOut)
        await model.signIn(password: "a long password")
        #expect(direct.addresses.isEmpty)
        #expect(
            model.signInProblem
                == "Can't reach the server: Tailscale did not answer for its name, and without it the name leads to "
                + "199.38.181.54, where lyfe is not published; open the Tailscale app and check it is connected (-1001).")
    }

    @Test func aServerThatIsDownIsNotBlamedOnTheLookup() async {
        let viaDirect = model(system: publicAnswer, tailscale: tailnetAnswer)
        direct.fail(as: .cannotConnectToHost)
        await viaDirect.signIn(password: "a long password")
        #expect(
            viaDirect.signInProblem
                == "Can't reach the server: it was found but refused the connection; check the port in the address "
                + "(-1004), at 100.101.102.103.")

        let viaSystem = model(system: tailnetAnswer, tailscale: tailnetAnswer)
        world.backend.goDown(as: .timedOut)
        await viaSystem.signIn(password: "a long password")
        #expect(viaSystem.signInProblem == "Can't reach the server: it did not answer in time (-1001), at 100.101.102.103.")
    }

    @Test func otherHostsAreNeverLookedUp() async {
        let asked = Asked()
        let lookup = NameLookup { host in
            await asked.note(host)
            return publicAnswer
        }
        world.backend.on("POST /v1/auth/sign-in", .ok(#"{"token": "from-system"}"#))
        world.backend.on("GET /v1/home", .ok(Fixture.home()))
        world.backend.on("POST /v1/sync", .ok(Fixture.sources()))
        let transport = TailnetTransport(system: world.backend, direct: direct, lookup: lookup, tailscale: lookup)
        for address in ["100.101.102.103:8444", "http://lyfe.example.ts.net:8787", "lyfe.example.com"] {
            let model = world.launch(transport: transport)
            model.serverAddress = address
            await model.signIn(password: "a long password")
            #expect(model.phase == .signedIn)
            await model.signOut()
        }
        #expect(await asked.hosts.isEmpty)
        #expect(direct.addresses.isEmpty)
    }
}

@Suite struct NameLookupTests {
    @Test func tailnetAddressesAreRecognised() {
        #expect(isTailnetAddress("100.101.102.103"))
        #expect(isTailnetAddress("100.64.0.1"))
        #expect(isTailnetAddress("100.127.255.254"))
        #expect(isTailnetAddress("fd7a:115c:a1e0::5a01:507b"))
        #expect(!isTailnetAddress("100.63.0.1"))
        #expect(!isTailnetAddress("100.128.0.1"))
        #expect(!isTailnetAddress("199.38.181.54"))
        #expect(!isTailnetAddress("2607:f740:f::bfe"))
        #expect(!isTailnetAddress("not an address"))
    }

    @Test func theSystemResolverAnswersForThisMachine() async {
        let addresses = await NameLookup.system.addresses("localhost")
        #expect(addresses.contains("127.0.0.1") || addresses.contains("::1"))
    }

    @Test func aTailscaleQuestionIsAWellFormedDNSQuery() {
        let query = TailscaleDNS.query(for: "host.example.ts.net", id: 0x1234)
        #expect(
            query.map { [UInt8]($0) }
                == [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
                + [4] + Array("host".utf8) + [7] + Array("example".utf8) + [2] + Array("ts".utf8)
                + [3] + Array("net".utf8) + [0, 0, 1, 0, 1])
        #expect(TailscaleDNS.query(for: "", id: 1) == nil)
        #expect(TailscaleDNS.query(for: "a..b", id: 1) == nil)
        #expect(TailscaleDNS.query(for: String(repeating: "x", count: 64) + ".ts.net", id: 1) == nil)
    }

    @Test func addressesAreReadFromATailscaleAnswer() throws {
        let query = try #require(TailscaleDNS.query(for: "host.example.ts.net", id: 0x1234))
        var answer = [UInt8](query)
        answer[2] = 0x84  // an answer, authoritative
        answer[7] = 2  // two records
        // An IPv6 record, then the IPv4 one; both name the question by pointer.
        answer += [0xC0, 0x0C, 0, 28, 0, 1, 0, 0, 2, 0x58, 0, 16] + [UInt8](repeating: 0xFD, count: 16)
        answer += [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 2, 0x58, 0, 4, 100, 101, 102, 103]
        #expect(TailscaleDNS.addresses(inAnswer: Data(answer), id: 0x1234) == ["100.101.102.103"])

        // Someone else's answer, an error answer, and a cut-off one give nothing.
        #expect(TailscaleDNS.addresses(inAnswer: Data(answer), id: 0x9999).isEmpty)
        var refused = answer
        refused[3] = 0x03
        #expect(TailscaleDNS.addresses(inAnswer: Data(refused), id: 0x1234).isEmpty)
        #expect(TailscaleDNS.addresses(inAnswer: Data(answer.dropLast(3)), id: 0x1234).isEmpty)
        #expect(TailscaleDNS.addresses(inAnswer: Data(query), id: 0x1234).isEmpty)
    }
}

@Suite struct HTTPMessageTests {
    private func response(_ text: String, atEnd: Bool = false) throws -> HTTPMessage? {
        try HTTPMessage.response(from: Data(text.utf8), atEnd: atEnd)
    }

    @Test func aRequestIsWrittenWithItsHeadersAndBody() throws {
        var request = URLRequest(url: URL(string: "https://lyfe.example.ts.net:8444/v1/auth/sign-in?x=a%20b")!)
        request.httpMethod = "POST"
        request.setValue("Bearer abc", forHTTPHeaderField: "Authorization")
        request.setValue("sneaky\r\nX-Injected: 1", forHTTPHeaderField: "X-Bad")
        request.httpBody = Data("{}".utf8)
        let text = String(decoding: try #require(HTTPMessage.request(request)), as: UTF8.self)
        #expect(
            text
                == "POST /v1/auth/sign-in?x=a%20b HTTP/1.1\r\nHost: lyfe.example.ts.net:8444\r\n"
                + "Authorization: Bearer abc\r\nContent-Length: 2\r\nAccept-Encoding: identity\r\n"
                + "Connection: close\r\n\r\n{}")
    }

    @Test func aRequestWithoutABodyStillSaysSoWhenItIsAPost() throws {
        var post = URLRequest(url: URL(string: "https://lyfe.example.ts.net/v1/sync")!)
        post.httpMethod = "POST"
        #expect(String(decoding: try #require(HTTPMessage.request(post)), as: UTF8.self).contains("Content-Length: 0\r\n"))
        let get = URLRequest(url: URL(string: "https://lyfe.example.ts.net")!)
        let text = String(decoding: try #require(HTTPMessage.request(get)), as: UTF8.self)
        #expect(text.hasPrefix("GET / HTTP/1.1\r\nHost: lyfe.example.ts.net\r\n"))
        #expect(!text.contains("Content-Length"))
    }

    @Test func anAnswerWithALengthIsCompleteOnceItHasArrived() throws {
        let head = "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: 27\r\n\r\n"
        #expect(try response("HTTP/1.1 401 Unauth") == nil)
        #expect(try response(head + #"{"error": "wrong_pa"#) == nil)
        let message = try #require(try response(head + #"{"error": "wrong_password"}"# + "extra"))
        #expect(message.status == 401)
        #expect(message.headers["content-type"] == "application/json")
        #expect(String(decoding: message.body, as: UTF8.self) == #"{"error": "wrong_password"}"#)
    }

    @Test func aChunkedAnswerIsPutBackTogether() throws {
        let head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        #expect(try response(head + "5\r\nhello\r\n6;note=1\r\n wor") == nil)
        let message = try #require(try response(head + "5\r\nhello\r\n6;note=1\r\n world\r\n0\r\n\r\n"))
        #expect(String(decoding: message.body, as: UTF8.self) == "hello world")
    }

    @Test func anAnswerWithoutALengthRunsUntilTheServerCloses() throws {
        let text = "HTTP/1.1 200 OK\r\n\r\nok"
        #expect(try response(text) == nil)
        #expect(try response(text, atEnd: true)?.body == Data("ok".utf8))
    }

    @Test func interimAndEmptyAnswersAreHandled() throws {
        let message = try #require(try response("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 204 No Content\r\n\r\n"))
        #expect(message.status == 204)
        #expect(message.body.isEmpty)
    }

    @Test func anythingElseIsRefused() {
        #expect(throws: HTTPMessage.Malformed.self) { try response("SSH-2.0-OpenSSH\r\n\r\n") }
        #expect(throws: HTTPMessage.Malformed.self) { try response("HTTP/1.1 200 OK\r\nContent-Le", atEnd: true) }
        #expect(throws: HTTPMessage.Malformed.self) {
            try response("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort", atEnd: true)
        }
        #expect(throws: HTTPMessage.Malformed.self) {
            try response("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n")
        }
    }
}

/// Runs against a real backend when LYFE_LIVE_SERVER is set, for example
/// `LYFE_LIVE_SERVER=name.tailnet.ts.net:8444@100.x.y.z swift test`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LYFE_LIVE_SERVER"] != nil))
struct LiveTransportTests {
    private let host: String
    private let address: String

    init() {
        let parts = (ProcessInfo.processInfo.environment["LYFE_LIVE_SERVER"] ?? "@").split(separator: "@")
        host = parts.first.map(String.init) ?? ""
        address = parts.last.map(String.init) ?? ""
    }

    @Test func tailscalesResolverGivesTheServersTailnetAddress() async {
        let name = host.split(separator: ":").first.map(String.init) ?? host
        #expect(await NameLookup.tailscale.addresses(name) == [address])
    }

    @Test func theBackendAnswersAtItsAddress() async throws {
        let health = URLRequest(url: URL(string: "https://\(host)/healthz")!)
        let (body, response) = try await DirectTLSTransport().send(health, to: address)
        #expect(response.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self) == "ok")

        var signIn = URLRequest(url: URL(string: "https://\(host)/v1/home")!)
        signIn.setValue("Bearer not-a-token", forHTTPHeaderField: "Authorization")
        let (_, refused) = try await DirectTLSTransport().send(signIn, to: address)
        #expect(refused.statusCode == 401)
    }

    @Test func aServerWhoseCertificateIsForAnotherNameIsRefused() async {
        // The right address, asked for under a name it has no certificate for.
        let port = host.split(separator: ":").last.map(String.init) ?? "443"
        let request = URLRequest(url: URL(string: "https://wrong-name.example.com:\(port)/healthz")!)
        await #expect(throws: URLError.self) {
            _ = try await DirectTLSTransport().send(request, to: address)
        }
    }

    @Test func aClosedPortFailsQuickly() async {
        var request = URLRequest(url: URL(string: "https://\(host.split(separator: ":")[0]):9/healthz")!)
        request.timeoutInterval = 5
        await #expect(throws: URLError.self) {
            _ = try await DirectTLSTransport().send(request, to: address)
        }
    }
}

/// Runs against a TLS server whose certificate no one vouches for, when
/// LYFE_UNTRUSTED_SERVER is set (`name:port@address`). For example, with
/// `openssl s_server -www` running on a self-signed certificate for `name`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LYFE_UNTRUSTED_SERVER"] != nil))
struct UntrustedServerTests {
    @Test func aCertificateNoOneVouchesForIsRefused() async {
        let parts = (ProcessInfo.processInfo.environment["LYFE_UNTRUSTED_SERVER"] ?? "@").split(separator: "@")
        var request = URLRequest(url: URL(string: "https://\(parts[0])/")!)
        request.timeoutInterval = 5
        do {
            _ = try await DirectTLSTransport().send(request, to: String(parts[1]))
            Issue.record("the untrusted server was accepted")
        } catch {
            #expect((error as? URLError)?.code == .secureConnectionFailed)
        }
    }
}
