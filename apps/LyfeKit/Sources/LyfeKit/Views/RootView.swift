import SwiftUI

/// The whole app: sign-in until there is a session, then Home, with the
/// breath session taking the whole screen while one is open. Progress and
/// the weight entry open from Home or from the morning prompt. All of it
/// is behind Face ID each time lyfe is opened.
public struct RootView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if model.isLocked {
                LockView(model: model)
            } else if let session = model.breathSession {
                // A session in progress stays on screen whatever else happens.
                BreathSessionView(model: model, session: session)
            } else {
                switch model.phase {
                case .signedOut:
                    SignInView(model: model)
                case .signedIn:
                    if model.isEnteringWeight, let today = model.home?.today {
                        WeighInView(
                            unit: model.weightUnit, latest: model.home?.weight?.latest, today: today,
                            onSave: { await model.recordWeight($0) }, onClose: { model.closeWeighIn() })
                    } else if model.screen == .progress, let home = model.home {
                        ProgressScreen(
                            weight: home.weight, today: home.today, unsent: model.unsentWeighIns.count,
                            problem: model.weighInProblem, onBack: { model.closeProgress() },
                            onWeighIn: { model.openWeighIn() })
                    } else {
                        HomeView(model: model)
                    }
                }
            }
        }
        // The Poster palette is fixed; it does not follow dark mode. The
        // lock is ink, so the clock and battery over it are drawn light.
        .preferredColorScheme(model.isLocked ? .dark : .light)
        .task(id: scenePhase) {
            if scenePhase == .active {
                await model.refresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Every time lyfe leaves the screen it is locked again.
            if phase == .background {
                model.lock()
            }
        }
    }
}

/// What lyfe shows until Face ID has confirmed its owner. It asks by
/// itself once each time lyfe comes forward; the bar asks again after a
/// refusal.
struct LockView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var asked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Text("LYFE")
                .font(.system(size: 96, weight: .heavy))
                .tracking(-4)
                .padding(.horizontal, Poster.margin)
            Text("Locked").posterLabel().padding(.horizontal, Poster.margin)
            Spacer()
            Button {
                Task { await model.unlock() }
            } label: {
                BreathBar(small: "Face ID or your passcode", big: "UNLOCK", mark: "→", onDark: true)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Poster.paper)
        .background(Poster.ink.ignoresSafeArea())
        // Only once it is on screen: the system refuses to ask from behind.
        .task(id: scenePhase) {
            if scenePhase == .active, !asked {
                asked = true
                await model.unlock()
            }
        }
    }
}
