import Foundation
import Testing

@testable import LyfeKit

@Suite struct StreakModelTests {
    @Test func decodesTheStreakTheBackendSends() throws {
        let json = Fixture.home(
            done: 1, streak: Fixture.streak(weeks: 5, state: "recovering", previousBest: 9, recent: "KKKRKA"),
            serverReady: false)
        let home = try JSONDecoder.lyfe.decode(HomeSnapshot.self, from: Data(json.utf8))
        let streak = try #require(home.gym.streak)
        #expect(streak.weeks == 5)
        #expect(streak.state == .recovering)
        #expect(streak.previousBest == 9)
        #expect(streak.remaining == 3)
        #expect(streak.openDays == 6)
        #expect(streak.reachable)
        #expect(streak.recent.map(\.mark) == [.kept, .kept, .kept, .recovered, .kept, .awaitingRecovery])
        #expect(streak.recent.last?.isoWeek == 46)
        #expect(streak.recent.last?.startsOn.description == "2026-11-09")
        #expect(streak.recent.last?.done == 2)
        #expect(home.notifications?.serverReady == false)
    }

    @Test func decodesEveryState() throws {
        for (text, state) in [
            ("not_started", HomeSnapshot.GymStreak.State.notStarted), ("on_track", .onTrack),
            ("recovering", .recovering), ("kept", .kept),
        ] {
            let home = Fixture.snapshot(streak: Fixture.streak(state: text))
            #expect(home.gym.streak?.state == state)
        }
    }

    @Test func anAnswerFromBeforeStreaksStillDecodes() throws {
        // What an older server sent, and what an older app left in its cache.
        let home = try JSONDecoder.lyfe.decode(HomeSnapshot.self, from: Data(Fixture.home(done: 2).utf8))
        #expect(home.gym.streak == nil)
        #expect(home.notifications == nil)
        #expect(HomeText.gymLines(for: home).headline == "SESSIONS THIS WEEK")
        #expect(HomeText.gymSpoken(for: home) == "Gym: 2 of 4 sessions this week")
    }

    @Test func aStreakSurvivesTheCache() {
        let cache = HomeCache(directory: Fixture.temporaryDirectory())
        let cached = CachedHome(
            snapshot: Fixture.snapshot(streak: Fixture.streak(recent: "KRKMMKA")),
            fetchedAt: Date(timeIntervalSince1970: 1_795_014_000))
        cache.save(cached)
        #expect(cache.load() == cached)
    }
}

@Suite struct StreakTextTests {
    private func lines(_ home: HomeSnapshot) -> String {
        let lines = HomeText.gymLines(for: home)
        return [lines.headline, lines.detail].compactMap { $0 }.joined(separator: " / ")
    }

    private func bar(_ home: HomeSnapshot) -> String {
        let next = HomeText.nextAction(for: home)
        return "\(next.small) / \(next.big)"
    }

    @Test func onTrackSaysWhatTheWeekStillNeeds() {
        let home = Fixture.snapshot(done: 1, streak: Fixture.streak(weeks: 6, state: "on_track", remaining: 3, openDays: 6))
        #expect(lines(home) == "WEEKS IN A ROW / 3 MORE BY SUNDAY")
        #expect(bar(home) == "NEXT · 3 MORE BY SUNDAY / GYM SESSION")
        #expect(HomeText.gymSpoken(for: home) == "Gym: 6 weeks in a row. 1 of 4 sessions this week.")
    }

    @Test func oneWeekIsNotPlural() {
        let home = Fixture.snapshot(done: 1, streak: Fixture.streak(weeks: 1, recent: "K"))
        #expect(lines(home) == "WEEK IN A ROW / 3 MORE BY SUNDAY")
        #expect(HomeText.gymSpoken(for: home) == "Gym: 1 week in a row. 1 of 4 sessions this week.")
    }

    @Test func aKeptWeekSaysSo() {
        var home = Fixture.snapshot(done: 2, streak: Fixture.streak(weeks: 7, state: "kept", remaining: 0, openDays: 3))
        home.gym.done = 4
        home.gym.remaining = 0
        #expect(lines(home) == "WEEKS IN A ROW / THIS WEEK DONE")
        #expect(bar(home) == "7 WEEKS IN A ROW · 4 SESSIONS / GYM WEEK DONE")
    }

