import Foundation
import Observation

/// The app's state and the only place that talks to the backend. It holds
/// no rules of its own: it signs in, fetches what the backend decided, and
/// keeps the last answer for when the backend cannot be reached.
@MainActor
@Observable
public final class AppModel {
    public enum Phase: Equatable, Sendable {
        case signedOut
        case signedIn
    }

    public private(set) var phase: Phase
    /// The latest Home state, fresh or cached.
    public private(set) var home: HomeSnapshot?
    /// When `home` was fetched from the backend.
    public private(set) var homeFetchedAt: Date?
    /// True when the last attempt could not reach the backend, so `home`
    /// is the last seen state rather than the current one.
    public private(set) var isOffline = false
    /// Why the last attempt could not reach the backend.
    public private(set) var offlineReason: String?
    public private(set) var isRefreshing = false
    public private(set) var isSigningIn = false
    /// Shown on the sign-in screen after a failed attempt.
    public private(set) var signInProblem: String?
    /// Set when the backend answered a refresh with something other than
    /// the week (a server error, an answer that could not be read).
    public private(set) var refreshProblem: String?
    public var serverAddress: String
    /// Whether the owner lets lyfe show notifications on this device; nil
    /// until they have been asked. Set by the app, which owns the prompt.
    public var notificationsAllowed: Bool?

    /// The breath session on screen, from opening its table to DONE.
    public private(set) var breathSession: BreathSessionModel?
    /// Finished breath sessions kept on this phone that the backend has
    /// not confirmed yet, oldest first.
    public private(set) var unsentBreath: [UUID]
    /// Set when the backend answered but would not take a saved session.
    public private(set) var breathProblem: String?

    /// The study session on this phone, from START until the owner says
    /// what it was. It keeps running while its screen is closed.
    public private(set) var studyRun: StudyRun?
    /// True while the study screen is on top: picking a subject, the timer,
    /// or saying what a session was.
    public private(set) var isStudyOpen = false
    /// Finished study sessions kept on this phone that the backend has not
    /// confirmed yet, oldest first.
    public private(set) var unsentStudy: [UUID]
    /// Set when the backend answered but would not take a saved session.
    public private(set) var studyProblem: String?

    /// Weights typed on this phone that the backend has not confirmed yet,
    /// oldest first.
    public private(set) var unsentWeighIns: [UUID]
    /// Set when the backend would not take a weight that was typed.
    public private(set) var weighInProblem: String?

    /// Meals tapped on this phone that the backend has not confirmed yet,
    /// oldest first.
    public private(set) var unsentFood: [MealTap]
    /// Set when the backend would not take a meal that was tapped.
    public private(set) var foodProblem: String?
    /// The meal being built or the saved meal being changed, while the
    /// builder is on screen.
    public private(set) var mealDraft: MealDraft?
    /// A meal being built that was left with parts in it, kept to carry on
    /// with. It outlasts closing lyfe.
    public private(set) var parkedMeal: MealDraft?
    /// True when the builder was opened to type a food, so it opens with
    /// its typing form out.
    public private(set) var builderStartsTyping = false
    /// True while the targets entry is on screen.
    public private(set) var isEnteringTargets = false
    /// Photo and barcode meals logged on this phone that the backend has
    /// not confirmed yet, oldest first.
    public private(set) var unsentCaptures: [FoodCapture]
    /// The photo or barcode screen over Food, while one is open.
    public private(set) var foodFlow: FoodFlow?

    /// The screens a part is added on and a logged meal is looked into.
    public enum FoodFlow: Equatable, Sendable {
        /// A photo and a line as a part: of the meal being built, or with
        /// `into` of a meal already logged.
        case photo(into: UUID?)
        /// A photo's estimate, to check and correct.
        case estimate(UUID)
        /// Scanning a barcode and saying how much was eaten: for the meal
        /// being built, or with `into` for a meal already logged.
        case scan(into: UUID?)
        /// Typing the label of a code lyfe does not know, for a meal
        /// already logged with it or about to be.
        case label(code: String)
        /// A meal logged from parts: to correct them, add to them, take
        /// one out, or save the meal for one tap.
        case meal(UUID)
    }

    /// The screens other than Home, for a signed-in owner.
    public enum Screen: Equatable, Sendable {
        case home
        case progress
        case food
        case money
        case goals
    }

    /// The goal open on the Goals screen.
    public private(set) var openGoalId: UUID?
    /// The goal being set or changed, while its editor is on screen.
    public private(set) var goalEditor: GoalEditing?

    public enum GoalEditing: Equatable, Sendable {
        /// With the id the new goal will have, made once when the editor
        /// opens, so a goal sent again after a lost answer is set once.
        case new(UUID)
        case change(UUID)

        public var id: UUID {
            switch self {
            case .new(let id), .change(let id): id
            }
        }
    }

    /// True while lyfe is waiting for Face ID. Set when it is opened and
    /// each time it leaves the screen; everything it shows is behind it.
    /// A weight typed into the morning prompt does not need it.
    public private(set) var isLocked = false
    private var isUnlocking = false

    public private(set) var screen: Screen = .home

    /// The month of money on screen, as the backend last answered. Kept
    /// only while lyfe runs: money is not stored on the phone.
    public private(set) var money: MoneyMonth?
    /// What went wrong fetching or changing it, in words for the owner.
    public private(set) var moneyProblem: String?
    public private(set) var isLoadingMoney = false
    /// Which of Money's three sections is on screen.
    public private(set) var moneySection: MoneySection = .month
    /// What everything comes to, as the backend last answered. Like the
    /// month, kept only while lyfe runs.
    public private(set) var worth: MoneyWorth?
    /// How far off financial independence is, likewise.
    public private(set) var fire: MoneyFire?
    private var isLoadingWorth = false
    private var isLoadingFire = false
    /// Set when one of them is asked for while it is already being
    /// fetched: something has changed since that fetch left, so it is
    /// fetched again once it is back.
    private var worthAskedAgain = false
    private var fireAskedAgain = false
    /// Counts up each time what `fire` should hold is changed from here,
    /// so an answer asked for before that is not shown over it.
    private var fireChanges = 0
    /// True while what FIRE assumes is open to change.
    public private(set) var isEditingPlan = false
    /// The entry whose sorting screen is open.
    public private(set) var sortingEntry: UUID?
    /// True while the weight entry is on screen.
    public private(set) var isEnteringWeight = false

    /// Where Apple delivers notifications for this install, once known.
    private var apnsToken: String?
    /// The token the backend has for the current session.
    private var apnsTokenSent: String?
    /// The device token for this run. The store only carries it between
    /// launches, so a failed save costs a sign-in next time, not this session.
    private var token: String?
    private let tokens: any TokenStore
    private let addresses: any ServerAddressStore
    private let cache: HomeCache
    private let breath: BreathStore
    private let study: StudyStore
    private var isSendingStudy = false
    private let weighIns: WeighInStore
    private var isSendingWeighIns = false
    private let food: FoodStore
    private let captures: CaptureStore
    private let drafts: DraftStore
    private(set) var recentPortions: [[Ingredient]] = []
    struct MealReceipt: Identifiable {
        let id: UUID
        let day: CalendarDay?
        let name: String
    }
    private(set) var receipt: MealReceipt?

    func dismissReceipt(_ id: UUID) {
        if receipt?.id == id { receipt = nil }
    }
    private let illustrations: IllustrationStore
    private let foodIcons: FoodIconStore
    private var isSendingFood = false
    private let ownerCheck: any OwnerCheck
    private let makeCues: @MainActor () -> any BreathCues
    private var isSendingBreath = false
    private let transport: any HTTPTransport
    private let deviceName: String
    private let now: @Sendable () -> Date

