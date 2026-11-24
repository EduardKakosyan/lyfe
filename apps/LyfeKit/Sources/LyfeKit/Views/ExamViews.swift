import SwiftUI

/// The latest practice tests as squares: solid at the ready score, outline
/// under it, with each score beneath.
struct PracticeSquares: View {
    let exam: ExamView

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if exam.practice.isEmpty {
                Text("No practice tests yet").posterLabel()
            }
            ForEach(exam.practice.suffix(6)) { test in
                VStack(spacing: 4) {
                    PosterSquare(state: test.overReady ? .solid : .outline, size: 18)
                    Text("\(test.score)").font(.system(size: 13, weight: .heavy)).monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GoalText.readiness(exam))
    }
}

/// An exam on its goal's own screen: practice against the ready score, the
/// parts it is marked in, the study behind it, and how a pass lasts.
struct ExamSection: View {
    let goal: Goal
    let exam: ExamView
    let today: CalendarDay
    let onPractice: (PracticeEntry) async -> String?
    let onResult: (Bool, CalendarDay, Int?) async -> String?

    @State private var adding = false
    @State private var score = ""
    @State private var parts: [String: String] = [:]
    @State private var resulting: Bool?
    @State private var resultScore = ""
    @State private var problem: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let problem {
                NoticeRow(text: problem)
                PosterRule()
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Practice · pass mark \(exam.passMark) of \(exam.scaleMax)").posterLabel()
                    Spacer()
                    Text(exam.ready ? "Ready" : "\(exam.inARow) of \(exam.readyRuns) over \(exam.readyAt)").posterLabel()
                }
                PracticeSquares(exam: exam)
            }
            .padding(Poster.margin)
            PosterRule()
            if !exam.domains.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Parts · share").posterLabel()
                        Spacer()
                        Text("Latest practice").posterLabel()
                    }
                    ForEach(exam.domains, id: \.name) { domain in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("\(domain.name) · \(domain.weightPct)%").posterLabel()
                                Spacer()
                                Text(domain.latestPct.map { "\($0)%" } ?? "—").posterLabel()
                            }
                            GeometryReader { geometry in
                                Rectangle().fill(Poster.ink)
                                    .frame(width: geometry.size.width * Double(domain.latestPct ?? 0) / 100)
                                    .frame(width: geometry.size.width, height: 9, alignment: .leading)
                                    .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 2))
                            }
                            .frame(height: 9)
                        }
                    }
                }
                .padding(Poster.margin)
                PosterRule()
            }
            StripRow(left: "Study on it", right: GoalText.figure(Double(exam.minutes), .studyMinutes, weightUnit: "kg"))
            PosterRule(thickness: 2)
            if let validity = GoalText.validity(exam) {
                StripRow(left: "A pass", right: validity)
                PosterRule(thickness: 2)
            }
            if let result = exam.result {
                StripRow(
                    left: result.outcome == "passed" ? "Passed" : "Not passed",
                    right: GoalText.date(result.on) + (result.score.map { " · \($0)" } ?? ""))
                PosterRule(thickness: 2)
            }
            if adding {
                practiceForm
            } else if let passed = resulting {
                resultForm(passed)
            } else if goal.status == .active || goal.status == .parked {
                HStack(spacing: 8) {
                    Button { adding = true } label: { StudyOutlineButton(text: "Add a practice score") }.buttonStyle(.plain)
                    Button { resulting = true } label: { StudyOutlineButton(text: "Passed") }.buttonStyle(.plain)
                    Button { resulting = false } label: { StudyOutlineButton(text: "Not passed") }.buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Poster.margin)
                .padding(.top, Poster.margin)
            }
        }
        .disabled(working)
    }

    private var practiceForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A practice test taken today").posterLabel()
            numberField("Score, out of \(exam.scaleMax)", text: $score)
            ForEach(exam.domains, id: \.name) { domain in
                numberField("\(domain.name) %, if it said", text: Binding(get: { parts[domain.name] ?? "" }, set: { parts[domain.name] = $0 }))
            }
            HStack(spacing: 8) {
                Button {
                    keepPractice()
                } label: {
                    StudyOutlineButton(text: "Keep it")
                }
                .buttonStyle(.plain)
                .disabled(Int(score) == nil)
                Button { adding = false } label: { StudyOutlineButton(text: "Not now") }.buttonStyle(.plain)
            }
        }
        .padding(Poster.margin)
    }

    private func resultForm(_ passed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(passed ? "Passed today. Well done." : "Not passed today. Move its date to the next sitting after.")
                .posterLabel()
                .fixedSize(horizontal: false, vertical: true)
            numberField("Score, if given", text: $resultScore)
            HStack(spacing: 8) {
                Button {
                    keepResult(passed)
                } label: {
                    StudyOutlineButton(text: "Keep it")
                }
                .buttonStyle(.plain)
                Button { resulting = nil } label: { StudyOutlineButton(text: "Not now") }.buttonStyle(.plain)
            }
        }
        .padding(Poster.margin)
    }

    private func numberField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label).posterLabel()
            Spacer()
            TextField("", text: text, prompt: Text("—"))
                .font(.system(size: 18, weight: .heavy))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                #if os(iOS)
                    .keyboardType(.numberPad)
                #endif
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 2.5))
                .accessibilityLabel(label)
        }
    }

    private func keepPractice() {
        guard let points = Int(score) else { return }
        let entry = PracticeEntry(
            takenOn: today, score: points,
            domains: exam.domains.compactMap { domain in
                parts[domain.name].flatMap(Int.init).map { PracticeEntry.Part(name: domain.name, pct: min($0, 100)) }
            })
        working = true
        Task {
            problem = await onPractice(entry)
            working = false
            if problem == nil {
                adding = false
                score = ""
                parts = [:]
            }
        }
    }

    private func keepResult(_ passed: Bool) {
        working = true
        Task {
            problem = await onResult(passed, today, Int(resultScore))
            working = false
            if problem == nil { resulting = nil }
        }
    }
}

