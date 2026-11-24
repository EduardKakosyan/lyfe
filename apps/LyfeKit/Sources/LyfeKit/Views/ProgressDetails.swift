import SwiftUI

struct ProgressHistory: Codable, Equatable, Sendable {
    struct Point: Codable, Equatable, Sendable {
        var day: CalendarDay
        var value: Double
    }
    var pools, swims, tapes, holds: [Point]
    var tapeDue, confirmed: Bool
    var goal: Double?
    var proposedKcal: Int?
}

struct ProgressEntry: Codable, Sendable {
    var kind: String
    var id: UUID?
    var day: CalendarDay?
    var metres, height, waist, neck, hip, pct: Double?
    var kcal: Int?
}

struct ProgressDetails: View {
    let home: HomeSnapshot
    let progress: ProgressHistory
    let save: (ProgressEntry) async -> String?
    @State private var editor: String?
    @State private var note: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Gym weeks").posterHeading()
            Text("This week: \(home.gym.done) of \(home.gym.target) sessions")
            ForEach((home.gym.streak?.recent ?? []).suffix(7).reversed()) { week in
                Text("\(week.startsOn.shortLabel) · \(week.done) sessions · \(week.mark == .awaitingRecovery ? "awaiting recovery" : week.mark.rawValue)")
                    .posterLabel()
            }
            history("Best dry hold per session", progress.holds, "s")
            history("Swim distance · Garmin", progress.swims, "m")
            history("Dynamic apnea distance", progress.pools, "m")
            Button("Enter pool distance") { editor = "pool" }
            history("Body fat · tape estimate", progress.tapes, "%")
            Button(progress.tapeDue ? "Tape measurement due · Enter" : "Enter tape measurement") { editor = "tape" }
            PosterRule()
            Text("Calorie target review").posterHeading()
            Text(progress.goal.map { "Weekly weight goal: \($0.formatted())%" } ?? "Set your weekly weight trend to enable suggestions.")
            Button("Set weekly trend") { editor = "goal" }
            Button(progress.confirmed ? "Food log confirmed today" : "Confirm I logged all food today") {
                submit(ProgressEntry(kind: "confirm", day: home.today))
            }.disabled(progress.confirmed)
            if let kcal = progress.proposedKcal {
                Text("Your weight trend missed your goal for two weeks. Protein stays unchanged.")
                Button("Approve \(kcal) kcal per day") { submit(ProgressEntry(kind: "approve", day: home.today, kcal: kcal)) }
            }
            if let note { Text(note).posterLabel() }
        }
        .padding(Poster.margin).frame(maxWidth: .infinity, alignment: .leading)
        .disabled(saving)
        .sheet(isPresented: Binding(get: { editor != nil }, set: { if !$0 { editor = nil } })) {
            if let editor { ProgressEditor(kind: editor, day: home.today, save: save) }
        }
    }

    private func submit(_ entry: ProgressEntry) {
        saving = true
        Task { note = await save(entry); saving = false }
    }

    @ViewBuilder private func history(_ label: String, _ points: [ProgressHistory.Point], _ unit: String) -> some View {
        PosterRule()
        Text(label).posterHeading()
        if points.isEmpty { Text("No readings in the last eight weeks.").posterLabel() }
        ForEach(Array(points.enumerated()), id: \.offset) { _, point in
            HStack { Text(point.day.shortLabel); Spacer(); Text("\(point.value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)").bold() }.monospacedDigit()
        }
    }
}

private struct ProgressEditor: View {
    let kind: String
    let day: CalendarDay
    let save: (ProgressEntry) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var id = UUID()
    @State private var a = ""
    @State private var b = ""
    @State private var c = ""
    @State private var d = ""
    @State private var useHip = false
    @State private var note: String?
    @State private var saving = false

    private func number(_ text: String) -> Double? { Double(text.replacingOccurrences(of: ",", with: ".")) }

    private var entry: ProgressEntry? {
        guard let first = number(a), first.isFinite else { return nil }
        switch kind {
        case "pool" where first > 0 && first <= 10000: return .init(kind: kind, id: id, day: day, metres: first)
        case "goal" where (-1...1).contains(first): return .init(kind: kind, pct: first)
        case "tape":
            guard let waist = number(b), let neck = number(c), waist > 0, neck > 0, !useHip || number(d) != nil else { return nil }
            return .init(kind: kind, id: id, day: day, height: first, waist: waist, neck: neck, hip: useHip ? number(d) : nil)
        default: return nil
        }
    }

    var body: some View {
        Form {
            Section(kind == "tape" ? "Tape measurements · cm" : kind == "pool" ? "Pool distance" : "Weekly weight trend") {
                if kind == "tape" {
                    Toggle("Use female circumference formula", isOn: $useHip)
                    Text(useHip ? "Measure natural waist and fullest hip." : "Male formula: measure abdomen at the navel.")
                    TextField("Height (cm)", text: $a); TextField("Waist (cm)", text: $b); TextField("Neck (cm)", text: $c)
                    if useHip { TextField("Hip (cm)", text: $d) }
                } else if kind == "pool" { TextField("Distance (metres)", text: $a) }
                else { Text("Percentage per week, from −1 to +1. Use 0 for maintenance."); TextField("Weekly change (%)", text: $a) }
            }
            if let note { Text(note) }
            Button(saving ? "Saving…" : "Save") {
                guard let entry else { return }; saving = true
                Task { note = await save(entry); saving = false; if note == nil { dismiss() } }
            }.disabled(entry == nil || saving)
            Button("Close") { dismiss() }.disabled(saving)
        }.padding().interactiveDismissDisabled(saving)
    }
}
