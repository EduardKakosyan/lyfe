import SwiftUI

/// The whole app: sign-in until there is a session, then Home, with the
/// breath session taking the whole screen while one is open, and the study
/// screen while it is open (its timer runs on when it is closed). Progress and
/// the weight entry open from Home or from the morning prompt; Food, with
/// its meal builder and targets entry, from Home or from the logging
/// prompt; Money, with its sorting screen and what FIRE assumes, from
/// Home. All of it is behind Face ID each time lyfe is opened.
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
                    if model.isStudyOpen {
                        StudySessionView(model: model)
                    } else if model.isEnteringWeight, let today = model.home?.today {
                        WeighInView(
                            unit: model.weightUnit, latest: model.home?.weight?.latest, today: today,
                            onSave: { await model.recordWeight($0) }, onClose: { model.closeWeighIn() })
                    } else if let flow = model.foodFlow, model.home?.food != nil {
                        // Over the builder too: a part is added on its
                        // own screen, and the builder is there after it.
                        FoodFlowView(model: model, flow: flow)
                    } else if let draft = model.mealDraft {
                        MealBuilderView(
                            draft: draft, recent: model.recentPortions, saved: model.home?.food?.meals ?? [], onSaved: { meal in
                                model.closeMealEditor()
                                Task { await model.logMeal(meal) }
                            }, estimates: model.draftEstimates,
                            unsent: Set(model.unsentCaptures.filter { $0.partOf == draft.id }.map(\.id)),
                            typing: model.builderStartsTyping, onChange: { model.changeDraft($0) },
                            onScan: { model.openScan() },
                            onPhoto: { model.openPhotoMeal() }, onEstimate: { model.openEstimate($0) },
                            onLog: { await model.logMealDraft() }, onSave: { await model.saveMeal() },
                            onRemove: { await model.removeMeal(draft.mealId) },
                            onDiscard: { await model.discardMeal() },
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
                            food: food, receipt: model.receipt?.day == food.day ? model.receipt : nil, onDismiss: model.dismissReceipt, unsent: model.unsentFood, captures: model.unsentMeals,
                            building: model.parkedMeal.map {
                                .init(parts: $0.parts.count, kcal: $0.total(estimates: model.draftEstimates).kcal)
                            },
                            problem: model.foodProblem, onBack: { model.closeFood() },
                            onLog: { await model.logMeal($0, servings: $1) },
                            onTakeBack: { await model.takeBackMeal($0) },
                            onEditMeal: { model.openMealEditor($0) },
                            onTargets: { model.openTargets() }, onPhoto: { model.openPhotoMeal() },
                            onScan: { model.openScan() }, onBuild: { model.openMealBuilder(typing: $0) },
                            onMeal: { model.openMeal($0) }, onEstimate: { model.openEstimate($0) },
                            onLabel: { model.openLabel(code: $0) }, onReload: { await model.reloadHome() })
                    } else if model.screen == .money {
                        if let id = model.sortingEntry, let money = model.money,
                            let entry = money.entries.first(where: { $0.id == id })
                        {
                            SortEntryView(
                                entry: entry, categories: money.categoryNames, currency: money.currency,
                                waiting: money.toSort, onSort: { await model.sortMoney(id, to: $0, onlyThis: $1) },
                                onClose: { model.closeSorting() })
                        } else if model.isEditingPlan, let fire = model.fire {
                            PlanView(
                                plan: fire.plan, thisYear: model.home?.today.year ?? fire.ahead.first?.year ?? 2100,
                                onSave: { await model.setPlan($0) }, onClose: { model.closePlan() })
                        } else {
                            MoneyScreen(
                                money: model.money, worth: model.worth, fire: model.fire, section: model.moneySection,
                                problem: model.moneyProblem, loading: model.isFetchingMoney,
                                onBack: { model.closeMoney() }, onMonth: { await model.loadMoney(month: $0) },
                                onSort: { model.openSorting($0) }, onSortNext: { model.openSortingNext() },
                                onSetAside: { await model.setAside(account: $0, $1) },
                                onCurrency: { await model.setCurrency(account: $0, $1) },
                                onSection: { model.showMoney($0) }, onReload: { await model.reloadMoneySection() },
                                onPlan: { model.openPlan() })
                        }
                    } else if model.screen == .goals, let home = model.home {
                        let goals = home.goals ?? GoalsView(limit: 3, goals: [])
                        if let editing = model.goalEditor {
                            let existing: Goal? =
                                if case .change(let id) = editing { goals.goals.first { $0.id == id } } else { nil }
                            GoalEditorView(
                                existing: existing, home: home, weightUnit: model.weightUnit,
                                subjects: model.studySubjects, today: home.today,
                                onSave: { await model.saveGoal(id: editing.id, $0) },
                                onClose: { model.closeGoalEditor() })
                        } else if let id = model.openGoalId, let goal = goals.goals.first(where: { $0.id == id }) {
                            GoalDetailView(
                                goal: goal, goals: goals, home: home, weightUnit: model.weightUnit, today: home.today,
                                onChange: { model.openGoalEditor(.change(id)) },
                                onStatus: { await model.setGoalStatus(id, $0, note: $1) },
                                onPractice: { await model.recordPractice(id, $0) },
                                onResult: { await model.recordExamResult(id, passed: $0, on: $1, score: $2) },
                                onBack: { model.closeGoal() })
                        } else {
                            GoalsScreen(
                                goals: goals, home: home, weightUnit: model.weightUnit,
                                onOpen: { model.openGoal($0) }, onNew: { model.openGoalEditor(.new(UUID())) })
                        }
                    } else if model.screen == .progress, let home = model.home {
                        ProgressScreen(
                            weight: home.weight, today: home.today, home: home, save: model.recordProgress,
                            unsent: model.unsentWeighIns.count,
                            problem: model.weighInProblem, onBack: { model.closeProgress() },
                            onWeighIn: { model.openWeighIn() }, training: model.startsOnTraining)
                    } else {
                        HomeView(model: model)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.phase == .signedIn, !model.isLocked, model.home != nil, model.breathSession == nil,
                !model.isEnteringWeight, model.foodFlow == nil, model.mealDraft == nil,
                !model.isEnteringTargets, model.sortingEntry == nil, !model.isEditingPlan, !model.isStudyOpen,
                model.goalEditor == nil
            {
                VStack(spacing: 0) {
                    PosterRule()
                    HStack(spacing: 0) {
                        tab(.home, "Home", "house")
                        if model.home?.food != nil { tab(.food, "Food", "fork.knife") }
                        tab(.progress, "Progress", "chart.xyaxis.line")
                        tab(.money, "Money", "wallet.pass")
                        tab(.goals, "Goals", "flag")
                    }
                }.background(Poster.paper)
            }
        }
        // Rows show a meal's illustration once drawn, fetched once.
        .environment(
            \.mealIllustration, IllustrationSource { [model] in await model.mealIllustration($0) }
        )
        // The picker's tiles show a food's icon once the Spark has drawn it.
        .environment(
            \.foodIcons,
            FoodIconSource(
                kept: { [model] in model.keptFoodIcon(named: $0) },
                ask: { [model] in await model.askForFoodIcon(named: $0) })
        )
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
    private func tab(_ screen: AppModel.Screen, _ title: String, _ symbol: String) -> some View {
        let selected = screen == model.screen
        return Button {
            guard !selected else { return }
            switch model.screen {
            case .money: model.closeMoney()
            case .food: model.closeFood()
            case .progress: model.closeProgress()
            case .goals: model.closeGoals()
            case .home: break
            }
            switch screen {
            case .money: model.openMoney()
            case .food: model.openFood()
            case .progress: model.openProgress()
            case .goals: model.openGoals()
            case .home: break
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                Text(title).font(.caption.bold())
            }.frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(selected ? Poster.paper : Poster.ink)
                .background(selected ? Poster.ink : Poster.paper)
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
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
                    loadPhoto: { await model.mealPhoto(id) },
                    loadIllustration: {
                        guard let drawn = model.home?.food?.entry(id)?.illustration else { return nil }
                        return await model.mealIllustration(drawn)
                    },
                    onCorrect: { await model.correctEstimate(id, $0) },
                    onReload: { await model.reloadHome() }, onTakeBack: { await model.takeBackMeal(id) },
                    onClose: { model.closeFoodFlow() })
            } else if let capture = model.unsentCaptures.first(where: { $0.id == id }) {
                WaitingPhotoView(
                    capture: capture, loadPhoto: { await model.mealPhoto(id) },
                    onClose: { model.closeFoodFlow() })
            } else {
                // Taken off, or from another day: back to Food.
                Color.clear.onAppear { model.closeFoodFlow() }
            }
        case .scan(let into):
            ScanView(
                asPart: true, lookUp: { await model.lookUp(code: $0) },
                onSetLabel: { await model.setLabel($0) },
                onLog: { code, grams, _, product in
                    if let meal = logged(into) {
                        await model.logBarcode(
                            code: code, grams: grams, slot: meal.slot, product: product, partOf: meal.id)
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
                    onTakeBack: { await model.takeBackMeal($0) },
                    onSave: { model.openMealEditor(savingLogged: id) },
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
