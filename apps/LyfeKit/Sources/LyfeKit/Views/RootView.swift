import SwiftUI

/// The whole app: sign-in until there is a session, then Home, with the
/// breath session taking the whole screen while one is open. Progress and
/// the weight entry open from Home or from the morning prompt; Food, with
/// its meal editor and targets entry, from Home or from the logging
/// prompt. All of it is behind Face ID each time lyfe is opened.
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
                    } else if let draft = model.mealDraft {
                        MealEditorView(
                            start: draft, onSave: { await model.saveMeal($0) }, onRemove: { await model.removeMeal($0) },
                            onClose: { model.closeMealEditor() }
                        )
                        .id(draft.id)
                    } else if let flow = model.foodFlow, model.home?.food != nil {
                        FoodFlowView(model: model, flow: flow)
                    } else if model.isEnteringTargets, let food = model.home?.food {
                        FoodTargetsView(
                            current: food.target, today: food.day, onSave: { await model.setFoodTargets($0) },
                            onClose: { model.closeTargets() })
                    } else if model.screen == .food, let food = model.home?.food {
                        FoodScreen(
                            food: food, unsent: model.unsentFood, captures: model.unsentCaptures,
                            problem: model.foodProblem, onBack: { model.closeFood() },
                            onLog: { await model.logMeal($0, servings: $1) },
                            onTakeBack: { await model.takeBackMeal($0) }, onEditMeal: { model.openMealEditor($0) },
                            onTargets: { model.openTargets() }, onPhoto: { model.openPhotoMeal() },
                            onScan: { model.openScan() }, onEstimate: { model.openEstimate($0) },
                            onLabel: { model.openLabel(code: $0) })
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

/// The photo and barcode screens over Food.
struct FoodFlowView: View {
    let model: AppModel
    let flow: AppModel.FoodFlow

    var body: some View {
        switch flow {
        case .photo:
            PhotoMealView(
                onLog: { await model.logPhotoMeal(note: $0, photo: $1, slot: $2) }, onClose: { model.closeFoodFlow() })
        case .estimate(let id):
            if let entry = model.home?.food?.entries.first(where: { $0.id == id }) {
                EstimateView(
                    entry: entry, loadPhoto: { await model.mealPhoto(id) },
                    onCorrect: { await model.correctEstimate(id, $0) }, onReload: { await model.reloadHome() },
                    onTakeBack: { await model.takeBackMeal(id) }, onClose: { model.closeFoodFlow() })
            } else if let capture = model.unsentCaptures.first(where: { $0.id == id }) {
                WaitingPhotoView(capture: capture, loadPhoto: { await model.mealPhoto(id) }, onClose: { model.closeFoodFlow() })
            } else {
                // Taken off, or from another day: back to Food.
                Color.clear.onAppear { model.closeFoodFlow() }
            }
        case .scan:
            ScanView(
                lookUp: { await model.lookUp(code: $0) }, onSetLabel: { await model.setLabel($0) },
                onLog: { await model.logBarcode(code: $0, grams: $1, slot: $2, product: $3) },
                onClose: { model.closeFoodFlow() })
        case .label(let code):
            LabelView(
                code: code,
                onSave: { label in
                    let problem = await model.setLabel(label)
                    if problem == nil { model.closeFoodFlow() }
                    return problem
                }, onClose: { model.closeFoodFlow() })
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
