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
    /// The saved meal being typed or changed, while the editor is on screen.
    public private(set) var mealDraft: MealDraft?
    /// True while the targets entry is on screen.
    public private(set) var isEnteringTargets = false

    /// The screens other than Home, for a signed-in owner.
    public enum Screen: Equatable, Sendable {
        case home
        case progress
        case food
    }

    /// True while lyfe is waiting for Face ID. Set when it is opened and
    /// each time it leaves the screen; everything it shows is behind it.
    /// A weight typed into the morning prompt does not need it.
    public private(set) var isLocked = false
    private var isUnlocking = false

    public private(set) var screen: Screen = .home
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
    private let weighIns: WeighInStore
    private var isSendingWeighIns = false
    private let food: FoodStore
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
        weighIns: WeighInStore,
        food: FoodStore,
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
        self.weighIns = weighIns
        self.food = food
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
        unsentWeighIns = weighIns.outbox().map(\.id)
        unsentFood = food.outbox()
        pickUpBreathSession()
        lock()
    }

    /// The app wired to the real Keychain, disk and network.
    public static func live(
        deviceName: String, defaultServerAddress: String = "", ownerCheck: any OwnerCheck = DeviceOwnerCheck()
    ) -> AppModel {
        AppModel(
            tokens: KeychainTokenStore(),
            addresses: DefaultsServerAddressStore(),
            cache: .standard(),
            breath: .standard(),
            weighIns: .standard(),
            food: .standard(),
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
        weighInProblem = nil
        foodProblem = nil
        mealDraft = nil
        isEnteringTargets = false
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

    // MARK: Progress and weigh-ins

    public func openProgress() {
        screen = .progress
    }

    public func closeProgress() {
        isEnteringWeight = false
        screen = .home
    }

    /// Opens the weight entry over Progress. Also what tapping the morning
    /// prompt itself does, rather than typing into it.
    public func openWeighIn() {
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
        mealDraft = nil
        isEnteringTargets = false
        screen = .home
    }

    /// The saved meal the Food screen's bar offers: the one for the next
    /// main meal still open today. Nil when there is nothing to tap.
    public var nextMeal: SavedMeal? {
        guard let food = home?.food, case .log(let meal) = FoodText.bar(food, unsent: unsentFood).action else {
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
                break
            } catch LyfeAPIError.unreachable(let why) {
                isOffline = true
                offlineReason = why
                break
            } catch LyfeAPIError.server(let status) where (400..<500).contains(status) {
                confirmedFood(tap.id)
                refused.insert(tap.id)
                foodProblem = "The server would not log \(tap.name) (\(status))."
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

    /// Takes a logged meal back, for a tap that was a slip. One still
    /// waiting on this phone is simply dropped; one the backend has needs
    /// a connection. Returns what went wrong, or nil.
    @discardableResult
    public func takeBackMeal(_ id: UUID) async -> String? {
        if unsentFood.contains(where: { $0.id == id }) {
            confirmedFood(id)
            return nil
        }
        return await changeFood("take that back") { api, token in
            try await api.removeFoodEntry(token: token, id: id)
        }
    }

    /// Opens the meal editor on a new meal, or on a saved one to change.
    public func openMealEditor(_ meal: SavedMeal? = nil) {
        screen = .food
        isEnteringTargets = false
        mealDraft = meal.map { MealDraft(editing: $0) } ?? MealDraft()
    }

    public func closeMealEditor() {
        mealDraft = nil
    }

    /// Saves the meal being typed and closes the editor. Needs a
    /// connection: a recipe is set up at home, not captured on the move.
    /// Returns what went wrong, or nil.
    @discardableResult
    public func saveMeal(_ draft: MealDraft) async -> String? {
        if let missing = draft.missing { return missing + "." }
        let problem = await changeFood("save the meal") { api, token in
            try await api.saveMeal(token: token, draft: draft)
        }
        if problem == nil { mealDraft = nil }
        return problem
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
        mealDraft = nil
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