    @Test func recoveryNamesItselfAndKeepsTheCount() {
        let home = Fixture.snapshot(
            done: 1, streak: Fixture.streak(weeks: 5, state: "recovering", remaining: 3, openDays: 6, recent: "KKKKKA"))
        #expect(lines(home) == "RECOVERING / 3 MORE BY SUNDAY")
        #expect(bar(home) == "RECOVERY · 3 MORE BY SUNDAY / GYM SESSION")
        #expect(HomeText.gymSpoken(for: home) == "Gym: 5 weeks in a row, recovering. 1 of 4 sessions this week.")
    }

    @Test func noStreakSaysHowToStartOne() {
        let home = Fixture.snapshot(
            done: 1, streak: Fixture.streak(weeks: 0, state: "not_started", remaining: 3, openDays: 5, recent: ""))
        #expect(lines(home) == "NO STREAK YET / 3 MORE BY SUNDAY STARTS ONE")
        #expect(bar(home) == "NEXT · 3 MORE BY SUNDAY / GYM SESSION")
        #expect(HomeText.gymSpoken(for: home) == "Gym: no streak yet. 1 of 4 sessions this week.")

        // After a streak has ended, "yet" no longer fits.
        let again = Fixture.snapshot(
            done: 1,
            streak: Fixture.streak(weeks: 0, state: "not_started", previousBest: 4, remaining: 3, openDays: 5, recent: "KKKKMM"))
        #expect(lines(again) == "STARTING AGAIN / 3 MORE BY SUNDAY STARTS ONE")
    }

    @Test func theDayEverythingLeftIsNeededIsMarked() {
        // Friday, one session so far: Friday, Saturday and Sunday all needed.
        let home = Fixture.snapshot(
            done: 1, streak: Fixture.streak(weeks: 6, remaining: 3, openDays: 3), today: "2026-11-20")
        #expect(bar(home) == "NEEDED TODAY · 3 MORE BY SUNDAY / GYM SESSION")
    }

    @Test func onSundayTheDeadlineIsToday() {
        let home = Fixture.snapshot(
            done: 3, streak: Fixture.streak(weeks: 6, remaining: 1, openDays: 1), today: "2026-11-22")
        #expect(lines(home) == "WEEKS IN A ROW / 1 MORE TODAY")
        #expect(bar(home) == "NEEDED TODAY · 1 MORE TODAY / GYM SESSION")
    }

    @Test func aWeekOutOfReachSaysWhatHappensNext() {
        let slipping = Fixture.snapshot(
            done: 1, streak: Fixture.streak(weeks: 6, state: "on_track", remaining: 3, openDays: 2), today: "2026-11-21")
        #expect(lines(slipping) == "WEEKS IN A ROW / THIS WEEK IS OUT OF REACH")
        #expect(bar(slipping) == "THIS WEEK IS OUT OF REACH / NEXT WEEK RECOVERS IT")

        let ending = Fixture.snapshot(
            done: 1, streak: Fixture.streak(weeks: 6, state: "recovering", remaining: 3, openDays: 2, recent: "KKKKKA"),
            today: "2026-11-21")
        #expect(lines(ending) == "RECOVERING / THE STREAK ENDS SUNDAY")
        #expect(bar(ending) == "THE STREAK ENDS SUNDAY / START AGAIN MONDAY")

        let none = Fixture.snapshot(
            done: 1, streak: Fixture.streak(weeks: 0, state: "not_started", remaining: 3, openDays: 2, recent: ""),
            today: "2026-11-21")
        #expect(lines(none) == "NO STREAK YET / NEXT WEEK CAN START ONE")
        #expect(bar(none) == "THIS WEEK IS OUT OF REACH / START AGAIN MONDAY")
    }

    @Test func trainingTodayIsEnoughForToday() {
        // Tuesday, sessions on Monday and today.
        let home = Fixture.snapshot(done: 2, streak: Fixture.streak(weeks: 6, remaining: 2, openDays: 5))
        #expect(bar(home) == "2 MORE BY SUNDAY / DONE FOR TODAY")
    }

