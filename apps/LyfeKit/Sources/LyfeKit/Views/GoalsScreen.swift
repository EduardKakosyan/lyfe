import SwiftUI

/// Goals: the active ones as bands in the colour of the routine that moves
/// them, then the parked ones, then the ended ones. A goal opens to where
/// it stands against its pace; the black bar sets a new one.
struct GoalsScreen: View {
    let goals: GoalsView
    let home: HomeSnapshot?
    let weightUnit: String
    let onOpen: (UUID) -> Void
    let onNew: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Goals").posterHeading(34)
                        Spacer()
                        Text(GoalText.count(goals)).posterLabel()
                    }
                    .padding(.horizontal, Poster.margin)
                    .padding(.top, 14)
                    .padding(.bottom, 12)
                    PosterRule()
                    if goals.goals.isEmpty {
                        Text(
                            "A goal is a figure lyfe already reads, and a date: a breath hold, the weight trend, body fat, or hours of study. \(goals.limit) can be active at once."
                        )
                        .posterLabel()
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Poster.margin)
                    }
                    ForEach(goals.active) { goal in
                        Button {
                            onOpen(goal.id)
                        } label: {
                            GoalBand(goal: goal, home: home, weightUnit: weightUnit)
                        }
                        .buttonStyle(.plain)
                        PosterRule()
                    }
                    if !goals.parked.isEmpty {
                        GoalList(title: "Parked", goals: goals.parked, weightUnit: weightUnit, onOpen: onOpen)
                    }
                    if !goals.ended.isEmpty {
                        GoalList(title: "Ended", goals: goals.ended, weightUnit: weightUnit, onOpen: onOpen)
                    }
                }
            }
            Button(action: onNew) {
                BreathBar(
                    small: goals.active.count >= goals.limit
                        ? "\(goals.limit) active · a new one waits parked" : "A figure and a date",
                    big: "New goal", mark: "+", onDark: false)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Poster.ink)
        .background(Poster.paper.ignoresSafeArea())
    }
}

/// The colours a goal is shown in: those of the routine that moves it.
func goalColours(_ goal: Goal) -> (back: Color, front: Color) {
    switch goal.movedBy {
    case "study": (Poster.green, Poster.ink)
    case "breath": (Poster.blue, Poster.paper)
    default: (Poster.red, Poster.ink)
    }
}

struct GoalBand: View {
    let goal: Goal
    let home: HomeSnapshot?
    let weightUnit: String

    var body: some View {
        let colours = goalColours(goal)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(goal.title).posterLabel().lineLimit(1)
                Spacer(minLength: 8)
                Text(GoalText.aim(goal, weightUnit: weightUnit)).posterLabel().lineLimit(1)
            }
            if let exam = goal.exam {
                HStack(alignment: .lastTextBaseline) {
                    Text(GoalText.countdown(goal))
                        .font(.system(size: 44, weight: .heavy))
                        .monospacedDigit()
                        .tracking(-1.5)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 8)
                    Text(GoalText.readiness(exam)).posterLabel().multilineTextAlignment(.trailing)
                }
                PracticeSquares(exam: exam)
            } else {
                HStack(alignment: .lastTextBaseline) {
                    Text(goal.standing.map { GoalText.bare($0.current, goal.reading, weightUnit: weightUnit) } ?? "—")
                        .font(.system(size: 44, weight: .heavy))
                        .monospacedDigit()
                        .tracking(-1.5)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 8)
                    Text(GoalText.pace(goal, weightUnit: weightUnit))
                        .posterLabel()
                        .multilineTextAlignment(.trailing)
                }
                GoalTrack(goal: goal)
            }
            Text(GoalText.movedBy(goal, home: home)).posterLabel().opacity(0.75)
        }
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 14)
        .foregroundStyle(colours.front)
        .background(colours.back)
        .contentShape(Rectangle())
    }
}

/// The way from where a goal started to its figure, with where the pace
/// line stands today marked.
struct GoalTrack: View {
    let goal: Goal

