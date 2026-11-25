import SwiftUI

/// Money, in three sections under one head. The month: what its spending
/// comes to across every account, by category, with the entries behind it;
/// money moved between the owner's own accounts is never spending, and the
/// black bar goes through what is still to sort, once for each payee.
/// Worth: what everything comes to, and what the investments are in. FIRE:
/// how far off financial independence is.
public struct MoneyScreen: View {
    let money: MoneyMonth?
    var worth: MoneyWorth?
    var fire: MoneyFire?
    var section: MoneySection = .month
    /// What went wrong fetching what is on screen, if anything.
    var problem: String?
    var loading = false
    let onBack: () -> Void
    /// Shows another month ("2026-10"), or with nil the current one again.
    let onMonth: (String?) async -> Void
    /// Opens the sorting screen on an entry.
    let onSort: (UUID) -> Void
    /// Opens it on the oldest entry still waiting.
    let onSortNext: () -> Void
    /// Sets an account aside or brings it back; answers with what went wrong.
    let onSetAside: (UUID, Bool) async -> String?
    /// Says what currency an account is in, or takes that back with nil.
    var onCurrency: (UUID, String?) async -> String? = { _, _ in nil }
    /// Shows another section.
    var onSection: (MoneySection) -> Void = { _ in }
    /// Fetches the section on screen again, when it is not the month.
    var onReload: () async -> Void = {}
    /// Opens what FIRE assumes.
    var onPlan: () -> Void = {}

    /// The category whose entries are shown; all of them when nil.
    @State private var showing: String?
    @State private var asking: MoneyMonth.Account?
    @State private var note: String?

