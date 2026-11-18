import LyfeKit
import SwiftUI
import UIKit

@main
struct LyfeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel.live(
        deviceName: UIDevice.current.name,
        // Set per machine in Local.xcconfig, so the address is not in the
        // repository and does not have to be typed on the phone.
        defaultServerAddress: Bundle.main.object(forInfoDictionaryKey: "LyfeDefaultServer") as? String ?? ""
    )

    var body: some Scene {
        WindowGroup {
            content
                // Once signed in, and again whenever the app comes forward,
                // since notifications can be switched off in Settings.
                .task(id: "\(model.phase) \(scenePhase == .active)") {
                    delegate.onDeviceToken = { token in
                        Task { await model.setPushToken(token) }
                    }
                    if model.phase == .signedIn, scenePhase == .active, !runsItself {
                        await enableNotifications(for: model)
                    }
                }
                #if DEBUG
                    .task {
                        await reportConnectionFromEnvironment()
                        await signInFromEnvironment()
                        await runBreathFromEnvironment()
                    }
                #endif
        }
    }

    /// True when a development build was launched to run a breath session
    /// by itself; it then asks no questions on the way.
    private var runsItself: Bool {
        #if DEBUG
            ProcessInfo.processInfo.environment["LYFE_DEBUG_BREATH_RUN"] != nil
        #else
            false
        #endif
    }

    @ViewBuilder private var content: some View {
        #if DEBUG
            if let gallery = ProcessInfo.processInfo.environment["LYFE_DEBUG_GALLERY"] {
                StreakGallery(skipping: Int(gallery) ?? 0)
            } else if let screen = ProcessInfo.processInfo.environment["LYFE_DEBUG_BREATH"] {
                BreathGallery(screen: screen)
            } else {
                RootView(model: model)
            }
        #else
            RootView(model: model)
        #endif
    }

    #if DEBUG
        /// With LYFE_DEBUG_PROBE set, a development build prints how this
        /// device resolves the server's name and whether the backend answers,
        /// then quits. Read it with `devicectl device process launch --console`.
        private func reportConnectionFromEnvironment() async {
            guard ProcessInfo.processInfo.environment["LYFE_DEBUG_PROBE"] != nil else { return }
            let address = model.serverAddress
            print("PROBE server: \(address)")
            guard let url = serverURL(from: address), let host = url.host() else {
                print("PROBE result: no usable server address")
                exit(0)
            }
            func labelled(_ addresses: [String]) -> String {
                addresses.isEmpty
                    ? "no answer"
                    : addresses.map { "\($0) (\(isTailnetAddress($0) ? "tailnet" : "public"))" }.joined(separator: ", ")
            }
            print("PROBE system lookup: \(labelled(await NameLookup.system.addresses(host)))")
            print("PROBE tailscale lookup: \(labelled(await NameLookup.tailscale.addresses(host)))")
            let started = Date()
            do {
                try await LyfeAPI(baseURL: url, transport: TailnetTransport.live()).isReachable()
                print("PROBE result: the backend answered in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            } catch {
                print("PROBE result: \(error)")
            }
            exit(0)
        }

        /// With LYFE_DEBUG_BREATH_RUN set to a number of seconds, a signed-in
        /// development build runs the next breath session by itself, ending
        /// every hold after that many seconds. For watching the whole
        /// session, sounds and upload included, without tapping; use it
        /// against a local backend, since the session is recorded.
        private func runBreathFromEnvironment() async {
            guard let text = ProcessInfo.processInfo.environment["LYFE_DEBUG_BREATH_RUN"], let hold = Double(text)
            else { return }
            for _ in 0..<100 where model.home?.breath == nil {
                try? await Task.sleep(for: .milliseconds(200))
            }
            model.openBreathSession()
            guard let session = model.breathSession else { return }
            try? await Task.sleep(for: .seconds(2))
            session.start()
            while session.isRunning {
                if case .hold(_, let since, _) = session.phase, Date().timeIntervalSince(since) >= hold {
                    session.tap()
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        /// Development builds can be launched already signed in, for
        /// running against a local backend from the command line:
        /// LYFE_DEBUG_SERVER and LYFE_DEBUG_PASSWORD in the environment.
        private func signInFromEnvironment() async {
            let environment = ProcessInfo.processInfo.environment
            guard model.phase == .signedOut,
                let server = environment["LYFE_DEBUG_SERVER"],
                let password = environment["LYFE_DEBUG_PASSWORD"]
            else { return }
            model.serverAddress = server
            await model.signIn(password: password)
        }
    #endif
}