    var body: some View {
        let span = goal.targetValue - goal.startValue
        let pace = span == 0 ? 1 : min(1, max(0, ((goal.standing?.paceValue ?? goal.startValue) - goal.startValue) / span))
        let done = goal.standing?.progress ?? 0
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(.foreground).frame(width: geometry.size.width * done)
                Rectangle().fill(.foreground).frame(width: 3, height: 20).offset(x: geometry.size.width * pace - 1.5)
            }
            .frame(width: geometry.size.width, height: 10, alignment: .leading)
            .overlay(Rectangle().strokeBorder(.foreground, lineWidth: 2.5))
        }
        .frame(height: 10)
        .padding(.vertical, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int(done * 100)) percent of the way; the pace line is at \(Int(pace * 100)) percent")
    }
}

struct GoalList: View {
    let title: String
    let goals: [Goal]
    let weightUnit: String
    let onOpen: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            StripRow(left: title, right: "\(goals.count)")
            PosterRule(thickness: 2)
            ForEach(goals) { goal in
                Button {
                    onOpen(goal.id)
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(goal.title).font(.system(size: 16, weight: .heavy)).textCase(.uppercase).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(GoalList.right(goal, weightUnit: weightUnit)).posterLabel().lineLimit(1)
                    }
                    .padding(.horizontal, Poster.margin)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                PosterRule(thickness: 2)
            }
        }
    }

    nonisolated static func right(_ goal: Goal, weightUnit: String) -> String {
        switch goal.status {
        case .reached: "Reached \(goal.endedOn.map(GoalText.date) ?? "")"
        case .dropped: "Dropped \(goal.endedOn.map(GoalText.date) ?? "")"
        default: GoalText.aim(goal, weightUnit: weightUnit)
        }
    }
}

// MARK: One goal

struct GoalDetailView: View {
    let goal: Goal
    let goals: GoalsView
    let home: HomeSnapshot?
    let weightUnit: String
    let today: CalendarDay
    let onChange: () -> Void
    let onStatus: (GoalStatus, String?) async -> String?
    var onPractice: (PracticeEntry) async -> String? = { _ in nil }
    var onResult: (Bool, CalendarDay, Int?) async -> String? = { _, _, _ in nil }
    let onBack: () -> Void

    @State private var problem: String?
    @State private var working = false
    @State private var confirmingDrop = false
    @State private var dropNote = ""

