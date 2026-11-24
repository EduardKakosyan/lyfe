import SwiftUI

/// The head of Worth and of FIRE: on ink like the month's, with the one
/// figure the section leads with.
struct MoneyHead: View {
    /// Beside the way back.
    var top = ""
    var heading: String
    /// Beside the heading.
    var beside = ""
    var figure: String
    var caption: String
    var captionRight = ""
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Button(action: onBack) {
                    Text("← Home").posterLabel().padding(.vertical, 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text(top).posterLabel().lineLimit(1)
            }
            HStack(alignment: .lastTextBaseline) {
                Text(heading).posterHeading()
                Spacer(minLength: 8)
                Text(beside).posterLabel().lineLimit(1).minimumScaleFactor(0.8)
            }
            Text(Poster.tight(figure, by: -5))
                .font(.system(size: 92, weight: .heavy))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .padding(.top, -6)
                .padding(.bottom, -4)
            HStack {
                Text(caption).posterLabel()
                Spacer(minLength: 6)
                Text(captionRight).posterLabel()
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

/// The three things Money shows, side by side under its head: the month,
/// what everything comes to, and the way to financial independence.
struct MoneySections: View {
    let section: MoneySection
    let onSection: (MoneySection) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(MoneySection.allCases, id: \.self) { choice in
                    let chosen = choice == section
                    Button {
                        if !chosen { onSection(choice) }
                    } label: {
                        Text(choice.title)
                            .font(.system(size: 13, weight: .heavy))
                            .tracking(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(chosen ? Poster.paper : Poster.ink)
                            .background(chosen ? Poster.ink : Poster.paper)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            PosterRule()
        }
    }
}

/// Worth: what everything comes to, the line it has drawn since lyfe began
/// keeping it, what it is made of, what the investments are in, and the
/// accounts. The line is one a day from the day it started; before that
/// the bank says nothing.
struct WorthSection: View {
    let worth: MoneyWorth
    /// Asks whether to set an account aside or bring it back.
    let onAccount: (MoneyMonth.Account) -> Void

    var body: some View {
        VStack(spacing: 0) {
            line
            PosterRule()
            StripRow(left: "What it is made of", right: "")
            PosterRule(thickness: 1.5)
            ForEach(WorthText.parts(worth), id: \.name) { part in
                BarRow(title: part.name, figure: MoneyText.amount(part.minor), share: part.share, mark: part.mark)
                PosterRule(thickness: 1.5)
            }
            holdings
            accounts
        }
    }

    @ViewBuilder private var line: some View {
        VStack(alignment: .leading, spacing: 0) {
            if worth.series.count > 1, let first = worth.series.first {
                WorthChart(points: worth.series)
                    .frame(height: 150)
                let span = WorthChartLayout(points: worth.series, size: .zero)
                HStack {
                    Text(WorthText.dayLabel(first.day, in: worth)).posterLabel()
                    Spacer()
                    Text(WorthText.span(low: span.low, high: span.high, currency: worth.currency)).posterLabel()
                        .opacity(0.55)
                    Spacer()
                    Text("Today").posterLabel()
                }
                .padding(.top, 6)
            } else {
                Text(WorthText.lineNote(worth))
                    .posterLabel()
                    .opacity(0.55)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Poster.margin)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WorthText.spoken(worth))
    }

    @ViewBuilder private var holdings: some View {
        if !worth.holdings.isEmpty {
            PosterRule(thickness: 1.5)
            StripRow(
                left: "What the investments are in", right: "\(MoneyText.amount(worth.heldMinor)) \(worth.currency)")
            PosterRule(thickness: 1.5)
            if let paid = worth.paid {
                PaidRow(paid: paid, line: WorthText.paidLine(paid, of: worth))
                PosterRule(thickness: 1.5)
            }
            ForEach(worth.holdings) { holding in
                BarRow(
                    title: WorthText.title(holding), detail: WorthText.holdingDetail(holding, of: worth),
                    line: WorthText.holdingLine(holding), figure: WorthText.value(holding, in: worth.currency),
                    share: WorthText.share(holding, of: worth))
                PosterRule(thickness: 1.5)
            }
            if worth.looseMinor > 0 {
                StripRow(left: "In those accounts and in no holding", right: MoneyText.amount(worth.looseMinor))
                PosterRule(thickness: 1.5)
            }
        }
    }

    @ViewBuilder private var accounts: some View {
        if !worth.accounts.isEmpty {
            PosterRule(thickness: 1.5)
            StripRow(left: "Accounts", right: "Everyday \(MoneyText.amount(worth.everydayMinor)) \(worth.currency)")
            PosterRule(thickness: 1.5)
            TimelineView(.periodic(from: .now, by: 300)) { timeline in
                VStack(spacing: 0) {
                    ForEach(worth.accounts) { account in
                        Button {
                            onAccount(account)
                        } label: {
                            AccountRow(account: account, currency: worth.currency, now: timeline.date)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(account.setAside ? "Brings it back into spending" : "Sets it aside")
                        PosterRule(thickness: 1.5)
                    }
                }
            }
            if worth.accounts.contains(where: \.setAside) {
                StripRow(left: "Set aside", right: "\(MoneyText.amount(worth.setAsideMinor)) \(worth.currency)")
            } else {
                StripRow(left: "Tap savings or investments to set them aside", right: "")
            }
            PosterRule(thickness: 1.5)
        }
    }
}

/// What was paid for the holdings against what they are worth now, as one
/// bar: paid solid, and what it grew by striped, since it is only there
/// until it is sold. A loss is the part of what was paid that is gone, as
/// an outline.
struct PaidRow: View {
    let paid: MoneyWorth.Paid
    let line: String

    var body: some View {
        let bar = WorthText.paidBar(paid)
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { space in
                let gap: CGFloat = bar.solid < 1 ? 2 : 0
                let solid = max(3, (space.size.width - gap) * bar.solid)
                HStack(spacing: gap) {
                    Rectangle().fill(.foreground).frame(width: solid)
                    if bar.solid < 1 {
                        PosterBar(share: 1, mark: bar.grew ? .striped : .outline, height: 18)
                    }
                }
            }
            .frame(height: 18)
            Text(line).posterLabel()
        }
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("What was paid for the holdings against what they are worth: \(line.lowercased())")
    }
}