    @Test func pastWeeksAreMarkedSolidStripedOrOutline() {
        #expect(HomeText.mark(for: .kept) == .solid)
        #expect(HomeText.mark(for: .recovered) == .striped)
        #expect(HomeText.mark(for: .awaitingRecovery) == .striped)
        #expect(HomeText.mark(for: .missed) == .outline)
        let streak = Fixture.snapshot(streak: Fixture.streak(previousBest: 9, recent: "KKMMKRKA")).gym.streak!
        #expect(
            HomeText.weeksSpoken(for: streak)
                == "Last 8 weeks: 4 kept, 2 recovered, 2 missed. Previous best 9 weeks")
    }
}

@MainActor
@Suite struct PushTokenTests {
    private func signedInWorld() -> World {
        let world = World.signedIn()
        world.backend.on("GET /v1/home", .ok(Fixture.home(serverReady: true)))
        world.backend.on("POST /v1/sync", .ok(Fixture.sources()))
        world.backend.on("POST /v1/push-token", StubBackend.Reply(status: 204, body: ""))
        return world
    }

    private func sentTokens(_ world: World) -> [String] {
        world.backend.bodies("POST /v1/push-token").compactMap { body in
            (try? JSONSerialization.jsonObject(with: body) as? [String: String])?["apns_token"]
        }
    }

    @Test func theDeviceTokenIsSentOnceWhenSignedIn() async {
        let world = signedInWorld()
        let model = world.launch()
        await model.setPushToken("aabbcc")
        #expect(sentTokens(world) == ["aabbcc"])
        #expect(world.backend.lastRequest("POST /v1/push-token")?.value(forHTTPHeaderField: "Authorization") == "Bearer device-token")
        // Apple hands over the same token on every launch; it is not re-sent.
        await model.setPushToken("aabbcc")
        await model.refresh()
        #expect(sentTokens(world) == ["aabbcc"])
        // A changed token is.
        await model.setPushToken("ddeeff")
        #expect(sentTokens(world) == ["aabbcc", "ddeeff"])
    }

    @Test func aTokenThatArrivesBeforeSignInIsSentAfterIt() async {
        let world = World()
        world.backend.on("POST /v1/auth/sign-in", .ok(#"{"token": "fresh-token"}"#))
        world.backend.on("GET /v1/home", .ok(Fixture.home()))
        world.backend.on("POST /v1/sync", .ok(Fixture.sources()))
        world.backend.on("POST /v1/push-token", StubBackend.Reply(status: 204, body: ""))
        let model = world.launch()
        model.serverAddress = "lyfe.example.ts.net:8444"
        await model.setPushToken("aabbcc")
        #expect(sentTokens(world).isEmpty)
        await model.signIn(password: "a long password")
        #expect(sentTokens(world) == ["aabbcc"])

        // A new session after signing out gets the token again.
        await model.signOut()
        await model.signIn(password: "a long password")
        #expect(sentTokens(world) == ["aabbcc", "aabbcc"])
    }

    @Test func aTokenThatCouldNotBeSentGoesWithTheNextRefresh() async {
        let world = signedInWorld()
        let model = world.launch()
        world.backend.goDown()
        await model.setPushToken("aabbcc")
        world.backend.goDown(false)
        #expect(sentTokens(world).count == 1)  // the attempt that failed
        await model.refresh()
        #expect(sentTokens(world).count == 2)
        await model.refresh()
        #expect(sentTokens(world).count == 2)
    }

    @Test func theOwnerIsToldWhyPromptsWillNotArrive() async {
        let world = signedInWorld()
        let model = world.launch()
        await model.refresh()
        #expect(model.notificationsProblem == nil)

        model.notificationsAllowed = false
        #expect(model.notificationsProblem == "Prompts are off. Allow notifications for lyfe in Settings.")
        model.notificationsAllowed = true
        #expect(model.notificationsProblem == nil)

        world.backend.on("GET /v1/home", .ok(Fixture.home(serverReady: false)))
        await model.refresh()
        #expect(model.notificationsProblem == "Prompts are off. The server has no Apple key yet.")
    }
}