    var body: some View {
        let colours = goalColours(goal)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Button(action: onBack) {
                                Text("← Goals").posterLabel().padding(.vertical, 10).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Text(goal.status == .active ? GoalText.aim(goal, weightUnit: weightUnit) : goal.status.rawValue)
                                .posterLabel()
                        }
                        Text(goal.title).posterHeading(26).padding(.top, 4)
                        if let exam = goal.exam {
                            Text(Poster.tight(GoalText.countdown(goal), by: -5))
                                .font(.system(size: 92, weight: .heavy))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .padding(.vertical, 4)
                            HStack {
                                Text(goal.daysLeft >= 0 ? "To the exam" : "Since its date").posterLabel()
                                Spacer()
                                Text(GoalText.readiness(exam)).posterLabel()
                            }
                            .padding(.bottom, 8)
                        } else {
                            Text(Poster.tight(goal.standing.map { GoalText.bare($0.current, goal.reading, weightUnit: weightUnit) } ?? "—", by: -5))
                                .font(.system(size: 92, weight: .heavy))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .padding(.vertical, 4)
                            HStack {
                                Text(GoalText.unit(goal.reading, weightUnit: weightUnit) + " · now").posterLabel()
                                Spacer()
                                Text(GoalText.pace(goal, weightUnit: weightUnit)).posterLabel()
                            }
                            GoalTrack(goal: goal).padding(.top, 6)
                        }
                        Text(GoalText.movedBy(goal, home: home)).posterLabel().opacity(0.75).padding(.bottom, 14)
                    }
                    .padding(.horizontal, Poster.margin)
                    .foregroundStyle(colours.front)
                    .background(colours.back)
                    PosterRule()
                    if let problem {
                        NoticeRow(text: problem)
                        PosterRule()
                    }
                    if let exam = goal.exam {
                        ExamSection(goal: goal, exam: exam, today: today, onPractice: onPractice, onResult: onResult)
                        PosterRule().padding(.top, Poster.margin)
                    } else {
                        rows
                    }
                    if !goal.changes.isEmpty {
                        StripRow(left: "Changes", right: "\(goal.changes.count)")
                        PosterRule(thickness: 2)
                        ForEach(Array(goal.changes.enumerated()), id: \.offset) { _, change in
                            StripRow(
                                left: GoalText.change(change, reading: goal.reading, weightUnit: weightUnit),
                                right: change.on.shortLabel)
                            PosterRule(thickness: 2)
                        }
                    }
                    actions
                }
            }
            if goal.status == .active || goal.status == .parked {
                Button(action: onChange) {
                    BreathBar(
                        small: goal.exam == nil ? "Its figure or its date" : "Its date or its figures", big: "Change it",
                        mark: "→", onDark: false)
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(Poster.ink)
        .background(Poster.paper.ignoresSafeArea())
        .alert("Drop this goal?", isPresented: $confirmingDrop) {
            TextField("Why, in a line (optional)", text: $dropNote)
            Button("Drop it", role: .destructive) { act(.dropped, note: dropNote) }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("It is kept with its history, and can be taken up again.")
        }
    }

    @ViewBuilder private var rows: some View {
        let unit = weightUnit
        let started = "\(GoalText.figure(goal.startValue, goal.reading, weightUnit: unit)) on \(GoalText.date(goal.startOn))"
        StripRow(left: "Started", right: started)
        PosterRule(thickness: 2)
        StripRow(left: "Figure", right: GoalText.aim(goal, weightUnit: unit))
        PosterRule(thickness: 2)
        if let standing = goal.standing, !standing.reached {
            StripRow(left: "The line today", right: GoalText.figure(standing.paceValue, goal.reading, weightUnit: unit))
            PosterRule(thickness: 2)
        }
        if let needed = GoalText.needed(goal, weightUnit: unit) {
            StripRow(left: "Needed", right: needed)
            PosterRule(thickness: 2)
        }
        StripRow(
            left: goal.daysLeft >= 0 ? "Days left" : "Past its date",
            right: goal.daysLeft >= 0 ? "\(goal.daysLeft)" : "\(-goal.daysLeft) days · move the date or drop it")
        PosterRule(thickness: 2)
        if let note = goal.note {
            StripRow(left: "Note", right: note)
            PosterRule(thickness: 2)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            switch goal.status {
            case .active:
                action("Park it") { act(.parked) }
                if goal.exam == nil {
                    action(goal.standing?.reached == true ? "Reached · close it" : "Mark it reached") { act(.reached) }
                }
                action("Drop it") { confirmingDrop = true }
            case .parked:
                action("Make it active") { act(.active) }
                action("Drop it") { confirmingDrop = true }
            case .reached, .dropped:
                action("Take it up again") { act(.parked) }
            }
            Spacer(minLength: 0)
        }
        .padding(Poster.margin)
        .disabled(working)
    }

    private func action(_ title: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) { StudyOutlineButton(text: title) }.buttonStyle(.plain)
    }

    private func act(_ status: GoalStatus, note: String? = nil) {
        working = true
        Task {
            problem = await onStatus(status, note)
            working = false
        }
    }
}

// MARK: Setting one

struct GoalEditorView: View {
    /// Nil for a new goal.
    let existing: Goal?
    let home: HomeSnapshot?
    let weightUnit: String
    let subjects: [String]
    let today: CalendarDay
    let onSave: (GoalRequest) async -> String?
    let onClose: () -> Void

    @State private var reading: GoalReading
    /// The subject of a study goal; empty for all study.
    @State private var subject = ""
    @State private var figure: String
    @State private var due: Date
    @State private var title: String
    @State private var exam: ExamRequest
    @State private var problem: String?
    @State private var saving = false

