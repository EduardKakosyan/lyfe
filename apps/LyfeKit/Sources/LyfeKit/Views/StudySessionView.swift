import SwiftUI

/// The study screen: the subjects to start a session on, the timer while
/// it runs, and what the session was once it ends. The timer keeps going
/// when the screen is closed, lyfe is put away or the phone is locked.
struct StudySessionView: View {
    let model: AppModel

    var body: some View {
        Group {
            if let run = model.studyRun, run.isEnded {
                StudyAfterView(
                    run: run, rules: model.studyRules, week: model.home?.study,
                    onChange: { model.changeStudy($0) },
                    onDone: { Task { await model.finishStudy() } },
                    onDiscard: { model.discardStudy() })
            } else if let run = model.studyRun {
                StudyTimerView(
                    run: run, rules: model.studyRules,
                    onPause: { model.pauseStudy() }, onResume: { model.resumeStudy() },
                    onEarlier: { model.startStudyEarlier(minutes: $0) }, onEnd: { model.endStudy() },
                    onSettle: { model.settleStudy() }, onDiscard: { model.discardStudy() },
                    onClose: { model.closeStudy() })
            } else {
                StudyReadyView(
                    subjects: model.studySubjects, rules: model.studyRules, week: model.home?.study,
                    onStart: { model.startStudy(subject: $0, kind: $1) }, onClose: { model.closeStudy() })
            }
        }
        .foregroundStyle(Poster.ink)
    }
}

// MARK: Before START

struct StudyReadyView: View {
    let subjects: [String]
    let rules: StudyRules
    let week: StudyWeek?
    let onStart: (String, StudyKind) -> Void
    let onClose: () -> Void

    @State private var chosen: String?
    @State private var typed = ""
    @State private var kind: StudyKind
    @FocusState private var typing: Bool

    init(
        subjects: [String], rules: StudyRules, week: StudyWeek?, onStart: @escaping (String, StudyKind) -> Void,
        onClose: @escaping () -> Void, startingKind: StudyKind = .questions
    ) {
        self.subjects = subjects
        self.rules = rules
        self.week = week
        self.onStart = onStart
        self.onClose = onClose
        _kind = State(initialValue: startingKind)
    }

    /// The subject START would start on.
    private var subject: String? {
        let name = typed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return name.isEmpty ? (chosen ?? (typing ? nil : subjects.first)) : name
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    StudyTopBar(left: "← Home", right: week.map { "This week · \($0.done) of \($0.target)" } ?? "", onLeft: onClose)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Study").posterHeading(44)
                        Text("Counts at \(rules.minMinutes) min · \(rules.targetMinutes) is the target").posterLabel()
                    }
                    .padding(.horizontal, Poster.margin)
                    .padding(.bottom, 16)
                    PosterRule()
                    Text("Subject").posterLabel().padding(.horizontal, Poster.margin).padding(.top, 12).padding(.bottom, 4)
                    ForEach(subjects, id: \.self) { name in
                        Button {
                            chosen = name
                            typed = ""
                            typing = false
                        } label: {
                            HStack(spacing: 10) {
                                PosterSquare(state: subject == name ? .solid : .outline, size: 16)
                                Text(name).font(.system(size: 18, weight: .heavy)).textCase(.uppercase).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Poster.margin)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 10) {
                        PosterSquare(state: !typed.isEmpty ? .solid : .outline, size: 16)
                        TextField("", text: $typed, prompt: Text(subjects.isEmpty ? "Name a subject" : "A new subject").foregroundStyle(Poster.ink.opacity(0.55)))
                            .font(.system(size: 18, weight: .heavy))
                            .focused($typing)
                            .submitLabel(.done)
                            .accessibilityLabel("New subject")
                    }
                    .padding(.horizontal, Poster.margin)
                    .padding(.vertical, 9)
                    PosterRule().padding(.top, 8)
                    Text("What it is").posterLabel().padding(.horizontal, Poster.margin).padding(.top, 12).padding(.bottom, 8)
                    StudyKindChoice(kind: $kind).padding(.horizontal, Poster.margin)
                    if kind == .build {
                        Text(StudyText.buildNote(rules: rules, week: week))
                            .posterLabel()
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Poster.margin)
                            .padding(.top, 10)
                    }
                    Spacer(minLength: 24)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            Button {
                if let subject { onStart(subject, kind) }
            } label: {
                BreathBar(small: subject ?? "Pick or name a subject", big: "Start", mark: "→", onDark: false)
            }
            .buttonStyle(.plain)
            .disabled(subject == nil)
            .opacity(subject == nil ? 0.5 : 1)
        }
        .background(Poster.green.ignoresSafeArea())
    }
}

