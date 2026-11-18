import Foundation
import Testing

@testable import LyfeKit

@MainActor
@Suite struct SignInTests {
    @Test func signingInStoresTheTokenAndShowsHome() async throws {
        let world = World()
        world.backend.on("POST /v1/auth/sign-in", .ok(#"{"token": "fresh-token"}"#))
        world.backend.on("GET /v1/home", .ok(Fixture.home(done: 1)))
        world.backend.on("POST /v1/sync", .ok(Fixture.sources()))
        let model = world.launch()
        #expect(model.phase == .signedOut)

        model.serverAddress = "lyfe.example.ts.net:8444"
        await model.signIn(password: "a long password")

        #expect(model.phase == .signedIn)
        #expect(model.signInProblem == nil)
        #expect(world.tokens.load() == "fresh-token")
        #expect(world.addresses.load() == "lyfe.example.ts.net:8444")
        #expect(model.home?.gym.done == 1)

        let signIn = try #require(world.backend.lastRequest("POST /v1/auth/sign-in"))
        #expect(signIn.url?.absoluteString == "https://lyfe.example.ts.net:8444/v1/auth/sign-in")
        let body = try JSONSerialization.jsonObject(with: signIn.httpBody ?? Data()) as? [String: String]
        #expect(body == ["password": "a long password", "device_name": "Test iPhone"])
        let home = try #require(world.backend.lastRequest("GET /v1/home"))
        #expect(home.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token")
    }

    @Test func theServerAddressIsPrefilledFromTheBuild() async {
        let backend = StubBackend()
        backend.on("POST /v1/auth/sign-in", .ok(#"{"token": "fresh-token"}"#))
        backend.on("GET /v1/home", .ok(Fixture.home(done: 1)))
        backend.on("POST /v1/sync", .ok(Fixture.sources()))
        func launch(saved: String?) -> AppModel {
            AppModel(
                tokens: MemoryTokenStore(), addresses: MemoryServerAddressStore(address: saved),
                cache: HomeCache(directory: Fixture.temporaryDirectory()), transport: backend,
                deviceName: "Test iPhone", defaultServerAddress: "built-in.example.ts.net:8444")
        }

        // Nothing saved yet: only the password is left to type.
        let model = launch(saved: nil)
        #expect(model.serverAddress == "built-in.example.ts.net:8444")
        #expect(model.phase == .signedOut)
        await model.signIn(password: "a long password")
        #expect(model.phase == .signedIn)
        #expect(backend.lastRequest("POST /v1/auth/sign-in")?.url?.host == "built-in.example.ts.net")

        // An address the owner typed and saved wins over the built-in one.
        #expect(launch(saved: "other.example.ts.net").serverAddress == "other.example.ts.net")
        #expect(launch(saved: "").serverAddress == "built-in.example.ts.net:8444")
    }

    @Test func aWrongPasswordIsExplainedAndNothingIsStored() async {
        let world = World()
        world.backend.on("POST /v1/auth/sign-in", .init(status: 401, body: #"{"error": "wrong_password"}"#))
        let model = world.launch()
        model.serverAddress = "lyfe.example.ts.net"
        await model.signIn(password: "nope")
        #expect(model.phase == .signedOut)
        #expect(model.signInProblem == "Wrong password.")
        #expect(world.tokens.load() == nil)
    }

    @Test func otherSignInFailuresAreExplained() async {
        let cases: [(StubBackend.Reply, String)] = [
            (.init(status: 429, body: #"{"error": "too_many_attempts", "retry_after_s": 8}"#),
                "Too many attempts. Try again in 8 s."),
            (.init(status: 429, body: #"{"error": "too_many_attempts", "retry_after_s": 900}"#),
                "Too many attempts. Try again in 15 min."),
            (.init(status: 503, body: #"{"error": "no_password_set"}"#),
                "The server has no password yet. Run lyfe-server set-password on it."),
            (.init(status: 500, body: #"{"error": "internal"}"#), "The server answered with an error (500)."),
            (.ok("<html>hello</html>"), "The server's answer could not be read. Is this a lyfe server?"),
        ]
        for (reply, message) in cases {
            let world = World()
            world.backend.on("POST /v1/auth/sign-in", reply)
            let model = world.launch()
            model.serverAddress = "lyfe.example.ts.net"
            await model.signIn(password: "a long password")
            #expect(model.signInProblem == message)
            #expect(model.phase == .signedOut)
        }
    }

    @Test func anUnreachableServerAndBadInputAreExplained() async {
        let world = World()
        world.backend.goDown()
        let model = world.launch()

        model.serverAddress = "not a url at all://"
        await model.signIn(password: "a long password")
        #expect(model.signInProblem == "That server address does not look right.")

        model.serverAddress = "lyfe.example.ts.net"
        await model.signIn(password: "")
        #expect(model.signInProblem == "Enter your lyfe password.")
        #expect(world.backend.requests.isEmpty)

        await model.signIn(password: "a long password")
        #expect(model.signInProblem == "Can't reach the server: it was found but refused the connection; check the port in the address (-1004).")
    }

    @Test func eachWayOfNotReachingTheServerIsToldApart() async {
        let cases: [(URLError.Code, String)] = [
            (.cannotFindHost, "its name was not found; in the Tailscale app, check it is connected and using Tailscale DNS (-1003)"),
            (.timedOut, "it did not answer in time (-1001)"),
            (.notConnectedToInternet, "this device has no network connection (-1009)"),
            (.secureConnectionFailed, "the secure connection could not be set up (-1200)"),
            (.serverCertificateUntrusted, "the secure connection could not be set up (-1202)"),
            (.appTransportSecurityRequiresSecureConnection, "the address must be https (-1022)"),
            (.badServerResponse, "the connection failed (-1011)"),
        ]
        for (code, why) in cases {
            let world = World()
            world.backend.goDown(as: code)
            let model = world.launch()
            model.serverAddress = "lyfe.example.ts.net"
            await model.signIn(password: "a long password")
            #expect(model.signInProblem == "Can't reach the server: \(why).")
        }
    }

    @Test func signingOutForgetsEverythingEvenWhenOffline() async {
        let world = World.signedIn()
        world.cache.save(CachedHome(snapshot: Fixture.snapshot(), fetchedAt: world.clock))
        world.backend.goDown()
        let model = world.launch()
        #expect(model.phase == .signedIn)

        await model.signOut()

        #expect(model.phase == .signedOut)
        #expect(model.home == nil)
        #expect(world.tokens.load() == nil)
        #expect(world.cache.load() == nil)
        #expect(world.backend.requests == ["POST /v1/auth/sign-out"])
        // The address is kept so signing back in is one field.
        #expect(model.serverAddress == "lyfe.example.ts.net:8444")
    }
}

@MainActor
@Suite struct HomeRefreshTests {
    @Test func aNewSessionAppearsAfterTheBackendChecksGarmin() async {
        let world = World.signedIn()
        // Before the check the backend knows one session; the check finds another.
        world.backend.on("GET /v1/home", .ok(Fixture.home(done: 1)), .ok(Fixture.home(done: 2, sources: Fixture.sources(syncedAt: "2026-11-17T15:00:05Z"))))
        world.backend.on("POST /v1/sync", .ok(Fixture.sources(syncedAt: "2026-11-17T15:00:05Z")))
        let model = world.launch()

        await model.refresh()

        #expect(world.backend.requests == ["GET /v1/home", "POST /v1/sync", "GET /v1/home"])
        #expect(model.home?.gym.done == 2)
        #expect(model.isOffline == false)
        #expect(model.homeFetchedAt == world.clock)
        #expect(world.cache.load()?.snapshot.gym.done == 2)
    }

    @Test func nothingIsRefetchedWhenTheCheckChangedNothing() async {
        let world = World.signedIn()
        world.backend.on("GET /v1/home", .ok(Fixture.home(done: 1)))
        world.backend.on("POST /v1/sync", .ok(Fixture.sources()))
        let model = world.launch()
        await model.refresh()
        #expect(world.backend.requests == ["GET /v1/home", "POST /v1/sync"])
        #expect(model.home?.gym.done == 1)
    }

    @Test func offlineShowsTheLastSeenStateWithItsAge() async {
        let world = World.signedIn()
        let seenAt = world.clock.addingTimeInterval(-2 * 3600)
        world.cache.save(CachedHome(snapshot: Fixture.snapshot(done: 2), fetchedAt: seenAt))
        world.backend.goDown()
        let model = world.launch()

        // The cached week is on screen before any request is made.
        #expect(model.home?.gym.done == 2)
        #expect(model.homeFetchedAt == seenAt)

        await model.refresh()

        #expect(model.phase == .signedIn)
        #expect(model.isOffline)
        #expect(model.offlineReason?.hasSuffix("(-1004)") == true)
        #expect(model.home?.gym.done == 2)
        #expect(model.homeFetchedAt == seenAt)
        #expect(agoLabel(from: model.homeFetchedAt!, to: world.clock) == "2 H AGO")

        // Back in range: fresh state replaces it.
        world.backend.goDown(false)
        world.backend.on("GET /v1/home", .ok(Fixture.home(done: 1)))
        world.backend.on("POST /v1/sync", .ok(Fixture.sources()))
        await model.refresh()
        #expect(model.isOffline == false)
        #expect(model.offlineReason == nil)
        #expect(model.home?.gym.done == 1)
        #expect(model.homeFetchedAt == world.clock)
    }

    @Test func aStoppedBackendBehindTheProxyCountsAsOffline() async {
        let world = World.signedIn()
        world.backend.on("GET /v1/home", .init(status: 502, body: ""))
        let model = world.launch()
        await model.refresh()
        #expect(model.isOffline)
        #expect(model.offlineReason == "the Spark answered but lyfe is not running on it (502)")
        #expect(model.phase == .signedIn)
    }

    @Test func aRevokedTokenSignsTheDeviceOut() async {
        let world = World.signedIn()
        world.cache.save(CachedHome(snapshot: Fixture.snapshot(), fetchedAt: world.clock))
        world.backend.on("GET /v1/home", .init(status: 401, body: #"{"error": "unauthorized"}"#))
        let model = world.launch()

        await model.refresh()

        #expect(model.phase == .signedOut)
        #expect(model.home == nil)
        #expect(world.tokens.load() == nil)
        #expect(world.cache.load() == nil)
    }

    @Test func aFailingGarminCheckStillShowsTheWeek() async {
        let world = World.signedIn()
        let failing = Fixture.sources(state: "failing", message: "Garmin rejected the API key; it may have expired or been deleted")
        world.backend.on("GET /v1/home", .ok(Fixture.home(done: 1)), .ok(Fixture.home(done: 1, sources: failing)))
        world.backend.on("POST /v1/sync", .ok(failing))
        let model = world.launch()
        await model.refresh()
        #expect(model.home?.gym.done == 1)
        #expect(model.home?.sources.garmin.state == .failing)
        #expect(model.home?.sources.garmin.message?.contains("rejected the API key") == true)
        #expect(model.isOffline == false)
    }

    @Test func aSessionWorksEvenIfTheTokenCouldNotBeSaved() async {
        // As when the Keychain refuses the write: the token must still
        // carry this run.
        final class BrokenTokenStore: TokenStore {
            func load() -> String? { nil }
            func save(_ token: String) {}
            func clear() {}
        }
        let backend = StubBackend()
        backend.on("POST /v1/auth/sign-in", .ok(#"{"token": "fresh-token"}"#))
        backend.on("GET /v1/home", .ok(Fixture.home(done: 1)))
        backend.on("POST /v1/sync", .ok(Fixture.sources()))
        let model = AppModel(
            tokens: BrokenTokenStore(), addresses: MemoryServerAddressStore(),
            cache: HomeCache(directory: Fixture.temporaryDirectory()), transport: backend,
            deviceName: "Test iPhone")
        model.serverAddress = "lyfe.example.ts.net"
        await model.signIn(password: "a long password")
        #expect(model.phase == .signedIn)
        #expect(model.home?.gym.done == 1)
        #expect(backend.lastRequest("GET /v1/home")?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token")
    }

    @Test func aServerErrorIsSaidOutLoudAndClearsOnSuccess() async {
        let world = World.signedIn()
        world.backend.on("GET /v1/home", .init(status: 500, body: #"{"error": "internal"}"#), .ok("not json"), .ok(Fixture.home(done: 1)))
        world.backend.on("POST /v1/sync", .ok(Fixture.sources()))
        let model = world.launch()
        await model.refresh()
        #expect(model.refreshProblem == "The server answered with an error (500).")
        #expect(model.isOffline == false)
        await model.refresh()
        #expect(model.refreshProblem == "The server's answer could not be read. The app may be older than the server.")
        await model.refresh()
        #expect(model.refreshProblem == nil)
        #expect(model.home?.gym.done == 1)
    }

    @Test func aSavedTokenWithoutAnAddressIsNotASession() {
        let world = World(token: "device-token", address: nil)
        #expect(world.launch().phase == .signedOut)
    }
}