    public var body: some View {
        Group {
            switch section {
            case .month:
                if let money {
                    if let showing {
                        VStack(alignment: .leading, spacing: 0) {
                            TopLine(left: "← Categories", right: MoneyText.long(money.month)) { self.showing = nil }
                            Text(showing).posterHeading().padding(.horizontal, Poster.margin)
                            if let category = money.categories.first(where: { $0.name == showing }) {
                                Text("\(MoneyText.amount(category.spentMinor)) \(money.currency)").font(.largeTitle.bold()).padding(.horizontal, Poster.margin)
                            }
                            PosterRule()
                            ScrollView { entries(money) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } else { month(money) }
                } else {
                    waiting
                }
            case .worth:
                worthPage
            case .fire:
                firePage
            }
        }
        .foregroundStyle(Poster.ink)
        .background(Poster.paper.ignoresSafeArea())
    }

    private func month(_ money: MoneyMonth) -> some View {
        VStack(spacing: 0) {
            MoneyHeader(money: money, loading: loading, onBack: onBack, onMonth: { month in
                showing = nil
                Task { await onMonth(month) }
            })
            MoneySections(section: section, onSection: onSection)
            ScrollView {
                VStack(spacing: 0) {
                    sourceLine(money.source)
                    ForEach(notices(money.problems, source: money.source), id: \.self) { notice in
                        NoticeRow(text: notice)
                        PosterRule(thickness: 1.5)
                    }
                    categories(money)
                    entries(money)
                }
            }
            .refreshable { await onMonth(money.month) }
            let bar = MoneyText.bar(money)
            if bar.opensSorting {
                Button(action: onSortNext) {
                    BreathBar(small: bar.small, big: bar.big, mark: "→", onDark: false)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Goes through the entries still to sort")
            }
        }
    }

    // MARK: Worth

    private var worthPage: some View {
        VStack(spacing: 0) {
            MoneyHead(
                top: worth.flatMap { worth in worth.recordedSince.map { "KEPT SINCE \(WorthText.dayLabel($0, in: worth))" } } ?? "",
                heading: "Worth", beside: worth.map(WorthText.changeLine) ?? "",
                figure: worth.map { MoneyText.whole($0.worthMinor) } ?? "–",
                caption: worth.map(WorthText.caption) ?? "EVERYTHING ADDED UP", onBack: onBack)
            MoneySections(section: section, onSection: onSection)
            ScrollView {
                VStack(spacing: 0) {
                    if let worth {
                        sourceLine(worth.source)
                        ForEach(notices(worth.problems, source: worth.source), id: \.self) { notice in
                            NoticeRow(text: notice)
                            PosterRule(thickness: 1.5)
                        }
                        WorthSection(worth: worth, onAccount: { asking = $0 })
                    } else {
                        fetching("what everything comes to")
                    }
                }
            }
            .refreshable { await onReload() }
        }
        .confirmationDialog(
            asking.map(MoneyText.asideQuestion) ?? "", isPresented: askingShown, titleVisibility: .visible
        ) {
            if let account = asking {
                Button(account.setAside ? "Bring it back" : "Set it aside") {
                    Task { note = await onSetAside(account.id, !account.setAside) }
                }
                if let choice = MoneyText.currencyChoice(account, totals: totals) {
                    Button(choice.label) {
                        Task { note = await onCurrency(account.id, choice.currency) }
                    }
                }
            }
        } message: {
            if let account = asking, let currency = MoneyText.currencyNote(account, totals: totals) {
                Text(currency)
            }
        }
    }

    /// The currency the totals are in.
    private var totals: String { worth?.currency ?? money?.currency ?? "" }

    private var askingShown: Binding<Bool> {
        Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })
    }

    // MARK: FIRE

    private var firePage: some View {
        let hero = fire.map(FireText.hero) ?? ("–", "OF WHAT CAME IN, KEPT")
        return VStack(spacing: 0) {
            MoneyHead(
                top: fire.map(FireText.basis) ?? "", heading: "FIRE", beside: fire.map(FireText.headline) ?? "",
                figure: hero.0, caption: hero.1, captionRight: fire.map(FireText.when) ?? "", onBack: onBack)
            MoneySections(section: section, onSection: onSection)
            ScrollView {
                VStack(spacing: 0) {
                    if let fire {
                        sourceLine(fire.source)
                        ForEach(notices(fire.problems, source: fire.source), id: \.self) { notice in
                            NoticeRow(text: notice)
                            PosterRule(thickness: 1.5)
                        }
                        FireSection(fire: fire, onPlan: onPlan)
                    } else {
                        fetching("the way to independence")
                    }
                }
            }
            .refreshable { await onReload() }
        }
    }

    // MARK: Shared

    /// Where the figures come from and how fresh they are.
    private func sourceLine(_ status: SourceStatus) -> some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                let source = MoneyText.sourceLine(status, now: timeline.date)
                HStack(spacing: 6) {
                    PosterSquare(state: source.mark, size: 10)
                    Text(source.left).posterLabel()
                    Spacer()
                    Text(loading ? "CHECKING" : source.right).posterLabel()
                }
                .padding(.horizontal, Poster.margin)
                .padding(.vertical, 7)
            }
            PosterRule(thickness: 1.5)
        }
    }

    private func notices(_ problems: [MoneyMonth.Problem], source: SourceStatus) -> [String] {
        var notices: [String] = []
        if let note { notices.append(note) }
        if let problem { notices.append(problem) }
        notices += problems.map(MoneyText.notice)
        if source.state == .notConfigured {
            notices.append("No bank is connected. The server has no SimpleFIN access file.")
        }
        return notices
    }

    /// A section with nothing fetched yet: money is not kept on the phone.
    private func fetching(_ what: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loading ? "Fetching \(what)" : (problem ?? "Fetching \(what)")).posterLabel()
            Button {
                Task { await onReload() }
            } label: {
                Text("Try again").posterLabel().padding(.vertical, 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(problem != nil && !loading ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 18)
    }

    @ViewBuilder private func categories(_ money: MoneyMonth) -> some View {
        if !money.categories.isEmpty {
            StripRow(left: "By category", right: MoneyText.inLine(money))
            PosterRule(thickness: 1.5)
            ForEach(money.categories.sorted { $0.spentMinor != $1.spentMinor ? $0.spentMinor > $1.spentMinor : $0.name < $1.name }) { category in
                Button {
                    showing = category.name
                } label: {
                    CategoryRow(
                        category: category, share: MoneyText.share(category, of: money),
                        detail: MoneyText.categoryDetail(category, of: money), chosen: showing == category.name)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows only its entries")
                PosterRule(thickness: 1.5)
            }
        }
    }

    @ViewBuilder private func entries(_ money: MoneyMonth) -> some View {
        let listed = money.entries.filter { showing == nil || $0.category == showing }
        if !money.entries.isEmpty {
            PosterRule(thickness: 1.5)
            StripRow(left: listed.count == 1 ? "1 transaction" : "\(listed.count) transactions", right: "")
            PosterRule(thickness: 1.5)
            ForEach(listed) { entry in
                Button {
                    onSort(entry.id)
                } label: {
                    MoneyEntryRow(entry: entry, currency: money.currency)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Says what it was")
                PosterRule(thickness: 1.5)
            }
        } else {
            Text(money.current ? "Nothing has posted yet this month. Banks take a day or two." : "Nothing in this month.")
                .posterLabel()
                .opacity(0.55)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Poster.margin)
                .padding(.vertical, 14)
            PosterRule(thickness: 1.5)
        }
    }

    /// Nothing fetched yet: money is not kept on the phone.
    private var waiting: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onBack) {
                Text("← Home").posterLabel().padding(.vertical, 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Text("MONEY")
                .font(.system(size: 72, weight: .heavy))
                .tracking(-3)
            Text(loading ? "Fetching the month" : (problem ?? "Fetching the month")).posterLabel()
            Spacer()
            Button {
                Task { await onMonth(nil) }
            } label: {
                Text("Try again").posterLabel().padding(.vertical, 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(problem != nil && !loading ? 1 : 0)
        }
        .padding(.horizontal, Poster.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// The month and what was spent in it, on ink: money has no streak and so
/// no colour of its own.
struct MoneyHeader: View {
    let money: MoneyMonth
    var loading = false
    let onBack: () -> Void
    let onMonth: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Button(action: onBack) {
                    Text("← Home").posterLabel().padding(.vertical, 12).contentShape(Rectangle())
                }
                Spacer()
                if let earlier = money.earlier {
                    Button {
                        onMonth(earlier)
                    } label: {
                        Text("← \(MoneyText.short(earlier))").posterLabel().padding(.vertical, 12).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Earlier: \(MoneyText.long(earlier))")
                }
                Text(MoneyText.long(money.month)).posterLabel()
                if let later = money.later {
                    Button {
                        onMonth(later)
                    } label: {
                        Text("\(MoneyText.short(later)) →").posterLabel().padding(.vertical, 12).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Later: \(MoneyText.long(later))")
                }
            }
            .buttonStyle(.plain)
            .disabled(loading)
            HStack(alignment: .lastTextBaseline) {
                Text("Money").posterHeading()
                Spacer()
                Text(MoneyText.comparison(money)).posterLabel()
            }
            Text(Poster.tight(MoneyText.whole(money.spentMinor), by: -5))
                .font(.system(size: 92, weight: .heavy))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .padding(.top, -6)
                .padding(.bottom, -4)
            HStack {
                Text(MoneyText.caption(money)).posterLabel()
                Spacer(minLength: 6)
                if money.toSort > 0 {
                    Text("\(money.toSort) to sort").posterLabel()
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, Poster.margin)
        .foregroundStyle(Poster.paper)
        .background(Poster.ink.ignoresSafeArea(edges: .top))
        .accessibilityElement(children: .contain)
    }
}

/// A category: its name, what went on it, and a bar against the largest.
struct CategoryRow: View {
    let category: MoneyMonth.Category
    /// 0 to 1, against the month's largest category.
    let share: Double
    let detail: String
    var chosen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(category.name)
                    .font(.system(size: 15, weight: .heavy))
                    .tracking(-0.3)
                    .textCase(.uppercase)
                Text(detail).posterLabel().opacity(0.6)
                Spacer(minLength: 8)
                Text(MoneyText.amount(category.spentMinor))
                    .font(.system(size: 15, weight: .heavy))
                    .monospacedDigit()
            }
            GeometryReader { space in
                Rectangle().fill(.foreground).frame(width: max(3, space.size.width * share))
            }
            .frame(height: 10)
        }
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 9)
        .foregroundStyle(chosen ? Poster.paper : Poster.ink)
        .background(chosen ? Poster.ink : Poster.paper)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(category.name): \(MoneyText.amount(category.spentMinor))")
    }
}

/// One entry: solid once sorted, outline while it waits, striped and dim
/// when it is not spending at all.
struct MoneyEntryRow: View {
    let entry: MoneyMonth.Entry
    let currency: String

    var body: some View {
        let mark = MoneyText.mark(entry)
        HStack(spacing: 10) {
            PosterSquare(state: mark, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 15, weight: .heavy))
                    .tracking(-0.3)
                    .textCase(.uppercase)
                    .lineLimit(1)
                Text(MoneyText.detail(entry)).posterLabel().lineLimit(2).multilineTextAlignment(.leading)
            }
            Spacer(minLength: 8)
            Text(MoneyText.figure(entry, in: currency))
                .font(.system(size: 15, weight: .heavy))
                .monospacedDigit()
        }
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 9)
        .opacity(mark == .striped ? 0.45 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.name), \(MoneyText.figure(entry, in: currency)), \(MoneyText.what(entry).lowercased())")
    }
}