/// Questions, reading or build, as three boxes.
struct StudyKindChoice: View {
    @Binding var kind: StudyKind

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StudyKind.allCases, id: \.self) { option in
                Button {
                    kind = option
                } label: {
                    Text(option.label)
                        .posterLabel()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundStyle(kind == option ? Poster.paper : Poster.ink)
                        .background(kind == option ? Poster.ink : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(kind == option ? .isSelected : [])
            }
        }
        .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 2.5))
    }
}

struct StudyTopBar: View {
    let left: String
    let right: String
    let onLeft: () -> Void

    var body: some View {
        HStack {
            Button(action: onLeft) {
                Text(left).posterLabel().padding(.vertical, 10).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Text(right).posterLabel().lineLimit(1)
        }
        .padding(.horizontal, Poster.margin)
        .padding(.top, 6)
    }
}

// MARK: While it runs

struct StudyTimerView: View {
    let run: StudyRun
    let rules: StudyRules
    let onPause: () -> Void
    let onResume: () -> Void
    let onEarlier: (Int) -> Void
    let onEnd: () -> Void
    let onSettle: () -> Void
    let onDiscard: () -> Void
    let onClose: () -> Void

    @State private var confirmingDiscard = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let active = run.activeSeconds(at: context.date)
            VStack(spacing: 0) {
                StudyTopBar(left: "← Home", right: "\(run.subject) · \(run.kind.label)", onLeft: onClose)
                Spacer(minLength: 12)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(run.isPaused ? "Paused · the clock is stopped" : StudyText.counting(active, rules: rules))
                            .posterLabel()
                        if active >= Double(rules.minMinutes * 60) {
                            PosterSquare(state: .solid, size: 10)
                        }
                    }
                    Text(Poster.tight(StudyText.clock(active), by: -6))
                        .font(.system(size: 112, weight: .heavy))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .contentTransition(.numericText())
                        .padding(.vertical, 10)
                        .opacity(run.isPaused ? 0.45 : 1)
                    StudyTrack(active: active, rules: rules)
                    HStack(spacing: 10) {
                        Button(action: run.isPaused ? onResume : onPause) {
                            StudyOutlineButton(text: run.isPaused ? "Resume" : "Pause")
                        }
                        .buttonStyle(.plain)
                        if run.movedBackS < StudyRun.longestMoveBack, !run.isPaused {
                            Menu {
                                ForEach(StudyText.earlierChoices(movedBack: run.movedBackS), id: \.self) { minutes in
                                    Button("\(minutes) min earlier") { onEarlier(minutes) }
                                }
                            } label: {
                                StudyOutlineButton(text: "Started earlier?")
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 24)
                }
                .padding(.horizontal, Poster.margin)
                Spacer(minLength: 12)
                Button {
                    confirmingDiscard = true
                } label: {
                    Text("Started by mistake? Throw it away").posterLabel().opacity(0.7).padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                Button(action: onEnd) {
                    BreathBar(small: StudyText.toTarget(active, rules: rules), big: "End session", mark: "■", onDark: false)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Poster.green.ignoresSafeArea())
        .task {
            // A timer left running ends itself; look every few seconds.
            while !Task.isCancelled {
                onSettle()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .confirmationDialog("Throw this session away?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Throw it away", role: .destructive, action: onDiscard)
        }
    }
}

/// The way to the target, with the minimum marked.
struct StudyTrack: View {
    let active: TimeInterval
    let rules: StudyRules

    var body: some View {
        let target = Double(max(rules.targetMinutes, 1) * 60)
        let share = min(1, active / target)
        let minimum = min(1, Double(rules.minMinutes * 60) / target)
        VStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Poster.ink).frame(width: geometry.size.width * share)
                    Rectangle().fill(Poster.ink).frame(width: 3, height: 22).offset(x: geometry.size.width * minimum - 1.5)
                }
                .frame(width: geometry.size.width, height: 12, alignment: .leading)
                .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 2.5))
            }
            .frame(height: 12)
            HStack {
                Text("0").posterLabel()
                Spacer()
                Text("\(rules.minMinutes) counts").posterLabel()
                Spacer()
                Text("\(rules.targetMinutes) target").posterLabel()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int(active / 60)) of \(rules.targetMinutes) minutes")
    }
}

struct StudyOutlineButton: View {
    let text: String

    var body: some View {
        Text(text)
            .posterLabel()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 2.5))
            .contentShape(Rectangle())
    }
}

// MARK: Once it ends

struct StudyAfterView: View {
    let run: StudyRun
    let rules: StudyRules
    let week: StudyWeek?
    let onChange: ((inout StudyRun) -> Void) -> Void
    let onDone: () -> Void
    let onDiscard: () -> Void

    @State private var answered = ""
    @State private var right = ""
    @State private var confirmingDiscard = false

