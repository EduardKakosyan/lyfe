import Foundation
import Testing

@testable import LyfeKit

@Suite struct HomeSnapshotTests {
    @Test func decodesTheBackendsAnswer() throws {
        let home = try JSONDecoder.lyfe.decode(HomeSnapshot.self, from: Data(Fixture.home(done: 2).utf8))
        #expect(home.today == CalendarDay(year: 2026, month: 11, day: 17))
        #expect(home.week.isoWeek == 47)
        #expect(home.week.startsOn.description == "2026-11-16")
        #expect(home.gym.target == 4)
        #expect(home.gym.done == 2)
        #expect(home.gym.remaining == 2)
        #expect(home.gym.daysLeft == 6)
        #expect(home.gym.sessions.map(\.activityId) == [501, 502])
        #expect(home.gym.sessions[0].durationMin == 58)
        #expect(home.gym.sessions[1].name == nil)
        #expect(home.sources.garmin.state == .ok)
        #expect(home.sources.garmin.lastSuccessAt == ISO8601DateFormatter().date(from: "2026-11-17T14:58:00Z"))
        #expect(home.generatedAt == ISO8601DateFormatter().date(from: "2026-11-17T15:00:00Z"))
        #expect(home.generatedAt.timeIntervalSince(home.sources.garmin.lastSuccessAt!) == 120)
    }

    @Test func decodesEverySourceState() throws {
        for (text, state) in [
            ("ok", SourceStatus.State.ok), ("failing", .failing), ("never_synced", .neverSynced),
            ("not_configured", .notConfigured),
        ] {
            let json = Fixture.sources(state: text, syncedAt: nil, message: text == "failing" ? "Garmin answered with HTTP 503" : nil)
            let sources = try JSONDecoder.lyfe.decode(Sources.self, from: Data(json.utf8))
            #expect(sources.garmin.state == state)
            #expect(sources.garmin.lastSuccessAt == nil)
        }
    }

    @Test func survivesItsOwnCache() throws {
        let cache = HomeCache(directory: Fixture.temporaryDirectory())
        #expect(cache.load() == nil)
        let cached = CachedHome(snapshot: Fixture.snapshot(done: 2), fetchedAt: Date(timeIntervalSince1970: 1_795_014_000))
        cache.save(cached)
        #expect(cache.load() == cached)
        cache.clear()
        #expect(cache.load() == nil)
    }
}

@Suite struct CalendarDayTests {
    @Test func parsesAndPrints() {
        #expect(CalendarDay("2026-11-17")?.description == "2026-11-17")
        #expect(CalendarDay("2026-1-7")?.description == "2026-01-07")
        #expect(CalendarDay("2026-13-01") == nil)
        #expect(CalendarDay("tuesday") == nil)
        #expect(CalendarDay("") == nil)
    }

    @Test func labelsDoNotDependOnTheTimeZone() {
        #expect(CalendarDay("2026-11-17")?.posterLabel == "TUE 17 NOV")
        #expect(CalendarDay("2026-11-16")?.weekdayLabel == "MON")
        #expect(CalendarDay("2026-11-22")?.weekdayLabel == "SUN")
        #expect(CalendarDay("2027-01-01")?.posterLabel == "FRI 1 JAN")
    }

    @Test func ordersByDate() {
        #expect(CalendarDay("2026-11-17")! < CalendarDay("2026-12-01")!)
        #expect(CalendarDay("2026-12-31")! < CalendarDay("2027-01-01")!)
    }
}

@Suite struct ServerAddressTests {
    @Test func bareHostsGetHTTPS() {
        #expect(serverURL(from: "dgx.example.ts.net:8444")?.absoluteString == "https://dgx.example.ts.net:8444")
        #expect(serverURL(from: "  dgx.example.ts.net  ")?.absoluteString == "https://dgx.example.ts.net")
    }

    @Test func explicitSchemesAreKept() {
        #expect(serverURL(from: "http://localhost:8787/")?.absoluteString == "http://localhost:8787")
        #expect(serverURL(from: "https://dgx.example.ts.net:8444//")?.absoluteString == "https://dgx.example.ts.net:8444")
    }

    @Test func nonsenseIsRejected() {
        #expect(serverURL(from: "") == nil)
        #expect(serverURL(from: "   ") == nil)
        #expect(serverURL(from: "ftp://dgx.example.ts.net") == nil)
        #expect(serverURL(from: "https://") == nil)
        #expect(serverURL(from: "https://host/?x=1") == nil)
    }
}

@Suite struct PosterTextTests {
    @Test func agoLabels() {
        let now = Date(timeIntervalSince1970: 1_795_014_000)
        #expect(agoLabel(from: now.addingTimeInterval(-5), to: now) == "JUST NOW")
        #expect(agoLabel(from: now.addingTimeInterval(-125), to: now) == "2 MIN AGO")
        #expect(agoLabel(from: now.addingTimeInterval(-3 * 3600 - 60), to: now) == "3 H AGO")
        #expect(agoLabel(from: now.addingTimeInterval(-2 * 86_400), to: now) == "2 D AGO")
        #expect(agoLabel(from: now.addingTimeInterval(60), to: now) == "JUST NOW")
    }

    @Test func theBlackBarNamesTheNextThing() {
        var home = Fixture.snapshot(done: 1)
        // One session, on Monday; today is Tuesday.
        #expect(HomeText.nextAction(for: home).small == "NEXT · 3 MORE BY SUNDAY")
        #expect(HomeText.nextAction(for: home).big == "GYM SESSION")

        home = Fixture.snapshot(done: 2)  // second session is today
        #expect(HomeText.nextAction(for: home).small == "2 MORE BY SUNDAY")
        #expect(HomeText.nextAction(for: home).big == "DONE FOR TODAY")

        home.gym.done = 4
        home.gym.remaining = 0
        #expect(HomeText.nextAction(for: home).big == "GYM WEEK DONE")
    }

    @Test func activityTypesReadAsWords() {
        #expect(HomeText.typeLabel("strength_training") == "STRENGTH TRAINING")
    }
}