    init(
        existing: Goal?, home: HomeSnapshot?, weightUnit: String, subjects: [String], today: CalendarDay,
        onSave: @escaping (GoalRequest) async -> String?, onClose: @escaping () -> Void
    ) {
        self.existing = existing
        self.home = home
        self.weightUnit = weightUnit
        self.subjects = subjects
        self.today = today
        self.onSave = onSave
        self.onClose = onClose
        let reading = existing?.reading ?? .studyMinutes
        _reading = State(initialValue: reading)
        _figure = State(
            initialValue: existing.map { GoalText.bare($0.targetValue, $0.reading, weightUnit: weightUnit) } ?? "")
        _due = State(initialValue: (existing?.dueOn ?? today.adding(days: 90)).noon)
        _title = State(initialValue: existing?.title ?? "")
        _exam = State(
            initialValue: existing?.exam.map(ExamRequest.init)
                ?? ExamRequest(name: "", scaleMax: 1000, passMark: 700, readyMargin: 30, readyRuns: 3))
    }

    private var target: Double? {
        reading == .exam ? (exam.problem == nil ? Double(exam.passMark) : nil) : GoalText.parse(figure, reading, weightUnit: weightUnit)
    }
    private var dueDay: CalendarDay { CalendarDay(date: due) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    StudyTopBar(left: "← Back", right: existing == nil ? "New goal" : "Change", onLeft: onClose)
                    Text(existing?.title ?? "A new goal").posterHeading(30)
                        .padding(.horizontal, Poster.margin)
                        .padding(.bottom, 12)
                    PosterRule()
                    if let problem {
                        NoticeRow(text: problem)
                        PosterRule()
                    }
                    if existing == nil {
                        Text("What it reads").posterLabel()
                            .padding(.horizontal, Poster.margin).padding(.top, 12).padding(.bottom, 4)
                        ForEach(GoalReading.allCases, id: \.self) { option in
                            let now = GoalEditorView.now(option, home: home, weightUnit: weightUnit)
                            Button {
                                reading = option
                                figure = ""
                            } label: {
                                HStack(spacing: 10) {
                                    PosterSquare(state: reading == option ? .solid : .outline, size: 16)
                                    Text(GoalText.name(option)).font(.system(size: 18, weight: .heavy)).textCase(.uppercase)
                                    Spacer()
                                    Text(now ?? "No reading yet").posterLabel().opacity(now == nil ? 0.5 : 1)
                                }
                                .padding(.horizontal, Poster.margin)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(now == nil)
                        }
                        if reading == .studyMinutes || reading == .exam {
                            PosterRule(thickness: 2).padding(.top, 6)
                            Text(reading == .exam ? "Its study is on" : "On").posterLabel()
                                .padding(.horizontal, Poster.margin).padding(.top, 10).padding(.bottom, 4)
                            ForEach([""] + subjects, id: \.self) { name in
                                Button {
                                    subject = name
                                } label: {
                                    HStack(spacing: 10) {
                                        PosterSquare(state: subject == name ? .solid : .outline, size: 14)
                                        Text(name.isEmpty ? (reading == .exam ? "No subject" : "All study") : name).font(.system(size: 16, weight: .heavy))
                                            .textCase(.uppercase)
                                        Spacer()
                                    }
                                    .padding(.horizontal, Poster.margin)
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        PosterRule().padding(.top, 8)
                    }
                    if reading == .exam {
                        ExamFields(exam: $exam)
                    } else {
                    HStack {
                        Text(reading == .studyMinutes ? "Hours from today" : "The figure").posterLabel()
                        Spacer()
                        TextField("", text: $figure, prompt: Text(GoalEditorView.example(reading, weightUnit: weightUnit)))
                            .font(.system(size: 22, weight: .heavy))
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 110)
                            #if os(iOS)
                                .keyboardType(reading == .breathHold ? .numbersAndPunctuation : .decimalPad)
                            #endif
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 2.5))
                            .accessibilityLabel("The figure")
                        Text(GoalText.unit(reading, weightUnit: weightUnit)).posterLabel().lineLimit(1).fixedSize()
                    }
                    .padding(.horizontal, Poster.margin)
                    .padding(.vertical, 12)
                    PosterRule(thickness: 2)
                    }
                    HStack {
                        Text(reading == .exam ? "Sat on" : "By").posterLabel()
                        Spacer()
                        DatePicker(
                            "By", selection: $due, in: today.adding(days: 1).noon...today.adding(days: 3650).noon,
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        .tint(Poster.ink)
                    }
                    .padding(.horizontal, Poster.margin)
                    .padding(.vertical, 8)
                    PosterRule(thickness: 2)
                    HStack {
                        Text("Name").posterLabel()
                        Spacer()
                        TextField("", text: $title, prompt: Text("Named after what it reads"))
                            .font(.system(size: 16, weight: .heavy))
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.horizontal, Poster.margin)
                    .padding(.vertical, 12)
                    PosterRule(thickness: 2)
                    if existing == nil, (home?.goals?.active.count ?? 0) >= (home?.goals?.limit ?? 3) {
                        Text("\(home?.goals?.limit ?? 3) goals are active, so this one starts parked.").posterLabel()
                            .padding(Poster.margin)
                    }
                    Text(
                        reading == .exam
                            ? "An exam has no line to keep to: practice says whether you are ready. lyfe never moves the date."
                            : "It starts from where lyfe reads it today, and the line runs straight from there to the figure on the date. lyfe never moves the date."
                    )
                        .posterLabel().opacity(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(Poster.margin)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            Button {
                save()
            } label: {
                BreathBar(
                    small: reading == .exam
                        ? (exam.problem ?? "Sat on \(GoalText.date(dueDay))")
                        : target.map { "\(GoalText.figure($0, reading, weightUnit: weightUnit)) by \(GoalText.date(dueDay))" }
                            ?? "Type the figure", big: existing == nil ? "Set it" : "Save", mark: "→", onDark: false)
            }
            .buttonStyle(.plain)
            .disabled(target == nil || saving)
            .opacity(target == nil ? 0.5 : 1)
        }
        .foregroundStyle(Poster.ink)
        .background(Poster.paper.ignoresSafeArea())
    }

    private func save() {
        guard let target else { return }
        let named = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let request = GoalRequest(
            title: named.isEmpty ? nil : named, reading: existing == nil ? reading : nil,
            subject: existing == nil && (reading == .studyMinutes || reading == .exam) && !subject.isEmpty ? subject : nil,
            targetValue: reading == .exam ? nil : target, dueOn: dueDay,
            exam: reading == .exam ? exam : nil)
        saving = true
        Task {
            problem = await onSave(request)
            saving = false
        }
    }

    /// Where a reading stands now, as the phone last heard; nil when lyfe
    /// has none, so a goal on it cannot start.
    nonisolated static func now(_ reading: GoalReading, home: HomeSnapshot?, weightUnit: String) -> String? {
        switch reading {
        case .breathHold:
            return "Best " + (home?.breath?.bestMs.map { StudyText.clock(Double($0 / 1000)) } ?? "0:00")
        case .weight:
            return home?.weight?.average.map { String(format: "Now %.1f %@", $0, weightUnit) }
        case .bodyFat:
            return home?.progress?.tapes.max(by: { $0.day < $1.day }).map { String(format: "Now %.1f%%", $0.value) }
        case .studyMinutes:
            return "From today"
        case .exam:
            return "A result to get"
        }
    }

    nonisolated static func example(_ reading: GoalReading, weightUnit: String) -> String {
        switch reading {
        case .breathHold: "3:00"
        case .weight: weightUnit == "kg" ? "78.0" : "172.0"
        case .bodyFat: "17.0"
        case .studyMinutes: "80"
        case .exam: "720"
        }
    }
}

extension CalendarDay {
    /// Noon on this day where the phone is, for a date picker.
    var noon: Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date()
    }

    /// The day a date falls on where the phone is.
    init(date: Date) {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 2026, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    func adding(days: Int) -> CalendarDay {
        CalendarDay(date: Calendar.current.date(byAdding: .day, value: days, to: noon) ?? noon)
    }
}