    private var ended: Date { run.endedAt ?? run.startedAt }
    private var active: TimeInterval { run.activeSeconds(at: ended) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(StudyText.verdict(run, rules: rules)).posterLabel()
                            Spacer()
                            Text(run.subject).posterLabel().lineLimit(1)
                        }
                        .padding(.top, 14)
                        Text(Poster.tight(StudyText.hoursMinutes(active), by: -6))
                            .font(.system(size: 96, weight: .heavy))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .padding(.vertical, 6)
                        if let week {
                            HStack {
                                Text("This week before it · \(week.done) of \(week.target)").posterLabel()
                                Spacer()
                                HStack(spacing: 5) {
                                    ForEach(0..<week.target, id: \.self) { index in
                                        PosterSquare(state: index < week.done ? .solid : .outline, size: 18)
                                    }
                                }
                            }
                            .padding(.bottom, 14)
                        }
                    }
                    .padding(.horizontal, Poster.margin)
                    .background(Poster.green)
                    PosterRule()
                    if run.endedItself {
                        stoppedItself
                        PosterRule()
                    }
                    Text("What it was").posterLabel().padding(.horizontal, Poster.margin).padding(.top, 12).padding(.bottom, 8)
                    StudyKindChoice(kind: Binding(get: { run.kind }, set: { kind in onChange { $0.kind = kind } }))
                        .padding(.horizontal, Poster.margin)
                        .padding(.bottom, 12)
                    switch run.kind {
                    case .questions:
                        PosterRule(thickness: 2)
                        numberRow("Answered", text: $answered) { value in onChange { $0.answered = value } }
                        PosterRule(thickness: 2)
                        numberRow("Right first time", text: $right) { value in onChange { $0.rightFirst = value } }
                        Text("Both can be left blank. They say whether the hours are working.")
                            .posterLabel().opacity(0.7)
                            .padding(.horizontal, Poster.margin).padding(.top, 10)
                    case .build:
                        PosterRule(thickness: 2)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("What did you build, and why? From memory.").posterLabel()
                            TextField(
                                "", text: Binding(get: { run.explainBack }, set: { text in onChange { $0.explainBack = text } }),
                                prompt: Text("The timer is worked out from the clock, because...").foregroundStyle(Poster.ink.opacity(0.45)),
                                axis: .vertical
                            )
                            .font(.system(size: 17, weight: .semibold))
                            .lineLimit(4...10)
                            .padding(8)
                            .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 2.5))
                            .accessibilityLabel("What you built and why")
                            Text(StudyText.buildNote(rules: rules, week: week)).posterLabel().opacity(0.7)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, Poster.margin)
                        .padding(.top, 12)
                    case .reading:
                        EmptyView()
                    }
                    Button {
                        confirmingDiscard = true
                    } label: {
                        Text("Don't keep this session").posterLabel().opacity(0.7).padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Poster.margin)
                    .padding(.top, 12)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            Button(action: onDone) {
                BreathBar(small: StudyText.barNote(run, rules: rules), big: "Done", mark: "→", onDark: false)
            }
            .buttonStyle(.plain)
        }
        .background(Poster.paper.ignoresSafeArea())
        .onAppear {
            answered = run.answered.map(String.init) ?? ""
            right = run.rightFirst.map(String.init) ?? ""
        }
        .confirmationDialog("Don't keep this session?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Throw it away", role: .destructive, action: onDiscard)
        }
    }

    private var stoppedItself: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Left running, it stopped itself at \(StudyText.hoursMinutes(Double(rules.stopAfterMinutes * 60))). When did you stop?")
                .posterLabel()
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach([0, 30, 60, 90, 120], id: \.self) { minutes in
                    let picked = Int((run.stoppedEarlierBy / 60).rounded()) == minutes
                    Button {
                        onChange { $0.stoppedEarlier(by: TimeInterval(minutes * 60)) }
                    } label: {
                        Text(minutes == 0 ? "Then" : "−\(StudyText.hoursMinutes(Double(minutes * 60)))")
                            .posterLabel()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundStyle(picked ? Poster.paper : Poster.ink)
                            .background(picked ? Poster.ink : Color.clear)
                            .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 2.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(Poster.margin)
    }

    private func numberRow(_ label: String, text: Binding<String>, onValue: @escaping (Int?) -> Void) -> some View {
        HStack {
            Text(label).font(.system(size: 15, weight: .heavy)).textCase(.uppercase)
            Spacer()
            TextField("", text: text, prompt: Text("—"))
                .font(.system(size: 20, weight: .heavy))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                #if os(iOS)
                    .keyboardType(.numberPad)
                #endif
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 2.5))
                .accessibilityLabel(label)
                .onChange(of: text.wrappedValue) { _, value in
                    let digits = value.filter(\.isNumber)
                    if digits != value { text.wrappedValue = digits }
                    onValue(Int(digits.prefix(4)))
                }
        }
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 8)
    }
}
