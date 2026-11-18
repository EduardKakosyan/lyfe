import SwiftUI

/// The whole app: sign-in until there is a session, then Home.
public struct RootView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            switch model.phase {
            case .signedOut:
                SignInView(model: model)
            case .signedIn:
                HomeView(model: model)
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