/// What an exam is held to, typed once from what its owner publishes.
struct ExamFields: View {
    @Binding var exam: ExamRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Exam") {
                TextField("", text: $exam.name, prompt: Text("Its name"))
                    .font(.system(size: 16, weight: .heavy))
                    .multilineTextAlignment(.trailing)
            }
            row("Pass mark · out of") {
                HStack(spacing: 6) {
                    number($exam.passMark, "720")
                    Text("of").posterLabel()
                    number($exam.scaleMax, "1000")
                }
            }
            row("Ready at · points over it") { number($exam.readyMargin, "30") }
            row("Tests in a row") { number($exam.readyRuns, "3") }
            row("Months a pass is valid") {
                number(Binding(get: { exam.validMonths ?? 0 }, set: { exam.validMonths = $0 > 0 ? $0 : nil }), "36")
            }
            Text("Parts it is marked in · share").posterLabel()
                .padding(.horizontal, Poster.margin).padding(.top, 12).padding(.bottom, 6)
            ForEach(exam.domains.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    TextField("", text: $exam.domains[index].name, prompt: Text("A part"))
                        .font(.system(size: 15, weight: .heavy))
                    number($exam.domains[index].weightPct, "25")
                    Text("%").posterLabel()
                    Button {
                        exam.domains.remove(at: index)
                    } label: {
                        Text("×").font(.system(size: 20, weight: .heavy)).padding(.horizontal, 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Take this part out")
                }
                .padding(.horizontal, Poster.margin)
                .padding(.vertical, 4)
            }
            Button {
                exam.domains.append(ExamRequest.Part(name: "", weightPct: 25))
            } label: {
                StudyOutlineButton(text: "Add a part")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Poster.margin)
            .padding(.vertical, 8)
            Text("Ready means that many practice tests in a row at the pass mark plus the points over it. Any default is a habit, not evidence: set what you trust.")
                .posterLabel().opacity(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Poster.margin)
                .padding(.bottom, 10)
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).posterLabel()
                Spacer(minLength: 8)
                content()
            }
            .padding(.horizontal, Poster.margin)
            .padding(.vertical, 9)
            PosterRule(thickness: 2)
        }
    }

    private func number(_ value: Binding<Int>, _ example: String) -> some View {
        TextField(
            "", text: Binding(get: { value.wrappedValue == 0 ? "" : "\(value.wrappedValue)" }, set: { value.wrappedValue = Int($0.filter(\.isNumber).prefix(5)) ?? 0 }),
            prompt: Text(example)
        )
        .font(.system(size: 17, weight: .heavy))
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
        .frame(width: 64)
        #if os(iOS)
            .keyboardType(.numberPad)
        #endif
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 2.5))
    }
}