struct AccountRow: View {
    let account: MoneyMonth.Account
    let currency: String
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            PosterSquare(
                state: account.problem != nil || account.stale ? .striped : (account.setAside ? .outline : .solid),
                size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.system(size: 15, weight: .heavy))
                    .tracking(-0.3)
                    .textCase(.uppercase)
                    .lineLimit(1)
                Text(MoneyText.accountDetail(account, now: now)).posterLabel().lineLimit(2).multilineTextAlignment(.leading)
            }
            Spacer(minLength: 8)
            Text(MoneyText.balance(account, in: currency))
                .font(.system(size: 15, weight: .heavy))
                .monospacedDigit()
        }
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(account.name), \(MoneyText.balance(account, in: currency))")
    }
}

// MARK: Sorting an entry

/// What was it? One entry, giant, and a tap on what it was. Said once, it
/// holds for every entry from the same payee, so a month is sorted in a
/// few taps and the next one in fewer.
public struct SortEntryView: View {
    let entry: MoneyMonth.Entry
    /// The categories on offer, in the backend's order.
    let categories: [String]
    let currency: String
    /// How many entries are still waiting, this one included.
    var waiting = 0
    /// Answers with what went wrong, or nil.
    let onSort: (MoneyChoice, Bool) async -> String?
    let onClose: () -> Void

