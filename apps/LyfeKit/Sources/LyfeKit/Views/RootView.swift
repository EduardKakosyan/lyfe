import SwiftUI

/// The whole app: sign-in until there is a session, then Home, with the
/// breath session taking the whole screen while one is open.
public struct RootView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if let session = model.breathSession {
                // A session in progress stays on screen whatever else happens.
                BreathSessionView(model: model, session: session)
            } else {
                switch model.phase {
                case .signedOut:
                    SignInView(model: model)
                case .signedIn:
                    HomeView(model: model)
                }
            }
        }
        // The Poster palette is fixed; it does not follow dark mode.
        .preferredColorScheme(.light)
        .task(id: scenePhase) {
            if scenePhase == .active {
                await model.refresh()
            }
        }
    }
}
