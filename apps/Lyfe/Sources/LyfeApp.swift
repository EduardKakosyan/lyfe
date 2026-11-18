import LyfeKit
import SwiftUI
import UIKit

@main
struct LyfeApp: App {
    @State private var model = AppModel.live(
        deviceName: UIDevice.current.name,
        // Set per machine in Local.xcconfig, so the address is not in the
        // repository and does not have to be typed on the phone.
        defaultServerAddress: Bundle.main.object(forInfoDictionaryKey: "LyfeDefaultServer") as? String ?? ""
    )

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                #if DEBUG
                    .task {
                        await reportConnectionFromEnvironment()
                        await signInFromEnvironment()
                    }
                #endif
        }
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