    @State private var onlyThis = false
    @State private var busy = false
    @State private var note: String?

    private let columns = [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)]

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button(action: onClose) {
                        Text("✕ Close").posterLabel().padding(.vertical, 12).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text(waiting > 1 && entry.toSort ? "\(waiting) to sort" : MoneyText.what(entry)).posterLabel()
                }
                Text(entry.name).posterHeading().lineLimit(2).minimumScaleFactor(0.7)
                Text("\(entry.day.posterLabel) · \(entry.account.uppercased())").posterLabel().padding(.top, 3)
                Text(Poster.tight(MoneyText.figure(entry, in: currency), by: -4))
                    .font(.system(size: 76, weight: .heavy))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .padding(.bottom, 4)
            }
            .padding(.horizontal, Poster.margin)
            .padding(.bottom, 6)
            .foregroundStyle(Poster.paper)
            .background(Poster.ink.ignoresSafeArea(edges: .top))

            ScrollView {
                VStack(spacing: 0) {
                    Button {
                        onlyThis.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            PosterSquare(state: onlyThis || !entry.hasPayee ? .outline : .solid, size: 14)
                            Text(MoneyText.scope(entry, onlyThis: onlyThis)).posterLabel().multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Poster.margin)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!entry.hasPayee)
                    .accessibilityHint("Switches between this payee and this one entry")
                    PosterRule()
                    if let note {
                        NoticeRow(text: note)
                        PosterRule(thickness: 1.5)
                    }
                    // Money in is most often pay or a transfer, so those
                    // come first; a category then means money back.
                    if entry.amountMinor > 0 {
                        notSpending
                        PosterRule()
                        StripRow(left: "Or money back for something bought", right: "")
                        PosterRule(thickness: 1.5)
                        spending
                    } else {
                        spending
                        PosterRule()
                        StripRow(left: "Or not spending at all", right: "")
                        PosterRule(thickness: 1.5)
                        notSpending
                    }
                    if entry.sortedBy == .owner || entry.sortedBy == .rule {
                        PosterRule()
                        Button {
                            pick(.unsorted)
                        } label: {
                            StripRow(left: "Take back what was said", right: "Unsort →")
                        }
                        .buttonStyle(.plain)
                    }
                    PosterRule(thickness: 1.5)
                }
            }
        }
        .foregroundStyle(Poster.ink)
        .background(Poster.paper.ignoresSafeArea())
        .disabled(busy)
        // A new entry starts with the payee's switch where it began.
        .onChange(of: entry.id) { _, _ in
            onlyThis = false
            note = nil
        }
    }

    private var spending: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(categories, id: \.self) { name in
                choice(name, .category(name), chosen: entry.category == name && !entry.toSort)
            }
        }
    }

    /// Side by side when money in is on offer; else the full width.
    private var notSpending: some View {
        HStack(spacing: 0) {
            if entry.amountMinor > 0 {
                choice("Money in", .income, chosen: entry.kind == .income && !entry.toSort, detail: "Pay, interest")
            }
            choice("Moved", .transfer, chosen: entry.kind == .transfer, detail: "Between my accounts")
        }
    }

    private func choice(_ title: String, _ choice: MoneyChoice, chosen: Bool, detail: String? = nil) -> some View {
        Button {
            pick(choice)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).posterHeading(18).lineLimit(1).minimumScaleFactor(0.7)
                if let detail {
                    Text(detail).posterLabel().opacity(0.6).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .padding(.horizontal, Poster.margin)
            .padding(.vertical, 11)
            .foregroundStyle(chosen ? Poster.paper : Poster.ink)
            .background(chosen ? Poster.ink : Poster.paper)
            .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 0.75))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func pick(_ choice: MoneyChoice) {
        guard !busy else { return }
        busy = true
        Task {
            note = await onSort(choice, onlyThis || !entry.hasPayee)
            busy = false
        }
    }
}

/// The way to Money from Home, with the month as it stands.
struct MoneyStrip: View {
    let glance: MoneyGlance

    var body: some View {
        HStack {
            Text(MoneyText.homeLine(glance)).posterLabel()
            Spacer()
            Text("Money →").posterLabel()
        }
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
