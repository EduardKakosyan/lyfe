import Foundation
import Testing

@testable import LyfeKit

@MainActor
@Suite struct LockTests {
    @Test func lyfeOpensLockedAndFaceIDOpensIt() async {
        let world = World.signedIn()
        let face = StubOwnerCheck()
        let model = world.launch(ownerCheck: face)
        #expect(model.isLocked)

        await model.unlock()
        #expect(!model.isLocked)
        #expect(face.asked == 1)
        // Already open: nothing more is asked.
        await model.unlock()
        #expect(face.asked == 1)
    }

    @Test func aFaceThatIsNotTheOwnersLeavesItLocked() async {
        let world = World.signedIn()
        let face = StubOwnerCheck(passes: false)
        let model = world.launch(ownerCheck: face)
        await model.unlock()
        #expect(model.isLocked)

        // Asked again from the bar, and this time it is the owner.
        face.passes = true
        await model.unlock()
        #expect(!model.isLocked)
        #expect(face.asked == 2)
    }

    @Test func leavingTheScreenLocksItAgain() async {
        let world = World.signedIn()
        let face = StubOwnerCheck()
        let model = world.launch(ownerCheck: face)
        await model.unlock()

        model.lock()
        #expect(model.isLocked)
        await model.unlock()
        #expect(!model.isLocked)
        #expect(face.asked == 2)
    }

    @Test func signedOutThePasswordIsTheLock() async {
        let world = World()
        world.backend.on("POST /v1/auth/sign-in", .ok(#"{"token": "fresh-token"}"#))
        world.backend.on("GET /v1/home", .ok(Fixture.home(done: 1)))
        world.backend.on("POST /v1/sync", .ok(Fixture.sources()))
        world.backend.on("POST /v1/auth/sign-out", .init(status: 204, body: ""))
        let face = StubOwnerCheck()
        let model = world.launch(ownerCheck: face)
        #expect(!model.isLocked)
        model.lock()
        #expect(!model.isLocked)

        // Having just typed the password, the owner is not asked for a face too.
        model.serverAddress = "lyfe.example.ts.net:8444"
        await model.signIn(password: "a long password")
        #expect(model.phase == .signedIn)
        #expect(!model.isLocked)
        #expect(face.asked == 0)

        // From then on, leaving locks it, and signing out lifts the lock
        // so the sign-in screen can be reached.
        model.lock()
        #expect(model.isLocked)
        await model.signOut()
        #expect(!model.isLocked)
    }

    @Test func aDeviceThatCannotCheckIsNeverLocked() async {
        let world = World.signedIn()
        let model = world.launch(ownerCheck: StubOwnerCheck(available: false))
        #expect(!model.isLocked)
        model.lock()
        #expect(!model.isLocked)
    }

    @Test func aRunningBreathSessionIsNotLockedAway() async throws {
        let world = World.signedIn()
        world.backend.on("GET /v1/home", .ok(Fixture.home(breath: Fixture.breath())))
        world.backend.on("POST /v1/sync", .ok(Fixture.sources()))
        let model = world.launch(ownerCheck: StubOwnerCheck())
        await model.unlock()
        await model.refresh()

        // The table is only open: leaving still locks.
        model.openBreathSession()
        model.lock()
        #expect(model.isLocked)
        await model.unlock()

        // Running: the phone can be locked and woken, and the next tap
        // lands without waiting for a face.
        let session = try #require(model.breathSession)
        session.start()
        model.lock()
        #expect(!model.isLocked)

        // The same after the app was closed mid-session and opened again.
        let relaunched = world.launch(ownerCheck: StubOwnerCheck())
        #expect(relaunched.breathSession?.isRunning == true)
        #expect(!relaunched.isLocked)

        session.stop()
        model.closeBreathSession()
        model.lock()
        #expect(model.isLocked)
    }

    @Test func aWeightTypedIntoThePromptDoesNotNeedTheLockOpened() async {
        let world = World.signedIn()
        world.backend.on(
            "POST /v1/weigh-ins", .ok(Fixture.home(weight: Fixture.weight([("2026-11-18", 181.4)], unit: "lb"))))
        let face = StubOwnerCheck()
        // Launched behind the lock screen by a reply to the prompt.
        let model = world.launch(ownerCheck: face)
        #expect(model.isLocked)

        #expect(await model.recordWeight("181.4") == .sent)
        #expect(model.isLocked)
        #expect(face.asked == 0)
    }
}