    public init(
        tokens: any TokenStore,
        addresses: any ServerAddressStore,
        cache: HomeCache,
        breath: BreathStore,
        study: StudyStore? = nil,
        weighIns: WeighInStore,
        food: FoodStore,
        captures: CaptureStore? = nil,
        drafts: DraftStore? = nil,
        illustrations: IllustrationStore? = nil,
        foodIcons: FoodIconStore? = nil,
        transport: any HTTPTransport,
        deviceName: String,
        defaultServerAddress: String = "",
        ownerCheck: any OwnerCheck = NoOwnerCheck(),
        cues: @escaping @MainActor () -> any BreathCues = { SilentCues() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tokens = tokens
        self.addresses = addresses
        self.cache = cache
        self.breath = breath
        self.study =
            study
            ?? StudyStore(directory: FileManager.default.temporaryDirectory.appending(path: "lyfe-\(UUID().uuidString)"))
        self.weighIns = weighIns
        self.food = food
        // Tests that do not care keep them in a folder of their own.
        self.captures =
            captures
            ?? CaptureStore(directory: FileManager.default.temporaryDirectory.appending(path: "lyfe-\(UUID().uuidString)"))
        self.drafts =
            drafts
            ?? DraftStore(directory: FileManager.default.temporaryDirectory.appending(path: "lyfe-\(UUID().uuidString)"))
        self.illustrations =
            illustrations
            ?? IllustrationStore(
                directory: FileManager.default.temporaryDirectory.appending(path: "lyfe-\(UUID().uuidString)"))
        self.foodIcons =
            foodIcons
            ?? FoodIconStore(directory: FileManager.default.temporaryDirectory.appending(path: "lyfe-\(UUID().uuidString)"))
        self.ownerCheck = ownerCheck
        makeCues = cues
        self.transport = transport
        self.deviceName = deviceName
        self.now = now
        // The address this build was made for, until one has been saved.
        let saved = addresses.load() ?? ""
        let address = saved.isEmpty ? defaultServerAddress : saved
        let cached = cache.load()
        let savedToken = tokens.load()
        let hasSession = savedToken != nil && serverURL(from: address) != nil
        token = hasSession ? savedToken : nil
        serverAddress = address
        phase = hasSession ? .signedIn : .signedOut
        home = hasSession ? cached?.snapshot : nil
        homeFetchedAt = hasSession ? cached?.fetchedAt : nil
        unsentBreath = breath.outbox().map(\.id)
        unsentStudy = self.study.outbox().map(\.id)
        unsentWeighIns = weighIns.outbox().map(\.id)
        unsentFood = food.outbox()
        recentPortions = hasSession ? self.drafts.recentPortions() : []
        if let kept = self.drafts.load() {
            if !kept.parts.isEmpty, now().timeIntervalSince(kept.startedAt) < Self.draftKeptFor {
                parkedMeal = kept
            } else {
                // Too old to be the meal in front of anyone: it goes, and
                // the photos waiting to be sent for it with it.
                self.drafts.save(nil)
                for capture in self.captures.outbox() where capture.partOf == kept.id {
                    self.captures.remove(capture.id, forget: true)
                }
            }
        }
        unsentCaptures = self.captures.outbox()
        self.captures.prunePhotos(olderThan: 3 * 86_400, now: now())
        pickUpBreathSession()
        pickUpStudy()
        lock()
    }

    /// How long a meal left half built is kept to carry on with.
    static let draftKeptFor: TimeInterval = 3 * 86_400

    /// The app wired to the real Keychain, disk and network.
    public static func live(
        deviceName: String, defaultServerAddress: String = "", ownerCheck: any OwnerCheck = DeviceOwnerCheck()
    ) -> AppModel {
        AppModel(
            tokens: KeychainTokenStore(),
            addresses: DefaultsServerAddressStore(),
            cache: .standard(),
            breath: .standard(),
            study: .standard(),
            weighIns: .standard(),
            food: .standard(),
            captures: .standard(),
            drafts: .standard(),
            illustrations: .standard(),
            foodIcons: .standard(),
            transport: TailnetTransport.live(),
            deviceName: deviceName,
            defaultServerAddress: defaultServerAddress,
            ownerCheck: ownerCheck,
            cues: { ToneCues() }
        )
    }

    private var api: LyfeAPI? {
        serverURL(from: serverAddress).map { LyfeAPI(baseURL: $0, transport: transport) }
    }

    // MARK: Sign-in

    public func signIn(password: String) async {
        guard !isSigningIn else { return }
        guard let api else {
            signInProblem = "That server address does not look right."
            return
        }
        guard !password.isEmpty else {
            signInProblem = "Enter your lyfe password."
            return
        }
        isSigningIn = true
        signInProblem = nil
        defer { isSigningIn = false }
        do {
            let token = try await api.signIn(password: password, deviceName: deviceName)
            self.token = token
            tokens.save(token)
            addresses.save(serverAddress)
            phase = .signedIn
            await sendPushToken()
            await refresh()
        } catch let error as LyfeAPIError {
            signInProblem = Self.signInMessage(for: error)
        } catch {
            signInProblem = nil
        }
    }

    static func signInMessage(for error: LyfeAPIError) -> String {
        switch error {
        case .wrongPassword, .unauthorized:
            "Wrong password."
        case .tooManyAttempts(let seconds):
            "Too many attempts. Try again in \(Self.waitLabel(seconds))."
        case .noPasswordSet:
            "The server has no password yet. Run lyfe-server set-password on it."
        case .unreachable(let why):
            "Can't reach the server: \(why)."
        case .server(let status):
            "The server answered with an error (\(status))."
        case .unreadableResponse:
            "The server's answer could not be read. Is this a lyfe server?"
        }
    }

    static func waitLabel(_ seconds: Int) -> String {
        seconds < 90 ? "\(max(seconds, 1)) s" : "\(Int((Double(seconds) / 60).rounded(.up))) min"
    }

    public func signOut() async {
        if let api, let token {
            // Best effort: the token is forgotten here even if the backend
            // cannot be told right now.
            try? await api.signOut(token: token)
        }
        forgetSession()
    }

    // MARK: The lock

    /// Puts lyfe behind Face ID. Called when it starts and whenever it
    /// leaves the screen. Not while signed out, where the password is the
    /// lock; not on a device that cannot check; and not while a breath
    /// session is running, whose next tap must not wait for a face.
    public func lock() {
        guard phase == .signedIn, ownerCheck.isAvailable, breathSession?.isRunning != true else { return }
        isLocked = true
    }

    /// Asks for Face ID and opens lyfe if it is the owner.
    public func unlock() async {
        guard isLocked, !isUnlocking else { return }
        isUnlocking = true
        defer { isUnlocking = false }
        guard ownerCheck.isAvailable else {
            isLocked = false
            return
        }
        if await ownerCheck.confirm(reason: "Open lyfe") {
            isLocked = false
        }
    }

    // MARK: Notifications

    /// Called when Apple hands the app its device token, which happens on
    /// every launch once notifications are allowed.
    public func setPushToken(_ apnsToken: String) async {
        self.apnsToken = apnsToken
        await sendPushToken()
    }

    /// Tells the backend the device token, once per session and whenever
    /// it changes. A failure is retried on the next refresh.
    private func sendPushToken() async {
        guard phase == .signedIn, let api, let token, let apnsToken, apnsToken != apnsTokenSent else { return }
        do {
            try await api.setPushToken(token: token, apnsToken: apnsToken)
            apnsTokenSent = apnsToken
        } catch {
            // Offline or signed out elsewhere; refresh deals with both.
        }
    }

    /// Why prompts will not arrive, when they will not.
    public var notificationsProblem: String? {
        if notificationsAllowed == false {
            return "Prompts are off. Allow notifications for lyfe in Settings."
        }
        if home?.notifications?.serverReady == false {
            return "Prompts are off. The server has no Apple key yet."
        }
        return nil
    }

    private func forgetSession() {
        receipt = nil
        recentPortions = []
        drafts.saveRecent([])
        token = nil
        apnsTokenSent = nil
        tokens.clear()
        cache.clear()
        home = nil
        homeFetchedAt = nil
        isOffline = false
        offlineReason = nil
        refreshProblem = nil
        breathProblem = nil
        studyProblem = nil
        isStudyOpen = false
        weighInProblem = nil
        foodProblem = nil
        setAside()
        isEnteringTargets = false
        foodFlow = nil
        money = nil
        moneyProblem = nil
        worth = nil
        fire = nil
        moneySection = .month
        isEditingPlan = false
        sortingEntry = nil
        openGoalId = nil
        goalEditor = nil
        screen = .home
        isEnteringWeight = false
        isLocked = false
        phase = .signedOut
    }

    // MARK: Home

    /// Shows what the backend has now, then asks it to check Garmin and
    /// shows the result. Called when the app opens and on pull-to-refresh.
    public func refresh() async {
        guard phase == .signedIn, !isRefreshing, let api, let token else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await sendPushToken()
        await sendUnsentBreath()
        await sendUnsentStudy()
        await sendUnsentWeighIns()
        await sendUnsentFood()
        guard phase == .signedIn else { return }
        do {
            try await loadHome(api, token)
            let before = home?.sources.garmin
            let after = try await api.sync(token: token).garmin
            if after != before {
                try await loadHome(api, token)
            }
        } catch LyfeAPIError.unauthorized {
            forgetSession()
        } catch LyfeAPIError.unreachable(let why) {
            isOffline = true
            offlineReason = why
        } catch LyfeAPIError.server(let status) {
            refreshProblem = "The server answered with an error (\(status))."
        } catch LyfeAPIError.unreadableResponse {
            refreshProblem = "The server's answer could not be read. The app may be older than the server."
        } catch {
            // Cancelled mid-flight: keep what is shown.
        }
    }

    private func loadHome(_ api: LyfeAPI, _ token: String) async throws {
        show(try await api.home(token: token))
    }

    /// Fetches Home again without asking Garmin: for following an estimate
    /// while its screen is open. Quiet when it cannot reach the backend.
    public func reloadHome() async {
        guard phase == .signedIn, !isRefreshing, let api, let token else { return }
        do {
            try await loadHome(api, token)
        } catch LyfeAPIError.unauthorized {
            forgetSession()
        } catch LyfeAPIError.unreachable(let why) {
            isOffline = true
            offlineReason = why
        } catch {
            // Kept as shown; the next refresh says what is wrong.
        }
    }

    /// Takes an answer from the backend as the current state.
    private func show(_ snapshot: HomeSnapshot) {
        let fetchedAt = now()
        home = snapshot
        homeFetchedAt = fetchedAt
        isOffline = false
        offlineReason = nil
        refreshProblem = nil
        cache.save(CachedHome(snapshot: snapshot, fetchedAt: fetchedAt))
    }

    // MARK: Breath sessions

    /// Opens the table lyfe set for the next session. Nothing runs until
    /// the owner taps START. Works offline, from the last table seen.
    public func openBreathSession() {
        guard breathSession == nil, let table = home?.breath?.table else { return }
        breathSession = makeBreathSession(table: table, resuming: nil)
    }

    /// Leaves the session screen. A session still running is ended first,
    /// keeping the holds it has.
    public func closeBreathSession() {
        breathSession?.stop()
        breathSession = nil
    }

    private func makeBreathSession(table: BreathTable, resuming run: BreathRun?) -> BreathSessionModel {
        BreathSessionModel(
            table: table, resuming: run, cues: makeCues(), now: now,
            onChange: { [breath] run in breath.saveActive(run) },
            onFinish: { [weak self] run in self?.breathFinished(run) })
    }

    /// A session that was running when the app was last closed: back on
    /// screen if its rounds are still going, kept for sending if they have
    /// run out since.
    private func pickUpBreathSession() {
        guard var run = breath.loadActive() else { return }
        run.settle(at: now())
        if run.isFinished {
            keep(run)
        } else {
            breathSession = makeBreathSession(table: run.table, resuming: run)
        }
    }

    private func breathFinished(_ run: BreathRun) {
        keep(run)
        if run.roundsDone == 0 {
            // Stopped before the first hold ended: nothing to show.
            breathSession = nil
        }
        Task { await sendUnsentBreath() }
    }

    /// Moves a finished session from "in progress" to "to send". One with
    /// no hold at all is dropped.
    private func keep(_ run: BreathRun) {
        if run.roundsDone > 0 {
            breath.enqueue(run)
            if !unsentBreath.contains(run.id) {
                unsentBreath.append(run.id)
            }
        }
        breath.clearActive()
    }

    /// Sends every finished session the backend has not confirmed, oldest
    /// first, and shows the state it answers with. Each session carries its
    /// own id, so one that was received but whose answer was lost is not
    /// counted again. Called when a session ends and on every refresh.
    public func sendUnsentBreath() async {
        guard phase == .signedIn, !isSendingBreath, let api, let token else { return }
        isSendingBreath = true
        defer { isSendingBreath = false }
        for run in breath.outbox() {
            do {
                let snapshot = try await api.recordBreathSession(token: token, run: run)
                confirmed(run.id)
                show(snapshot)
                breathProblem = nil
            } catch LyfeAPIError.unreadableResponse {
                // The backend took it; only its answer could not be read.
                confirmed(run.id)
                refreshProblem = "The server's answer could not be read. The app may be older than the server."
            } catch LyfeAPIError.unauthorized {
                forgetSession()
                return
            } catch LyfeAPIError.unreachable(let why) {
                isOffline = true
                offlineReason = why
                return
            } catch LyfeAPIError.server(let status) {
                breathProblem = "The server would not take a saved breath session (\(status)). It stays on this phone."
                return
            } catch {
                return
            }
        }
    }

    private func confirmed(_ id: UUID) {
        breath.remove(id)
        unsentBreath.removeAll { $0 == id }
    }

    // MARK: Study sessions

    /// What the timer is held to: the backend's, or the usual ones before
    /// it has said.
    public var studyRules: StudyRules { home?.study?.rules ?? StudyRules() }

    /// Subjects to pick from, most recent first: the backend's, and any
    /// typed on this phone that it has not heard of yet.
    public var studySubjects: [String] {
        var names = home?.study?.subjects.map(\.name) ?? []
        for run in study.outbox() + [studyRun].compactMap({ $0 })
        where !names.contains(where: { $0.caseInsensitiveCompare(run.subject) == .orderedSame }) {
            names.insert(run.subject, at: 0)
        }
        return names
    }

    /// Opens the study screen: the timer when one is running, otherwise
    /// the subjects to start one on. Works offline.
    public func openStudy() {
        settleStudy()
        isStudyOpen = true
    }

    /// Leaves the study screen. A timer that is running keeps running.
    public func closeStudy() {
        isStudyOpen = false
    }

    /// The owner tapped START on a subject.
    public func startStudy(subject: String, kind: StudyKind) {
        guard studyRun == nil, let name = Self.subjectName(subject) else { return }
        let run = StudyRun(subject: name, kind: kind, startedAt: now())
        studyRun = run
        study.saveActive(run)
    }

    /// Changes the session in progress and keeps it on disk at once.
    public func changeStudy(_ change: (inout StudyRun) -> Void) {
        guard var run = studyRun else { return }
        change(&run)
        studyRun = run
        study.saveActive(run)
    }

    public func pauseStudy() {
        let at = now()
        changeStudy { $0.pause(at: at) }
    }

    public func resumeStudy() {
        let at = now()
        changeStudy { $0.resume(at: at) }
    }

    /// The owner started before tapping START.
    public func startStudyEarlier(minutes: Int) {
        changeStudy { $0.startEarlier(by: TimeInterval(minutes * 60)) }
    }

    /// The owner ended the session; what it was is asked next.
    public func endStudy() {
        let at = now()
        changeStudy { $0.stop(at: at) }
    }

    /// Ends a timer that has been left running past the longest a session
    /// is taken to be. Called whenever the screen looks at the clock.
    public func settleStudy() {
        guard let run = studyRun, !run.isEnded else { return }
        let at = now()
        let stopAfter = TimeInterval(studyRules.stopAfterMinutes * 60)
        changeStudy { $0.settle(at: at, stopAfter: stopAfter) }
    }

    /// Keeps the ended session and sends it.
    public func finishStudy() async {
        guard let run = studyRun, run.isEnded else { return }
        study.enqueue(run)
        if !unsentStudy.contains(run.id) {
            unsentStudy.append(run.id)
        }
        study.clearActive()
        studyRun = nil
        isStudyOpen = false
        await sendUnsentStudy()
    }

    /// Throws the session away: a timer started by mistake.
    public func discardStudy() {
        study.clearActive()
        studyRun = nil
        isStudyOpen = false
    }

    /// A session that was in progress when the app was last closed: back
    /// on screen, ended by itself if it was left too long.
    private func pickUpStudy() {
        guard let run = study.loadActive() else { return }
        studyRun = run
        settleStudy()
        isStudyOpen = true
    }

    /// Sends every finished session the backend has not confirmed, oldest
    /// first, and shows the state it answers with. Each carries its own
    /// id, so one that was received but whose answer was lost is not
    /// counted again.
    public func sendUnsentStudy() async {
        guard phase == .signedIn, !isSendingStudy, let api, let token else { return }
        isSendingStudy = true
        defer { isSendingStudy = false }
        for run in study.outbox() {
            do {
                let snapshot = try await api.recordStudySession(token: token, run: run)
                confirmedStudy(run.id)
                show(snapshot)
                studyProblem = nil
            } catch LyfeAPIError.unreadableResponse {
                // The backend took it; only its answer could not be read.
                confirmedStudy(run.id)
                refreshProblem = "The server's answer could not be read. The app may be older than the server."
            } catch LyfeAPIError.unauthorized {
                forgetSession()
                return
            } catch LyfeAPIError.unreachable(let why) {
                isOffline = true
                offlineReason = why
                return
            } catch LyfeAPIError.server(let status) {
                studyProblem = "The server would not take a saved study session (\(status)). It stays on this phone."
                return
            } catch {
                return
            }
        }
    }

    private func confirmedStudy(_ id: UUID) {
        study.remove(id)
        unsentStudy.removeAll { $0 == id }
    }

    /// A subject's name as it is kept: runs of spaces made one, at most 60
    /// characters. Nil when nothing is left.
    static func subjectName(_ text: String) -> String? {
        let name = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return name.isEmpty ? nil : String(name.prefix(60))
    }

    // MARK: Goals

    public func openGoals() {
        openGoalId = nil
        goalEditor = nil
        screen = .goals
    }

    public func closeGoals() {
        openGoalId = nil
        goalEditor = nil
        screen = .home
    }

    public func openGoal(_ id: UUID) {
        screen = .goals
        openGoalId = id
    }

    public func closeGoal() {
        openGoalId = nil
    }

    public func openGoalEditor(_ editing: GoalEditing) {
        screen = .goals
        goalEditor = editing
    }

    public func closeGoalEditor() {
        goalEditor = nil
    }

    /// Sets a goal or changes one, and shows it. Needs a connection: where
    /// a new goal starts is the backend's reading of today.
    public func saveGoal(id: UUID, _ request: GoalRequest) async -> String? {
        let problem = await changeFood("save the goal") { api, token in
            try await api.setGoal(token: token, id: id, request: request)
        }
        if problem == nil {
            goalEditor = nil
            openGoalId = id
        }
        return problem
    }

    /// Makes a goal active, parks it, or ends it. Only so many are active
    /// at once; making another active is refused here before it is asked.
    public func setGoalStatus(_ id: UUID, _ status: GoalStatus, note: String? = nil) async -> String? {
        if status == .active, let goals = home?.goals, goals.active.count >= goals.limit,
            goals.goals.first(where: { $0.id == id })?.status != .active
        {
            return "\(goals.limit) goals are active. Park one first."
        }
        return await changeFood("change the goal") { api, token in
            try await api.setGoalStatus(token: token, id: id, status: status, note: note)
        }
    }

    /// Keeps a practice test's score for an exam. Needs a connection.
    public func recordPractice(_ goal: UUID, _ entry: PracticeEntry) async -> String? {
        await changeFood("keep the score") { api, token in
            try await api.recordPractice(token: token, goal: goal, entry: entry)
        }
    }

    /// Keeps how an exam went: a pass ends its goal as reached; a fail
    /// leaves it, for its date to be moved to the next sitting.
    public func recordExamResult(_ goal: UUID, passed: Bool, on: CalendarDay, score: Int?) async -> String? {
        await changeFood("keep the result") { api, token in
            try await api.recordExamResult(token: token, goal: goal, passed: passed, on: on, score: score)
        }
    }

    // MARK: Money

    /// Opens Money on the current month, showing the last answer until the
    /// new one arrives. It opens on the section it was left on.
    public func openMoney() {
        screen = .money
        Task {
            await loadMoney(month: nil)
            await reloadMoneySection()
        }
    }

    public func closeMoney() {
        sortingEntry = nil
        isEditingPlan = false
        screen = .home
        // Home's strip says how many are left to sort.
        Task { await reloadHome() }
    }

    /// Fetches a month ("2026-11"), or the current one. Money needs the
    /// backend: with no connection the month already on screen stays.
    public func loadMoney(month: String?) async {
        guard phase == .signedIn, !isLoadingMoney else { return }
        isLoadingMoney = true
        defer { isLoadingMoney = false }
        moneyProblem = await changeMoney("fetch the month") { api, token in
            try await api.money(token: token, month: month)
        }
    }

    /// Opens the sorting screen on an entry of the month shown.
    public func openSorting(_ id: UUID) {
        guard money?.entries.contains(where: { $0.id == id }) == true else { return }
        sortingEntry = id
    }

    /// Opens the sorting screen on the oldest entry still waiting.
    public func openSortingNext() {
        sortingEntry = money?.waiting.first?.id
    }

    public func closeSorting() {
        sortingEntry = nil
    }

    /// Says what an entry is. An entry that was waiting is followed by the
    /// next one waiting, so a month is gone through without going back to
    /// the list; one sorted again closes. Returns what went wrong, or nil.
    @discardableResult
    public func sortMoney(_ id: UUID, to choice: MoneyChoice, onlyThis: Bool) async -> String? {
        guard let money, let entry = money.entries.first(where: { $0.id == id }) else { return "That entry is gone." }
        let wasWaiting = entry.toSort
        let after = money.waiting.drop { $0.id != id }.dropFirst().map(\.id)
        let problem = await changeMoney("sort it") { api, token in
            try await api.sortMoneyEntry(token: token, id: id, to: choice, onlyThis: onlyThis, month: money.month)
        }
        guard problem == nil else { return problem }
        if sortingEntry == id {
            // The next one that is still waiting: a payee sorted once may
            // have taken several of them with it.
            let waiting = Set(self.money?.waiting.map(\.id) ?? [])
            sortingEntry = wasWaiting ? (after.first(where: waiting.contains) ?? self.money?.waiting.first?.id) : nil
        }
        return nil
    }

    /// Sets an account aside, or brings it back. Returns what went wrong.
    /// What is set aside changes what everything is made of and what
    /// counts towards independence, so those are fetched again.
    @discardableResult
    public func setAside(account id: UUID, _ aside: Bool) async -> String? {
        guard let month = money?.month else { return "Open the month first." }
        let problem = await changeMoney("change the account") { api, token in
            try await api.setMoneyAccount(token: token, id: id, setAside: aside, month: month)
        }
        guard problem == nil else { return problem }
        fire = nil
        fireChanges += 1
        if worth != nil { await loadWorth() }
        return nil
    }

    /// Says what currency an account is in where the bank has it wrong, or
    /// takes that back with nil. Which totals it is in changes everything.
    public func setCurrency(account id: UUID, _ currency: String?) async -> String? {
        guard let month = money?.month else { return "Open the month first." }
        let problem = await changeMoney("change the account") { api, token in
            try await api.setMoneyAccountCurrency(token: token, id: id, currency: currency, month: month)
        }
        guard problem == nil else { return problem }
        fire = nil
        fireChanges += 1
        if worth != nil { await loadWorth() }
        return nil
    }

    /// Shows another of Money's sections, with the last answer until the
    /// new one arrives.
    public func showMoney(_ section: MoneySection) {
        moneySection = section
        moneyProblem = nil
        Task { await reloadMoneySection() }
    }

    /// Fetches what the section on screen shows. The month has its own
    /// way, since it is asked for by month.
    public func reloadMoneySection() async {
        switch moneySection {
        case .month: break
        case .worth: await loadWorth()
        case .fire: await loadFire()
        }
    }

    /// Fetches what everything comes to. One fetch at a time: asked for
    /// again meanwhile, it is fetched once more when that one is back.
    public func loadWorth() async {
        guard phase == .signedIn else { return }
        guard !isLoadingWorth else {
            worthAskedAgain = true
            return
        }
        isLoadingWorth = true
        defer { isLoadingWorth = false }
        repeat {
            worthAskedAgain = false
            let (answer, problem) = await askMoney("fetch what everything comes to") { api, token in
                try await api.moneyWorth(token: token)
            }
            if let answer { worth = answer }
            if moneySection == .worth { moneyProblem = problem }
        } while worthAskedAgain && phase == .signedIn
    }

    /// Fetches how far off financial independence is, likewise. An answer
    /// asked for before the plan or an account was changed is out of date
    /// when it comes, and is asked for again instead of shown.
    public func loadFire() async {
        guard phase == .signedIn else { return }
        guard !isLoadingFire else {
            fireAskedAgain = true
            return
        }
        isLoadingFire = true
        defer { isLoadingFire = false }
        repeat {
            fireAskedAgain = false
            let asked = fireChanges
            let (answer, problem) = await askMoney("fetch the way to independence") { api, token in
                try await api.moneyFire(token: token)
            }
            guard asked == fireChanges else {
                fireAskedAgain = true
                continue
            }
            if let answer { fire = answer }
            if moneySection == .fire { moneyProblem = problem }
        } while fireAskedAgain && phase == .signedIn
    }

    /// True while any of Money is being fetched.
    public var isFetchingMoney: Bool {
        isLoadingMoney || isLoadingWorth || isLoadingFire
    }

    /// Opens what FIRE assumes, to change it.
    public func openPlan() {
        guard fire != nil else { return }
        isEditingPlan = true
    }

    public func closePlan() {
        isEditingPlan = false
    }

    /// Says what to assume, and closes the entry once the backend has it.
    /// Returns what went wrong, or nil.
    @discardableResult
    public func setPlan(_ plan: MoneyPlan) async -> String? {
        let (answer, problem) = await askMoney("change what it assumes") { api, token in
            try await api.setMoneyPlan(token: token, plan: plan)
        }
        guard let answer else { return problem }
        fire = answer
        fireChanges += 1
        isEditingPlan = false
        return nil
    }

    /// Asks the backend about money and shows the month it answers with.
    /// `what` finishes "Could not …". Returns what went wrong, or nil.
    private func changeMoney(
        _ what: String, _ change: (LyfeAPI, String) async throws -> MoneyMonth
    ) async -> String? {
        let (month, problem) = await askMoney(what, change)
        if let month { money = month }
        return problem
    }

    /// Asks the backend something about money. `what` finishes
    /// "Could not …". Answers with what it said, or with what went wrong.
    private func askMoney<Answer>(
        _ what: String, _ ask: (LyfeAPI, String) async throws -> Answer
    ) async -> (answer: Answer?, problem: String?) {
        guard phase == .signedIn, let api, let token else { return (nil, "Sign in first.") }
        do {
            let answer = try await ask(api, token)
            // Signed out while it was on its way: nothing of it is kept.
            guard phase == .signedIn else { return (nil, "Signed out.") }
            isOffline = false
            offlineReason = nil
            return (answer, nil)
        } catch LyfeAPIError.unauthorized {
            forgetSession()
            return (nil, "Signed out.")
        } catch LyfeAPIError.unreachable(let why) {
            isOffline = true
            offlineReason = why
            return (nil, "Could not \(what): can't reach the server (\(why)).")
        } catch LyfeAPIError.unreadableResponse {
            return (nil, "The server's answer could not be read. The app may be older than the server.")
        } catch LyfeAPIError.server(let status) where (400..<500).contains(status) {
            return (nil, "The server would not \(what) (\(status)).")
        } catch LyfeAPIError.server(let status) {
            return (nil, "Could not \(what): the server answered with an error (\(status)).")
        } catch {
            return (nil, "Could not \(what).")
        }
    }

    // MARK: Progress and weigh-ins

    private(set) var startsOnTraining = false

    func openTraining() {
        openProgress()
        startsOnTraining = true
    }

    public func openProgress() {
        startsOnTraining = false
        screen = .progress
    }

    public func closeProgress() {
        isEnteringWeight = false
        screen = .home
    }

    /// Opens the weight entry over Progress. Also what tapping the morning
    /// prompt itself does, rather than typing into it.
    public func openWeighIn() {
        startsOnTraining = false
        screen = .progress
        isEnteringWeight = true
    }

    public func closeWeighIn() {
        isEnteringWeight = false
    }

    /// The unit lyfe shows weights in, as the backend last said.
    public var weightUnit: String {
        home?.weight?.unit ?? "lb"
    }

    /// Takes a weight the owner typed, into the morning prompt or the app.
    /// It is kept on this phone before anything is sent, then sent at once;
    /// with no connection it waits for the next refresh. Says what became
    /// of it, so a reply that was not a weight can be asked for again.
    @discardableResult
    public func recordWeight(_ text: String) async -> WeighInOutcome {
        guard let typed = TypedWeight(text, unit: weightUnit) else { return .unreadable }
        let weighIn = WeighIn(measuredAt: now(), value: typed.value, unit: typed.unit)
        weighIns.enqueue(weighIn)
        unsentWeighIns.append(weighIn.id)
        let refused = await sendUnsentWeighIns()
        if refused.contains(weighIn.id) { return .refused }
        return unsentWeighIns.contains(weighIn.id) ? .saved : .sent
    }

    /// Sends every weigh-in the backend has not confirmed, oldest first,
    /// and shows the state it answers with. Each carries its own id, so one
    /// that was received but whose answer was lost is not stored twice.
    /// Returns the ones the backend refused, which are dropped: sending
    /// them again would never work.
    @discardableResult
    public func sendUnsentWeighIns() async -> Set<UUID> {
        guard phase == .signedIn, !isSendingWeighIns, let api, let token else { return [] }
        isSendingWeighIns = true
        defer { isSendingWeighIns = false }
        var refused: Set<UUID> = []
        for weighIn in weighIns.outbox() {
            do {
                show(try await api.recordWeighIn(token: token, weighIn: weighIn))
                confirmedWeighIn(weighIn.id)
                weighInProblem = nil
            } catch LyfeAPIError.unreadableResponse {
                // The backend took it; only its answer could not be read.
                confirmedWeighIn(weighIn.id)
                refreshProblem = "The server's answer could not be read. The app may be older than the server."
            } catch LyfeAPIError.unauthorized {
                forgetSession()
                break
            } catch LyfeAPIError.unreachable(let why) {
                isOffline = true
                offlineReason = why
                break
            } catch LyfeAPIError.server(let status) where (400..<500).contains(status) {
                confirmedWeighIn(weighIn.id)
                refused.insert(weighIn.id)
                weighInProblem = "The server would not take the weight \(WeightText.number(weighIn.value)) \(weighIn.unit) (\(status))."
            } catch LyfeAPIError.server(let status) {
                weighInProblem = "The server could not store a weight just now (\(status)). It stays on this phone."
                break
            } catch {
                break
            }
        }
        return refused
    }

    private func confirmedWeighIn(_ id: UUID) {
        weighIns.remove(id)
        unsentWeighIns.removeAll { $0 == id }
    }

    // MARK: Food

    public func openFood() {
        screen = .food
    }

    public func closeFood() {
        setAside()
        isEnteringTargets = false
        foodFlow = nil
        screen = .home
    }

    /// What is on this phone that is a meal of the day once sent:
    /// everything but the photos sent ahead of a meal not logged yet.
    public var unsentMeals: [FoodCapture] {
        unsentCaptures.filter { capture in
            guard let meal = capture.partOf else { return true }
            return home?.food?.entries.contains { $0.id == meal } == true
        }
    }

    /// The saved meal the Food screen's bar offers: the one for the next
    /// main meal still open today. Nil when there is nothing to tap.
    public var nextMeal: SavedMeal? {
        guard let food = home?.food,
            case .log(let meal) = FoodText.bar(food, unsent: unsentFood, captures: unsentMeals).action
        else {
            return nil
        }
        return meal
    }

    /// Logs a saved meal: one tap, one portion unless another is chosen.
    /// The tap is kept on this phone before anything is sent, then sent at
    /// once; with no connection it waits for the next refresh and still
    /// counts for the day it was tapped on.
    @discardableResult
    public func logMeal(_ meal: SavedMeal, servings: Double = 1) async -> MealLogOutcome {
        let tap = MealTap(eatenAt: now(), meal: meal, servings: servings)
        food.enqueue(tap)
        unsentFood.append(tap)
        let refused = await sendUnsentFood()
        if refused.contains(tap.id) { return .refused }
        if phase == .signedIn { receipt = MealReceipt(id: tap.id, day: home?.today, name: meal.name) }
        return unsentFood.contains { $0.id == tap.id } ? .saved : .sent
    }

    /// Sends every tap the backend has not confirmed, oldest first, and
    /// shows the state it answers with. Each carries its own id, so one
    /// that was received but whose answer was lost is not logged twice.
    /// Returns the ones the backend refused, which are dropped: sending
    /// them again would never work.
    @discardableResult
    public func sendUnsentFood() async -> Set<UUID> {
        guard phase == .signedIn, !isSendingFood, let api, let token else { return [] }
        isSendingFood = true
        defer { isSendingFood = false }
        var refused: Set<UUID> = []
        var tried: Set<UUID> = []
        // Set when sending stopped for a reason that would stop the rest too.
        var stopped = false
        // Read again each time round: a meal tapped while another is on
        // its way goes out in the same pass.
        while let tap = food.outbox().first(where: { !tried.contains($0.id) }) {
            tried.insert(tap.id)
            do {
                show(try await api.recordFoodEntry(token: token, tap: tap))
                confirmedFood(tap.id)
                foodProblem = nil
            } catch LyfeAPIError.unreadableResponse {
                // The backend took it; only its answer could not be read.
                confirmedFood(tap.id)
                refreshProblem = "The server's answer could not be read. The app may be older than the server."
            } catch LyfeAPIError.unauthorized {
                forgetSession()
                stopped = true
                break
            } catch LyfeAPIError.unreachable(let why) {
                isOffline = true
                offlineReason = why
                stopped = true
                break
            } catch LyfeAPIError.server(let status) where (400..<500).contains(status) {
                confirmedFood(tap.id)
                refused.insert(tap.id)
                foodProblem = "The server would not log \(tap.name) (\(status))."
            } catch LyfeAPIError.server(let status) {
                foodProblem = "The server could not log a meal just now (\(status)). It stays on this phone."
                stopped = true
                break
            } catch {
                stopped = true
                break
            }
        }
        guard !stopped else { return refused }
        // In the order kept: a photo sent ahead goes before its meal.
        while let capture = captures.outbox().first(where: { !tried.contains($0.id) }) {
            tried.insert(capture.id)
            do {
                let snapshot =
                    switch capture.kind {
                    case .photo:
                        try await api.recordPhotoEntry(token: token, capture: capture, jpeg: captures.photo(capture.id))
                    case .barcode:
                        try await api.recordBarcodeEntry(token: token, capture: capture)
                    case .typed:
                        try await api.recordTypedEntry(token: token, capture: capture)
                    case .built:
                        try await api.recordBuiltMeal(token: token, capture: capture)
                    }
                show(snapshot)
                confirmedCapture(capture.id)
                foodProblem = nil
            } catch LyfeAPIError.unreadableResponse {
                confirmedCapture(capture.id)
                refreshProblem = "The server's answer could not be read. The app may be older than the server."
            } catch LyfeAPIError.unauthorized {
                forgetSession()
                stopped = true
                break
            } catch LyfeAPIError.unreachable(let why) {
                isOffline = true
                offlineReason = why
                stopped = true
                break
            } catch LyfeAPIError.server(let status) where (400..<500).contains(status) {
                confirmedCapture(capture.id, forget: true)
                // A photo refused is no part of the meal it was sent for.
                takeOutOfDraft(capture.id)
                refused.insert(capture.id)
                foodProblem = "The server would not log \(capture.name) (\(status))."
            } catch LyfeAPIError.server(let status) {
                foodProblem = "The server could not log a meal just now (\(status)). It stays on this phone."
                break
            } catch {
                break
            }
        }
        return refused
    }

    private func confirmedFood(_ id: UUID) {
        food.remove(id)
        unsentFood.removeAll { $0.id == id }
    }

    private func confirmedCapture(_ id: UUID, forget: Bool = false) {
        captures.remove(id, forget: forget)
        unsentCaptures.removeAll { $0.id == id }
    }

    /// Takes a logged meal back, for a tap that was a slip, or takes one
    /// part out of a meal. One still waiting on this phone is simply
    /// dropped; one the backend has needs a connection. Returns what went
    /// wrong, or nil.
    @discardableResult
    public func takeBackMeal(_ id: UUID) async -> String? {
        if isSendingFood { return "Syncing this meal. Try again in a moment." }
        if unsentFood.contains(where: { $0.id == id }) {
            confirmedFood(id)
            dismissReceipt(id)
            return nil
        }
        if let capture = unsentCaptures.first(where: { $0.id == id }) {
            confirmedCapture(id, forget: true)
            dismissReceipt(id)
            takeOutOfDraft(id)
            if case .built(_, let parts) = capture.kind {
                await dropPhotos(of: parts)
            }
            return nil
        }
        let problem = await changeFood("take that back") { api, token in
            try await api.removeFoodEntry(token: token, id: id)
        }
        if problem == nil {
            dismissReceipt(id)
            takeOutOfDraft(id)
        }
        return problem
    }

    /// Takes a part out of the meal being built, on the builder or set
    /// aside.
    private func takeOutOfDraft(_ part: UUID) {
        changeDraft { $0.parts.removeAll { $0.id == part } }
        if parkedMeal?.parts.contains(where: { $0.id == part }) == true {
            parkedMeal?.parts.removeAll { $0.id == part }
            keepDraft()
        }
    }

    /// Drops the photos of a meal that will not be logged from them: the
    /// ones still on this phone at once, the ones already sent ahead on
    /// the backend when it can be reached. One it cannot be told about is
    /// dropped there by itself, a week on.
    private func dropPhotos(of parts: [MealPart]) async {
        for part in parts {
            guard case .photo = part.kind else { continue }
            if unsentCaptures.contains(where: { $0.id == part.id }) {
                confirmedCapture(part.id, forget: true)
            } else if phase == .signedIn, let api, let token,
                let snapshot = try? await api.removeFoodEntry(token: token, id: part.id)
            {
                show(snapshot)
            }
        }
    }

    // MARK: Building a meal

    /// Opens the builder on the meal being built, or on a new one: what was
    /// eaten, added part by part, to log now, save for one tap, or both.
    public func openMealBuilder(typing: Bool = false) {
        screen = .food
        isEnteringTargets = false
        foodFlow = nil
        builderStartsTyping = typing
        guard mealDraft?.purpose != .log else { return }
        mealDraft = parkedMeal ?? MealDraft(slot: .likely(at: now()), purpose: .log, startedAt: now())
        parkedMeal = nil
        keepDraft()
    }

    /// Opens the builder on a new saved meal, or on a saved one to change.
    public func openMealEditor(_ meal: SavedMeal? = nil) {
        screen = .food
        isEnteringTargets = false
        foodFlow = nil
        setAside()
        mealDraft = meal.map { MealDraft(editing: $0) } ?? MealDraft(startedAt: now())
    }

    /// Opens the builder on a meal already logged from parts, to save it
    /// for one tap. False while a part's figures are not known.
    @discardableResult
    public func openMealEditor(savingLogged id: UUID) -> Bool {
        guard let entry = home?.food?.entries.first(where: { $0.id == id }), let draft = MealDraft(saving: entry) else {
            return false
        }
        screen = .food
        isEnteringTargets = false
        foodFlow = nil
        setAside()
        mealDraft = draft
        return true
    }

    /// Leaves the builder. A meal being built with parts in it is set
    /// aside to carry on with; a recipe being typed is dropped.
    public func closeMealEditor() {
        let dropped = mealDraft
        setAside()
        if let dropped, parkedMeal?.id != dropped.id {
            Task { await dropPhotos(of: dropped.parts) }
        }
    }

    /// Takes the builder off the screen, keeping a meal being built that
    /// has parts and was not saved instead.
    private func setAside() {
        if let draft = mealDraft, draft.purpose == .log, !draft.parts.isEmpty, !draft.isSaved {
            parkedMeal = draft
        }
        mealDraft = nil
        keepDraft()
    }

    /// Writes the meal being built to this phone, or forgets it.
    private func keepDraft() {
        drafts.save(mealDraft?.purpose == .log ? mealDraft : parkedMeal)
    }

    /// Changes the meal on the builder. One that was saved for one tap and
    /// is changed again is no longer what was saved.
    public func changeDraft(_ change: (inout MealDraft) -> Void) {
        guard var draft = mealDraft else { return }
        change(&draft)
        guard draft != mealDraft else { return }
        draft.isSaved = false
        mealDraft = draft
        keepDraft()
    }

    /// Adds a part, typed or scanned, to the meal on the builder.
    public func addPart(_ part: MealPart) {
        changeDraft { draft in
            if draft.parts.count < MealDraft.maxParts { draft.parts.append(part) }
        }
    }

    /// Adds a scanned food to the meal on the builder and goes back to it.
    /// A code nothing could be found for is looked up when the meal is sent.
    public func addScan(code: String, grams: Double, product: Product?) {
        addPart(.scanned(code: code, grams: grams, product: product))
        foodFlow = nil
    }

    /// Adds a photo and its line to the meal on the builder, and sends it
    /// ahead to be estimated while the rest is added. Without a connection
    /// it is kept and sent before the meal is.
    @discardableResult
    public func addPhoto(note: String, photo: Data?) async -> MealLogOutcome {
        guard let draft = mealDraft, draft.parts.count < MealDraft.maxParts else { return .refused }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let part = MealPart(.photo(note: note, hasPhoto: photo != nil))
        addPart(part)
        foodFlow = nil
        let capture = FoodCapture(
            id: part.id, eatenAt: now(), slot: draft.slot, kind: .photo(note: note, hasPhoto: photo != nil),
            partOf: draft.id)
        return await log(capture, jpeg: photo)
    }

    /// The backend's entry for each photo of the meal being built, once it
    /// has one: being estimated, estimated, or left to be typed.
    public var draftEstimates: [UUID: FoodDay.Entry] {
        guard let draft = mealDraft ?? parkedMeal, let sent = home?.food?.drafts else { return [:] }
        var found: [UUID: FoodDay.Entry] = [:]
        for part in draft.parts {
            if case .photo = part.kind, let entry = sent.first(where: { $0.id == part.id }) {
                found[part.id] = entry
            }
        }
        return found
    }

    /// Logs the meal on the builder as one meal and closes the builder. It
    /// is kept on this phone before anything is sent, like every meal, and
    /// does not wait for a photo still being estimated: that part fills in
    /// afterwards. A meal saved for one tap in this sitting is logged as
    /// that tap. Returns what went wrong, or nil.
    @discardableResult
    public func logMealDraft() async -> String? {
        guard let draft = mealDraft else { return nil }
        guard !draft.parts.isEmpty else { return "Add what you ate first." }
        guard draft.name.trimmingCharacters(in: .whitespacesAndNewlines).count <= MealDraft.maxNameLength else {
            return "The name is too long."
        }
        if draft.isSaved, let meal = home?.food?.meals.first(where: { $0.id == draft.mealId }) {
            mealDraft = nil
            keepDraft()
            let outcome = await logMeal(meal)
            await dropPhotos(of: draft.parts)
            return outcome == .refused ? foodProblem : nil
        }
        let capture = FoodCapture(
            id: draft.id, eatenAt: now(), slot: draft.slot, kind: .built(name: draft.name, parts: draft.parts))
        let portion = draft.ingredients(estimates: draftEstimates)
        mealDraft = nil
        keepDraft()
        if await log(capture, jpeg: nil) == .refused {
            // Nothing was logged; the meal is still there to put right.
            mealDraft = draft
            keepDraft()
            return foodProblem ?? "The server would not log the meal."
        }
        if phase == .signedIn {
            receipt = MealReceipt(id: capture.id, day: home?.today, name: capture.name)
            if let portion, !portion.isEmpty {
                recentPortions = Array(([portion] + recentPortions.filter { $0 != portion }).prefix(6))
                drafts.saveRecent(recentPortions)
            }
        }
        return nil
    }

    /// Saves the meal on the builder for one tap. Needs a connection, and
    /// every part's figures: a photo's estimate is saved as it stands, and
    /// stays an estimate each time the meal is logged. A recipe being
    /// typed closes; a meal being built stays, to be logged as well.
    /// Returns what went wrong, or nil.
    @discardableResult
    public func saveMeal() async -> String? {
        guard let draft = mealDraft else { return nil }
        let estimates = draftEstimates
        if let missing = draft.missing(estimates: estimates) { return missing + "." }
        guard let ingredients = draft.ingredients(estimates: estimates) else { return nil }
        let problem = await changeFood("save the meal") { api, token in
            try await api.saveMeal(
                token: token, id: draft.mealId, name: draft.name, slot: draft.slot, portions: draft.portions,
                ingredients: ingredients)
        }
        guard problem == nil else { return problem }
        if draft.purpose == .recipe {
            mealDraft = nil
            await dropPhotos(of: draft.parts)
        } else if mealDraft?.id == draft.id {
            mealDraft?.isSaved = true
            mealDraft?.isNew = false
            keepDraft()
        }
        return nil
    }

    /// Throws away the meal on the builder, and the photos sent for it.
    public func discardMeal() async {
        guard let draft = mealDraft else { return }
        mealDraft = nil
        keepDraft()
        await dropPhotos(of: draft.parts)
    }

    /// Takes a saved meal out of the list and closes the editor. What was
    /// logged from it stays. Returns what went wrong, or nil.
    @discardableResult
    public func removeMeal(_ id: UUID) async -> String? {
        let problem = await changeFood("remove the meal") { api, token in
            try await api.removeMeal(token: token, id: id)
        }
        if problem == nil { mealDraft = nil }
        return problem
    }

    public func openTargets() {
        screen = .food
        setAside()
        isEnteringTargets = true
    }

    public func closeTargets() {
        isEnteringTargets = false
    }

    /// Sets the calorie and protein targets from today on and closes the
    /// entry. Only the owner sets them. Returns what went wrong, or nil.
    @discardableResult
    public func setFoodTargets(_ targets: FoodTargets) async -> String? {
        let problem = await changeFood("set the targets") { api, token in
            try await api.setFoodTargets(token: token, targets: targets)
        }
        if problem == nil { isEnteringTargets = false }
        return problem
    }

    // MARK: Parts: photos, barcodes and typed food

    func recordProgress(_ entry: ProgressEntry) async -> String? {
        await changeFood("save progress") { api, token in try await api.recordProgress(token: token, entry: entry) }
    }

    /// Opens the photo screen: for the meal being built, starting one when
    /// there is none, or with `into` for a meal already logged.
    public func openPhotoMeal(into meal: UUID? = nil) {
        if meal == nil, mealDraft == nil { openMealBuilder() }
        screen = .food
        isEnteringTargets = false
        foodFlow = .photo(into: meal)
    }

    /// Opens a photo's estimate, to check and correct it.
    public func openEstimate(_ id: UUID) {
        screen = .food
        foodFlow = .estimate(id)
    }

    /// Opens the barcode scanner: for the meal being built, starting one
    /// when there is none, or with `into` for a meal already logged.
    public func openScan(into meal: UUID? = nil) {
        if meal == nil, mealDraft == nil { openMealBuilder() }
        screen = .food
        isEnteringTargets = false
        foodFlow = .scan(into: meal)
    }

    /// Opens the label entry for a code lyfe does not know.
    public func openLabel(code: String) {
        screen = .food
        foodFlow = .label(code: code)
    }

    /// Opens a meal logged from parts.
    public func openMeal(_ id: UUID) {
        screen = .food
        foodFlow = .meal(id)
    }

    /// Leaves a part's screen for where it was opened from: the logged
    /// meal it belongs to, or else the builder or Food.
    public func closeFoodFlow() {
        switch foodFlow {
        case .estimate(let id):
            foodFlow = (home?.food?.meal(holding: id)).map { .meal($0.id) }
        case .photo(let meal?), .scan(let meal?):
            foodFlow = .meal(meal)
        default:
            foodFlow = nil
        }
    }

    /// Logs a photo and one line: as a meal of its own, or with `partOf`
    /// as a part joining a meal already logged. It is kept on this phone
    /// before anything is sent, then sent at once; with no connection it
    /// waits for the next refresh and still counts for the day it was
    /// eaten on. Once the backend has it, its estimate opens, to follow
    /// and correct.
    @discardableResult
    public func logPhotoMeal(note: String, photo: Data?, slot: MealSlot, partOf meal: UUID? = nil) async
        -> MealLogOutcome
    {
        let capture = FoodCapture(
            eatenAt: now(), slot: slot,
            kind: .photo(note: note.trimmingCharacters(in: .whitespacesAndNewlines), hasPhoto: photo != nil),
            partOf: meal)
        let outcome = await log(capture, jpeg: photo)
        foodFlow = outcome == .sent ? .estimate(capture.id) : meal.map { .meal($0) }
        return outcome
    }

    /// Logs packaged food by its barcode and the grams eaten: as a meal of
    /// its own, or with `partOf` as a part joining a meal already logged.
    /// Kept on this phone before it is sent, like every meal. A code the
    /// backend does not know is logged too, and its label is asked for.
    @discardableResult
    public func logBarcode(code: String, grams: Double, slot: MealSlot, product: Product?, partOf meal: UUID? = nil)
        async -> MealLogOutcome
    {
        let capture = FoodCapture(
            eatenAt: now(), slot: slot, kind: .barcode(code: code, grams: grams, product: product), partOf: meal)
        let outcome = await log(capture, jpeg: nil)
        foodFlow = meal.map { .meal($0) }
        return outcome
    }

    /// Logs a food typed by hand, weighed or whole: as a meal of its own,
    /// or with `partOf` as a part joining a meal already logged.
    @discardableResult
    public func logTyped(_ food: Ingredient, slot: MealSlot, partOf meal: UUID? = nil) async -> MealLogOutcome {
        await log(FoodCapture(eatenAt: now(), slot: slot, kind: .typed(food), partOf: meal), jpeg: nil)
    }

    /// Keeps a meal or a part on this phone, sends it, and says what
    /// became of it.
    private func log(_ capture: FoodCapture, jpeg: Data?) async -> MealLogOutcome {
        captures.enqueue(capture, jpeg: jpeg)
        unsentCaptures.append(capture)
        let refused = await sendUnsentFood()
        return refused.contains(capture.id) ? .refused : unsentCaptures.contains { $0.id == capture.id } ? .saved : .sent
    }

    /// What lyfe knows of a barcode.
    public enum ProductLookup: Equatable, Sendable {
        case found(Product)
        /// Neither the owner's labels nor the food database have it.
        case notFound
        /// The backend could not be asked, and this phone has not seen it.
        case offline
    }

    /// Looks a code up: packaged food logged lately is known on this phone
    /// without a connection; anything else is asked of the backend.
    public func lookUp(code: String) async -> ProductLookup {
        if let known = home?.food?.products?.first(where: { Self.sameCode($0.code, code) }) {
            return .found(known)
        }
        guard phase == .signedIn, let api, let token else { return .offline }
        do {
            return try await api.product(token: token, code: code).map(ProductLookup.found) ?? .notFound
        } catch LyfeAPIError.unauthorized {
            forgetSession()
            return .offline
        } catch LyfeAPIError.unreachable(let why) {
            isOffline = true
            offlineReason = why
            return .offline
        } catch {
            return .offline
        }
    }

    /// A 12-digit UPC and the 13-digit EAN with a 0 in front are one code.
    static func sameCode(_ a: String, _ b: String) -> Bool {
        func long(_ code: String) -> String { code.count == 12 ? "0" + code : code }
        return long(a) == long(b)
    }

    /// Stores a label typed for a barcode; meals waiting for it get their
    /// figures. Returns what went wrong, or nil.
    @discardableResult
    public func setLabel(_ product: Product) async -> String? {
        await changeFood("save the label") { api, token in
            try await api.setProduct(token: token, product: product)
        }
    }

    /// Corrects a photo meal's estimate. Returns what went wrong, or nil.
    @discardableResult
    public func correctEstimate(_ id: UUID, _ change: LyfeAPI.EstimateChange) async -> String? {
        await changeFood("change the estimate") { api, token in
            try await api.correctEstimate(token: token, id: id, change: change)
        }
    }

    /// The photo of a meal: the copy on this phone while it is kept, else
    /// the backend's.
    public func mealPhoto(_ id: UUID) async -> Data? {
        if let local = captures.photo(id) { return local }
        guard phase == .signedIn, let api, let token else { return nil }
        return try? await api.foodPhoto(token: token, id: id)
    }

    /// A meal's photo drawn as a Poster illustration: the copy on this
    /// phone, else the backend's, kept here once fetched. Nil while it has
    /// not been drawn, or cannot be fetched now.
    public func mealIllustration(_ illustration: Illustration) async -> Data? {
        if let kept = illustrations.picture(illustration) { return kept }
        guard phase == .signedIn, let api, let token else { return nil }
        guard let png = try? await api.foodIllustration(token: token, illustration) else { return nil }
        illustrations.keep(png, for: illustration)
        return png
    }

    /// A food's icon as this phone has it, asking nobody: in the look the
    /// backend draws now, else in whichever look it was kept, which is
    /// shown rather than nothing until the new one comes.
    public func keptFoodIcon(named name: String) -> Data? {
        if let look = home?.food?.iconLook, let kept = foodIcons.picture(FoodIcon(name: name, look: look)) {
            return kept
        }
        return foodIcons.anyPicture(named: name)
    }

    /// Asks the backend for a food's icon, and keeps it here once it is
    /// drawn. Asking is what has the Spark draw it, so while the answer is
    /// `waiting` it is worth asking again. None while the backend draws no
    /// icons or cannot be reached.
    public func askForFoodIcon(named name: String) async -> FoodIconAnswer {
        guard let look = home?.food?.iconLook else { return .none }
        let icon = FoodIcon(name: name, look: look)
        if let kept = foodIcons.picture(icon) { return .drawn(kept) }
        guard phase == .signedIn, let api, let token else { return .none }
        guard let answer = try? await api.foodIcon(token: token, icon) else { return .none }
        if case .drawn(let png) = answer { foodIcons.keep(png, for: icon) }
        return answer
    }

    /// Makes a change to food that needs the backend now, and shows the
    /// state it answers with. `what` finishes "Could not …". Returns what
    /// went wrong in words for the owner, or nil.
    private func changeFood(
        _ what: String, _ change: (LyfeAPI, String) async throws -> HomeSnapshot
    ) async -> String? {
        guard phase == .signedIn, let api, let token else { return "Sign in first." }
        do {
            show(try await change(api, token))
            return nil
        } catch LyfeAPIError.unreadableResponse {
            // The backend made the change; only its answer could not be read.
            refreshProblem = "The server's answer could not be read. The app may be older than the server."
            return nil
        } catch LyfeAPIError.unauthorized {
            forgetSession()
            return "Signed out."
        } catch LyfeAPIError.unreachable(let why) {
            isOffline = true
            offlineReason = why
            return "Could not \(what): can't reach the server (\(why))."
        } catch LyfeAPIError.server(let status) where (400..<500).contains(status) {
            return "The server would not \(what) (\(status))."
        } catch LyfeAPIError.server(let status) {
            return "Could not \(what): the server answered with an error (\(status))."
        } catch {
            return "Could not \(what)."
        }
    }
}
