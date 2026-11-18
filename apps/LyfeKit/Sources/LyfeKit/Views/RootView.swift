import SwiftUI

/// The whole app: sign-in until there is a session, then Home, with the
/// breath session taking the whole screen while one is open. Progress and
/// the weight entry open from Home or from the morning prompt; Food, with
/// its meal builder and targets entry, from Home or from the logging
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
                    } else if let flow = model.foodFlow, model.home?.food != nil {
                        // Over the builder too: a part is added on its
                        // own screen, and the builder is there after it.
                        FoodFlowView(model: model, flow: flow)
                    } else if let draft = model.mealDraft {
                        MealBuilderView(
                            draft: draft, estimates: model.draftEstimates,
                            unsent: Set(model.unsentCaptures.filter { $0.partOf == draft.id }.map(\.id)),
                            typing: model.builderStartsTyping, onChange: { model.changeDraft($0) }, onScan: { model.openScan() },
                            onPhoto: { model.openPhotoMeal() }, onEstimate: { model.openEstimate($0) },
                            onLog: { await model.logMealDraft() }, onSave: { await model.saveMeal() },
                            onRemove: { await model.removeMeal(draft.mealId) }, onDiscard: { await model.discardMeal() },
                            onFollow: {
                                await model.sendUnsentFood()
                                await model.reloadHome()
                            }, onClose: { model.closeMealEditor() }
                        )
                        .id(draft.id)
                    } else if model.isEnteringTargets, let food = model.home?.food {
                        FoodTargetsView(
                            current: food.target, today: food.day, onSave: { await model.setFoodTargets($0) },
                            onClose: { model.closeTargets() })
                    } else if model.screen == .food, let food = model.home?.food {
                        FoodScreen(
                            food: food, unsent: model.unsentFood, captures: model.unsentMeals,
                            building: model.parkedMeal.map {
                                .init(parts: $0.parts.count, kcal: $0.total(estimates: model.draftEstimates).kcal)
                            },
                            problem: model.foodProblem, onBack: { model.closeFood() },
                            onLog: { await model.logMeal($0, servings: $1) },
                            onTakeBack: { await model.takeBackMeal($0) }, onEditMeal: { model.openMealEditor($0) },
                            onTargets: { model.openTargets() }, onPhoto: { model.openPhotoMeal() },
                            onScan: { model.openScan() }, onBuild: { model.openMealBuilder(typing: $0) },
                            onMeal: { model.openMeal($0) }, onEstimate: { model.openEstimate($0) },
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
        // Rows show a meal's illustration once drawn, fetched once.
        .environment(\.mealIllustration, IllustrationSource { [model] id in await model.mealIllustration(id) })
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

/// The screens over Food and the builder: adding a part, a photo's
/// estimate, a label, and a meal logged from parts.
struct FoodFlowView: View {
    let model: AppModel
    let flow: AppModel.FoodFlow

    var body: some View {
        switch flow {
        case .photo(let into):
            PhotoMealView(
                asPart: true,
                onLog: { note, photo, _ in
                    if let meal = logged(into) {
                        await model.logPhotoMeal(note: note, photo: photo, slot: meal.slot, partOf: meal.id)
                    } else {
                        await model.addPhoto(note: note, photo: photo)
                    }
                }, onClose: { model.closeFoodFlow() })
        case .estimate(let id):
            if let entry = model.home?.food?.entry(id) {
                EstimateView(
                    entry: entry, inMeal: model.home?.food?.entries.contains { $0.id == id } != true,
                    loadPhoto: { await model.mealPhoto(id) }, loadIllustration: { await model.mealIllustration(id) },
                    onCorrect: { await model.correctEstimate(id, $0) },
                    onReload: { await model.reloadHome() }, onTakeBack: { await model.takeBackMeal(id) },
                    onClose: { model.closeFoodFlow() })
            } else if let capture = model.unsentCaptures.first(where: { $0.id == id }) {
                WaitingPhotoView(capture: capture, loadPhoto: { await model.mealPhoto(id) }, onClose: { model.closeFoodFlow() })
            } else {
                // Taken off, or from another day: back to Food.
                Color.clear.onAppear { model.closeFoodFlow() }
            }
        case .scan(let into):
            ScanView(
                asPart: true, lookUp: { await model.lookUp(code: $0) }, onSetLabel: { await model.setLabel($0) },
                onLog: { code, grams, _, product in
                    if let meal = logged(into) {
                        await model.logBarcode(code: code, grams: grams, slot: meal.slot, product: product, partOf: meal.id)
                    } else {
                        model.addScan(code: code, grams: grams, product: product)
                    }
                }, onClose: { model.closeFoodFlow() })
        case .label(let code):
            LabelView(
                code: code,
                onSave: { label in
                    let problem = await model.setLabel(label)
                    if problem == nil { model.closeFoodFlow() }
                    return problem
                }, onClose: { model.closeFoodFlow() })
        case .meal(let id):
            if let meal = logged(id) {
                LoggedMealView(
                    meal: meal, unsent: model.unsentCaptures.filter { $0.partOf == id },
                    onScan: { model.openScan(into: id) }, onPhoto: { model.openPhotoMeal(into: id) },
                    onType: { await model.logTyped($0, slot: meal.slot, partOf: id) },
                    onEstimate: { model.openEstimate($0) }, onLabel: { model.openLabel(code: $0) },
                    onTakeBack: { await model.takeBackMeal($0) }, onSave: { model.openMealEditor(savingLogged: id) },
                    onReload: { await model.reloadHome() }, onClose: { model.closeFoodFlow() })
            } else {
                // Taken off, or from another day: back to Food.
                Color.clear.onAppear { model.closeFoodFlow() }
            }
        }
    }

    /// The meal on the day a part is being added to, when it is one.
    private func logged(_ id: UUID?) -> FoodDay.Entry? {
        guard let id else { return nil }
        return model.home?.food?.entries.first { $0.id == id && $0.from == .built }
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
