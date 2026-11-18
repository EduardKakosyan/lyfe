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
    private let transport: any HTTPTransport
    private let deviceName: String
    private let now: @Sendable () -> Date

    public init(
        tokens: any TokenStore,
        addresses: any ServerAddressStore,
        cache: HomeCache,
        transport: any HTTPTransport,
        deviceName: String,
        defaultServerAddress: String = "",
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tokens = tokens
        self.addresses = addresses
        self.cache = cache
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
    }

    /// The app wired to the real Keychain, disk and network.
    public static func live(deviceName: String, defaultServerAddress: String = "") -> AppModel {
        AppModel(
            tokens: KeychainTokenStore(),
            addresses: DefaultsServerAddressStore(),
            cache: .standard(),
            transport: TailnetTransport.live(),
            deviceName: deviceName,
            defaultServerAddress: defaultServerAddress
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
        let snapshot = try await api.home(token: token)
        let fetchedAt = now()
        home = snapshot
        homeFetchedAt = fetchedAt
        isOffline = false
        offlineReason = nil
        refreshProblem = nil
        cache.save(CachedHome(snapshot: snapshot, fetchedAt: fetchedAt))
    }
}
