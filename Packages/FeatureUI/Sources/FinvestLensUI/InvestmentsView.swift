//
//  InvestmentsView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

import FinvestLensEngine
import FinvestLensReports

/// The Investments hub (`FR-INV-08`) — docs/investments-design.md §6.
///
/// This replaces *Prices & Securities*, which rendered every price row in the
/// book (148,458 of them on the reference book) while seven held securities
/// were the only ones needing a human. Nothing here lists the price database:
/// prices are a precondition, and what a person wants to know is whether the
/// numbers built on them can be trusted.
struct InvestmentsView: View {
    @Bindable var model: AppModel
    /// The portfolio this tab is scoped to — the parent account whose security
    /// accounts it shows — or `nil` for All Holdings.
    ///
    /// One view serves both because "the holdings of this broker" is the same
    /// question as "the holdings" with a narrower answer. A second view would
    /// have to repeat the groups, the sparklines, the worklist and the context
    /// menus, and would drift from them.
    var portfolio: GncGUID?
    @Environment(\.appDateFormat) private var dateFormat
    @State private var expanded: Set<InvestmentGroup> = [.held, .manual]
    @State private var showingQuotes = false
    @State private var showingAddRate = false
    @State private var showingAddWatch = false
    @State private var showingAddPrice = false
    @State private var showingPreview = false
    @State private var targeting: CommodityTarget?
    @State private var cadenceFor: CommodityTarget?
    // A security's page opens as a **tab**, not as a push onto a stack of this
    // view's own.
    //
    // It used to be both: the sidebar's security rows navigate to
    // `.security(key)` and open a tab, while *Get Info* on a holding pushed the
    // very same `SecurityDetailView` onto a private `NavigationPath` — so the
    // same page had a back button or a tab depending on which of two equivalent
    // routes you took, and Investments was the only mode in the app carrying a
    // second navigation model inside a tab. One route now, the one every other
    // mode uses.

    /// The holdings shown, narrowed to the portfolio when this tab has one.
    ///
    /// Filtered here rather than in `investmentRows()` so the memoised build —
    /// lots, returns, allocations, sparkline windows — is done once for the
    /// book and shared by every portfolio tab, instead of once per tab.
    private var rows: [InvestmentRow] {
        let all = model.investmentRows()
        guard let portfolio else { return all }
        let held = model.securityCommodities(inPortfolio: portfolio)
        return all.filter { held.contains($0.commodity) }
    }

    /// The worklist stays book-wide. A stale price or a missing rate is a
    /// problem with the book, not with the broker you happen to be looking at,
    /// and hiding it behind a tab is how it goes unfixed.
    private var issues: [InvestmentIssue] { model.investmentIssues() }

    var body: some View {
        // A stack for the toolbar to hang from — with no path of its own. A
        // holding's page (`FR-INV-15`) is a tab, reached the same way the
        // sidebar reaches it.
        NavigationStack {
            Group {
                if model.securityCommodities.isEmpty && model.watchlist.isEmpty {
                    ContentUnavailableView(
                        "No investments yet", systemImage: "chart.line.uptrend.xyaxis",
                        description: Text("Securities appear here once you hold one, or add one to watch."))
                } else {
                    List {
                        Section { ConfidenceBand(model: model) }
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                        if !issues.isEmpty { worklist }
                        holdings
                        ratesRow
                    }
                }
            }
            .navigationTitle("")
            .onChange(of: model.sidebarCreateRequest) {
                guard model.sidebarCreateRequest == .watchedSecurity else { return }
                model.sidebarCreateRequest = nil
                showingAddWatch = true
            }
            .toolbar { toolbar }
        }
        .sheet(isPresented: $showingQuotes) { QuotesView(model: model) }
        .sheet(isPresented: $showingAddRate) { AddRateSheet(model: model) }
        .sheet(isPresented: $showingAddWatch) { AddWatchSheet(model: model) }
        .sheet(isPresented: $showingAddPrice) { AddPriceSheet(model: model) }
        .sheet(isPresented: $showingPreview) { FetchPreviewSheet(model: model) }
        .sheet(item: $targeting) { target in
            PriceTargetSheet(model: model, commodity: target.commodity)
        }
        .sheet(item: $cadenceFor) { target in
            ValuationCadenceSheet(model: model, commodity: target.commodity)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            // The journey's most frequent task stays one click (⌘⇧U); scope and
            // provider live in the menu, so the common case needs no sheet and
            // the uncommon case needs no separate destination (`FR-INV-22`).
            ControlGroup {
                Button("Update Prices", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await model.updatePrices() }
                }
                .disabled(model.pricableSecurities.isEmpty || model.quoteProgress != nil)
                // A `ControlGroup` renders its buttons icon-only, and a
                // `Button`'s title does not become its accessibility label when
                // the icon is all that is drawn — so this and the menu beside
                // it came back from the accessibility API unnamed.
                .accessibilityLabel("Update Prices")
                .help("Update prices for this book's securities")
                // `slider.horizontal.3`, and neither `chevron.down` nor
                // `ellipsis.circle`. A toolbar `Menu` draws its symbol and
                // drops the title, so a chevron rendered as a lone chevron —
                // a control with no name at all, reported 16 Aug 2026. The
                // ellipsis then collided with the *More* menu beside it: two
                // identical glyphs, adjacent, meaning different things. HIG
                // *Toolbars*: "Make sure the meaning of each control is clear.
                // Don't make people guess or experiment to figure out what a
                // toolbar item does." The ellipsis belongs to More, which is
                // the shape the same page names — "Add a More menu to contain
                // additional actions" — so this one, which adjusts the run the
                // button beside it starts, takes the settings glyph instead.
                Menu("Update Options", systemImage: "slider.horizontal.3") {
                    // Scope, remembered per book (`FR-INV-25`). The default run
                    // used to ask about every security the book had ever held —
                    // 87 on the reference book, 48 of them closed.
                    Picker("Scope", selection: Binding(
                        get: { model.fetchScope }, set: { model.fetchScope = $0 })) {
                        ForEach(FetchScope.allCases) { scope in
                            Text(scope.label).tag(scope)
                        }
                    }
                    Divider()
                    Button("Preview This Run…", systemImage: "list.bullet.rectangle") {
                        showingPreview = true
                    }
                    Divider()
                    ForEach(model.availableProviders) { provider in
                        Button("Update using \(provider.displayName)") {
                            Task { await model.updatePrices(using: provider) }
                        }
                    }
                    Divider()
                    Button("Quote Settings…") { showingQuotes = true }
                }
                .disabled(model.quoteProgress != nil)
                .accessibilityLabel("Update Options")
                .help("Choose the scope or the provider for this run")
            }
        }
        ToolbarItem {
            Menu("More", systemImage: "ellipsis.circle") {
                // **The sparkline period lives here, not in its own toolbar
                // item.** Seen on screen 16 Aug 2026: with the search field in
                // the window title bar and a wide sidebar, macOS pushed both
                // this and the More menu behind the `»` overflow chevron —
                // two controls a person could no longer see at all. HIG
                // *Toolbars* names the remedy: "Add a More menu to contain
                // additional actions", and there already was one.
                //
                // Nothing is lost by moving it. The period is *stated* in the
                // list itself, above the first group ("Prices · 3 months"), so
                // a line's shape is still readable without opening a menu
                // (`FR-INV-12`); only the way to change it moved.
                Picker("Price History", selection: Binding(
                    get: { model.sparkRange }, set: { model.sparkRange = $0 })) {
                    ForEach(AppModel.SparkRange.allCases) { range in
                        Text(range.label).tag(range)
                    }
                }
                .help("How much price history each holding's sparkline covers")
                Divider()
                // Company data for the whole book in one command. Per-security
                // Fetch buttons on each holding's page were the only route,
                // which made filling a portfolio a matter of opening every
                // security in turn.
                Button("Update Company Data", systemImage: "building.columns") {
                    Task { await model.fetchAllFundamentals() }
                }
                .disabled(model.pricableSecurities.isEmpty || model.fundamentalsRun != nil)
                .help("Fetch the profile and financials for every security a provider covers")
                Button("Refetch All Company Data", systemImage: "arrow.clockwise") {
                    Task { await model.fetchAllFundamentals(force: true) }
                }
                .disabled(model.pricableSecurities.isEmpty || model.fundamentalsRun != nil)
                .help("Ignore how recently each was fetched and ask again")
                Divider()
                Button("Watch Security…", systemImage: "eye") { showingAddWatch = true }
                Button("Enter a Price…", systemImage: "plus") { showingAddPrice = true }
                    .disabled(model.pricableSecurities.isEmpty)
                Button("Add Exchange Rate…", systemImage: "dollarsign.arrow.circlepath") {
                    showingAddRate = true
                }
                .disabled(model.currencyCommodities.count < 2)
                Divider()
                Toggle("Show Closed Positions", isOn: Binding(
                    get: { model.showsClosedPositions },
                    set: { model.showsClosedPositions = $0
                           if $0 { expanded.insert(.closed) } }))
            }
        }
    }

    // MARK: Worklist (`FR-INV-13`)

    private var worklist: some View {
        Section("Needs attention") {
            ForEach(issues) { issue in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: issue.kind.symbol)
                        .foregroundStyle(issue.kind.isBlocking ? .red : .orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.kind.title(count: issue.count))
                        Text(issue.symbols.prefix(6).joined(separator: ", ")
                             + (issue.symbols.count > 6 ? "…" : ""))
                            .scaledFont(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if issue.kind.isFetchable {
                        Button("Fetch") { Task { await model.updateAllPrices() } }
                            .buttonStyle(.borderless)
                            .disabled(model.quoteProgress != nil)
                    } else if issue.kind == .manualOverdue {
                        Button("Enter…") { showingAddPrice = true }.buttonStyle(.borderless)
                    } else if issue.kind == .missingRate {
                        Button("Add Rate…") { showingAddRate = true }.buttonStyle(.borderless)
                    } else if issue.kind == .bondProvider {
                        Button("Use FIIG") { model.routeCandidatesToFIIG() }
                            .buttonStyle(.borderless)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Holdings (`FR-INV-11`)

    /// One window for the whole table, read once per body pass.
    private var sparkWindow: ClosedRange<Date> { model.sparkWindow }

    /// The first group with rows on screen — where the period legend goes, so
    /// it is stated once and never lands on an empty book.
    private var firstVisibleGroup: InvestmentGroup? {
        InvestmentGroup.allCases.first { group in
            (group != .closed || model.showsClosedPositions)
                && rows.contains { $0.group == group }
        }
    }

    @ViewBuilder
    private var holdings: some View {
        ForEach(InvestmentGroup.allCases, id: \.self) { group in
            let members = rows.filter { $0.group == group }
            if !members.isEmpty && (group != .closed || model.showsClosedPositions) {
                Section {
                    if expanded.contains(group) {
                        ForEach(members) { row in
                            // The whole row is the link. A holding's own page is
                            // where every question this table raises gets
                            // answered, so reaching it should not require
                            // finding a disclosure chevron.
                            NavigationLink(value: row.commodity) {
                                InvestmentRowView(
                                    row: row, model: model, sparkWindow: sparkWindow,
                                    onTarget: { targeting = CommodityTarget(commodity: row.commodity) },
                                    onCadence: { cadenceFor = CommodityTarget(commodity: row.commodity) },
                                    onOpen: {
                                        model.navigate(to: .security(
                                            SidebarSelection.securityKey(row.commodity)))
                                    })
                            }
                        }
                    }
                } header: {
                    HStack {
                        Button {
                            if expanded.contains(group) { expanded.remove(group) }
                            else { expanded.insert(group) }
                        } label: {
                            HStack {
                                Image(systemName: expanded.contains(group)
                                      ? "chevron.down" : "chevron.right")
                                    .scaledFont(.caption2)
                                Text(group.title)
                                Text("\(members.count)").foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(expanded.contains(group)
                                            ? "Collapse \(group.title), \(members.count) securities"
                                            : "Expand \(group.title), \(members.count) securities")

                        // The period, legible without opening a menu. Outside
                        // the disclosure button so it is not part of that tap
                        // target, and stated once on the first section rather
                        // than repeated over every group.
                        if group == firstVisibleGroup {
                            Text("Prices · \(model.sparkRange.label)")
                                .scaledFont(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Sparklines cover \(model.sparkRange.label)")
                        }
                    }
                }
            }
        }
    }

    // MARK: Exchange rates (`FR-INV-33`)

    private var ratesRow: some View {
        let rates = model.rateHealth()
        return Section("Exchange rates") {
            if rates.currencies == 0 {
                Text("Only \(model.reportCurrency.mnemonic) is in use.")
                    .foregroundStyle(.secondary).scaledFont(.callout)
            } else {
                HStack {
                    Image(systemName: rates.missing.isEmpty
                          ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(rates.missing.isEmpty ? .green : .orange)
                        .accessibilityHidden(true)
                    Text(rates.missing.isEmpty
                         ? "\(rates.priced) of \(rates.currencies) currencies have a rate."
                         : "No rate for \(rates.missing.joined(separator: ", ")) — holdings in it cannot be valued.")
                    Spacer()
                    Button("Add Rate…") { showingAddRate = true }.buttonStyle(.borderless)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - The confidence band (`FR-INV-09`)

/// The three-second answer: what fraction of held **value** is priced as of the
/// exchange's latest trading day, and what the last run did.
private struct ConfidenceBand: View {
    @Bindable var model: AppModel
    @Environment(\.appDateFormat) private var dateFormat

    var body: some View {
        let health = model.priceHealth()
        HStack(alignment: .center, spacing: 16) {
            Gauge(value: health?.valueCoverage ?? 0) {
                EmptyView()
            } currentValueLabel: {
                Text(coverageText(health)).scaledFont(.caption).monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            // `View.tint(_:)` wants a concrete `Color?`, not the `.tint`
            // ShapeStyle — CLAUDE.md ▸ Theming's one sanctioned use of
            // `Color.appAccent`. Never `Color.accentColor`, which ignores the
            // user's chosen tint and paints the system blue.
            .tint(Color.appAccent)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(headline(health)).scaledFont(.headline)
                Text(detail(health)).scaledFont(.caption).foregroundStyle(.secondary)
                Text(runState).scaledFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let progress = model.quoteProgress {
                ProgressView(value: progress).frame(width: 90)
                    .accessibilityLabel("Fetching prices")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(voiceOver(health))
    }

    private func coverageText(_ health: PortfolioPriceHealth?) -> String {
        guard let coverage = health?.valueCoverage else { return "—" }
        return "\(Int((coverage * 100).rounded()))%"
    }

    private func headline(_ health: PortfolioPriceHealth?) -> String {
        guard let health, let coverage = health.valueCoverage else {
            return String(localized: "Nothing held can be valued yet")
        }
        return coverage >= 0.999
            ? String(localized: "Every holding is priced")
            : String(localized: "\(Int((coverage * 100).rounded()))% of portfolio value priced")
    }

    private func detail(_ health: PortfolioPriceHealth?) -> String {
        guard let health else { return "" }
        var parts: [String] = []
        if health.oldCount > 0 {
            parts.append(String(localized: "\(health.oldCount) need a price"))
        }
        if health.missingWhileHeld > 0 {
            parts.append(String(localized: "\(health.securitiesWithHeldGaps) with gaps while held"))
        }
        if parts.isEmpty { parts.append(String(localized: "\(health.heldCount) holdings, all current")) }
        return parts.joined(separator: " · ")
    }

    private var runState: String {
        switch model.quoteStatus {
        case .fetching(let what): return String(localized: "Fetching \(what)…")
        case .failure(let message): return message
        case .success, .idle:
            guard let last = model.lastPriceUpdate else {
                return String(localized: "No prices fetched yet")
            }
            return String(localized: "Last price \(dateFormat.long(last))")
        }
    }

    /// Spoken as one sentence: the ring is decorative, so the numbers it shows
    /// have to be in the label or a VoiceOver user gets nothing.
    private func voiceOver(_ health: PortfolioPriceHealth?) -> String {
        "\(headline(health)). \(detail(health)). \(runState)"
    }
}

// MARK: - One holding

private struct InvestmentRowView: View {
    let row: InvestmentRow
    @Bindable var model: AppModel
    /// Passed in rather than read per row, so every line in the table shares
    /// one time axis and one clock reading.
    let sparkWindow: ClosedRange<Date>
    let onTarget: () -> Void
    let onCadence: () -> Void
    let onOpen: () -> Void
    @Environment(\.appDateFormat) private var dateFormat
    /// The cost column is fixed so the figures line up down the page, and
    /// scaled so they are not truncated when the text is. A plain constant
    /// clipped "1,234,567 units" to "1,234…" at the larger accessibility
    /// sizes — the same class of defect as the dashboard's.
    @ScaledMetric(relativeTo: .body) private var costWidth: CGFloat = 130

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.freshness.symbol)
                .foregroundStyle(row.freshness.style)
                .accessibilityHidden(true)

            // Ahead of the name, at a fixed offset from the leading edge.
            // Sitting after the name it inherited that column's width, and the
            // name column was `minWidth` — so every differing name length put
            // the chart somewhere else and the column visibly wandered down the
            // page. A chart whose whole job is comparison has to be comparable.
            Sparkline(segments: row.spark, window: sparkWindow)
                .frame(width: 72, height: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.symbol).fontWeight(.medium)
                Text(row.name).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minWidth: 90, alignment: .leading)

            Spacer(minLength: 4)

            // What it cost, and what is held — asked for 16 Aug 2026: "each
            // holding row should also show no of units and purchase price (to
            // compare against current value)", then sharpened twice. First:
            // "I asked for Purchase Amount not average price - I can't compare
            // average price with current value", so the figure is a **total**
            // of the same kind as the market value. Then: "having purchase
            // amount at bottom row in small font vs current value in top row is
            // just wrong."
            //
            // Both money totals therefore sit on the **same line at the same
            // size** — cost, then value, left to right — and the two supporting
            // figures line up beneath them: units under the cost, return under
            // the value. What you paid → what it is worth; how many → how it
            // did. A comparison the eye cannot make on one line is not a
            // comparison.
            VStack(alignment: .trailing, spacing: 1) {
                if let paid = row.purchaseAmount {
                    Text("cost \(AmountFormat.string(paid, code: model.reportCurrency.mnemonic))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
                if row.units != 0 {
                    Text("\(DecimalFormat.units(row.units)) units")
                        .scaledFont(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .frame(width: costWidth, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 1) {
                if let value = row.marketValue {
                    Text(AmountFormat.string(value, code: model.reportCurrency.mnemonic))
                        .monospacedDigit()
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
                if let fraction = row.returnFraction {
                    Text(fraction.formatted(.percent.precision(.fractionLength(1))))
                        .scaledFont(.caption).monospacedDigit()
                        .foregroundStyle(fraction < 0 ? Color.negativeAmount : Color.positiveAmount)
                }
            }

            Text(ageText)
                .scaledFont(.caption).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(voiceOver)
        .contextMenu {
            // First, and separated: this is the way to the security's own page,
            // where its name, ticker override, ISIN and price provider are
            // edited. Everything below it is a single setting.
            Button("Get Info", action: onOpen)
            Divider()
            Button("Set Price Target…", action: onTarget)
            // Only where it means something: a security a provider prices is
            // never waiting on a person to value it (`FR-INV-30`).
            if row.group == .manual {
                Button("Valuation Cadence…", action: onCadence)
            }
            // A held security can stop trading without being disposed of — a
            // note is redeemed, a company delists. Its last price is then final
            // rather than late, and nothing should chase it or count it against
            // valuation confidence (`FR-INV-37`).
            Toggle("No Longer Trading", isOn: Binding(
                get: { model.isDelisted(row.commodity) },
                set: { model.setDelisted(row.commodity, $0) }))
            // Separate from the above on purpose. A retail super or
            // managed-fund unit is still trading and its price still moves —
            // there is just no feed, so it is valued from a statement. Saying
            // "no longer trading" instead would freeze it and misreport it.
            Toggle("No Public Price", isOn: Binding(
                get: { model.isUnquoted(row.commodity) },
                set: { model.setUnquoted(row.commodity, $0) }))
                .help("Valued by hand from a statement — never ask a provider for it")
            if model.isWatchOnly(row.commodity) {
                Button("Stop Watching", role: .destructive) {
                    model.removeWatchSecurity(row.commodity)
                }
            }
        }
    }

    private var ageText: String {
        switch row.freshness {
        case .current: return String(localized: "today")
        case .missing: return String(localized: "never")
        case .ceased: return String(localized: "final")
        case .stale, .old: return String(localized: "\(row.tradingDaysBehind)d")
        }
    }

    /// The sparkline is decorative to VoiceOver, so everything it conveys has
    /// to be said here (`FR-INV-12` accessibility).
    private var voiceOver: String {
        var parts = [row.symbol, row.name]
        // The row's own label replaces its children, so anything added to the
        // row has to be added here too or it is silently inaudible — and in
        // the order it is *read*, cost then value, so the comparison the layout
        // makes with the eye is the one the ear gets too.
        if let paid = row.purchaseAmount {
            parts.append(String(localized: "cost \(AmountFormat.string(paid, code: model.reportCurrency.mnemonic))"))
        }
        if row.units != 0 {
            parts.append(String(localized: "\(DecimalFormat.units(row.units)) units"))
        }
        if let value = row.marketValue {
            parts.append(AmountFormat.string(value, code: model.reportCurrency.mnemonic))
        }
        if let fraction = row.returnFraction {
            parts.append(String(localized: "return \(fraction.formatted(.percent.precision(.fractionLength(1))))"))
        }
        parts.append(row.freshness.spokenAge(tradingDaysBehind: row.tradingDaysBehind))
        if row.missingWhileHeld > 0 {
            parts.append(String(localized: "\(row.missingWhileHeld) missing days while held"))
        }
        return parts.joined(separator: ", ")
    }
}

/// A holding's recent price line, drawn as separate segments so a gap in the
/// data reads as a **break** rather than an invented straight line (`FR-INV-12`).
private struct Sparkline: View {
    let segments: [SparkSegment]
    /// The table-wide time axis. Every row is drawn against the same one, so a
    /// horizontal position means the same date in every line.
    let window: ClosedRange<Date>

    var body: some View {
        // The empty case keeps the same 22pt box as a drawn line, with its rule
        // on the vertical centre. Collapsing it to a bare 1pt `Rectangle` let
        // the `HStack` centre a shorter view, so rows without history sat at a
        // different height from rows with it and the column visibly wandered.
        Canvas { context, size in
            let midY = size.height / 2
            guard let value = Self.valueBounds(of: segments) else {
                var rule = Path()
                rule.move(to: CGPoint(x: 0, y: midY))
                rule.addLine(to: CGPoint(x: size.width, y: midY))
                context.stroke(rule, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
                return
            }
            // One expression: a `...` broken across lines parses as a partial
            // range and silently changes the type.
            let from = window.lowerBound.timeIntervalSinceReferenceDate
            let to = max(window.upperBound.timeIntervalSinceReferenceDate, from + 1)
            let bounds = (x: from...to, y: value)
            for segment in segments {
                var path = Path()
                for (index, point) in segment.points.enumerated() {
                    let position = Self.point(point, in: bounds, size: size)
                    if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                }
                context.stroke(path, with: .color(.appAccent), lineWidth: 1.2)
            }
        }
        .drawingGroup()
    }

    /// The value range is still per row: two securities' prices are not
    /// comparable in absolute terms, so each line uses its own vertical scale.
    /// Only the *time* axis is shared — that is the one that has to be.
    private static func valueBounds(of segments: [SparkSegment]) -> ClosedRange<Double>? {
        let values = segments.flatMap(\.points).map(\.value)
        guard let low = values.min(), let high = values.max() else { return nil }
        // A flat series would divide by zero; give it a hair of height so it
        // draws as the horizontal line it is.
        return low...(high > low ? high : low + 1)
    }

    // Drawn by hand rather than with Swift Charts, for two reasons. A `Chart`
    // per row is heavy for a 72×22 line repeated down a long list; and marking
    // the segments as distinct chart series — the only way to stop Charts
    // joining across a gap — requires a `PlottableValue` label, which the
    // string extractor then demands a translation for in eight languages, for
    // text that is never displayed.

    private static func point(_ point: SparkPoint,
                              in bounds: (x: ClosedRange<Double>, y: ClosedRange<Double>),
                              size: CGSize) -> CGPoint {
        let spanX = bounds.x.upperBound - bounds.x.lowerBound
        let spanY = bounds.y.upperBound - bounds.y.lowerBound
        let fractionX = (point.date.timeIntervalSinceReferenceDate - bounds.x.lowerBound) / spanX
        let fractionY = (point.value - bounds.y.lowerBound) / spanY
        // Inset by half the stroke so the extremes are not shaved off by the
        // canvas edge — without it every line's high and low read as clipped,
        // and the top of one row sat flush against the bottom of the next.
        let inset = 1.0
        let usable = max(1, size.height - 2 * inset)
        return CGPoint(x: fractionX * size.width,
                       y: inset + usable - fractionY * usable)   // y grows downward
    }
}

// MARK: - Presentation

private extension InvestmentGroup {
    var title: String {
        switch self {
        case .held: String(localized: "Holdings")
        case .manual: String(localized: "Valued by hand")
        case .watching: String(localized: "Watching")
        case .closed: String(localized: "Closed positions")
        }
    }
}

private extension PriceFreshness {
    /// Shape **and** colour: a band must never be conveyed by colour alone.
    var symbol: String {
        switch self {
        case .current: "circle.fill"
        case .stale: "circle.bottomhalf.filled"
        case .old: "exclamationmark.circle.fill"
        case .missing: "questionmark.circle"
        // Not a warning shape: nothing is wrong with a series that has ended.
        case .ceased: "flag.checkered"
        }
    }

    var style: Color {
        switch self {
        case .current: .green
        case .stale: .orange
        case .old: .red
        case .missing: .secondary
        case .ceased: .secondary
        }
    }

    func spokenAge(tradingDaysBehind: Int) -> String {
        switch self {
        case .current: String(localized: "priced today")
        case .missing: String(localized: "never priced")
        case .stale, .old:
            String(localized: "\(tradingDaysBehind) trading days behind")
        case .ceased: String(localized: "no longer trading, last price is final")
        }
    }
}

private extension InvestmentIssue.Kind {
    var symbol: String {
        switch self {
        case .unpriced: "questionmark.circle.fill"
        case .stale: "clock.badge.exclamationmark.fill"
        case .gaps: "chart.line.downtrend.xyaxis"
        case .manualOverdue: "square.and.pencil"
        case .missingRate: "dollarsign.arrow.circlepath"
        case .bondProvider: "arrow.triangle.branch"
        }
    }

    /// Whether this one makes today's total wrong, rather than history.
    var isBlocking: Bool { self == .unpriced || self == .missingRate }

    /// Whether a fetch is the fix.
    var isFetchable: Bool { self == .unpriced || self == .stale || self == .gaps }

    func title(count: Int) -> String {
        switch self {
        case .unpriced: String(localized: "\(count) holdings have never been priced")
        case .stale: String(localized: "\(count) holdings are more than a trading week behind")
        case .gaps: String(localized: "\(count) holdings have gaps while they were held")
        case .manualOverdue: String(localized: "\(count) hand-valued holdings are out of date")
        case .missingRate: String(localized: "\(count) currencies have no exchange rate")
        case .bondProvider: String(localized: "\(count) holdings have an ISIN and could be priced by FIIG")
        }
    }
}

/// A commodity addressed by a sheet.
///
/// A local wrapper rather than a retroactive `Identifiable` on `Commodity`:
/// conforming another module's type here would claim that conformance for the
/// whole app and collide the day the Engine adds its own.
struct CommodityTarget: Identifiable {
    let commodity: Commodity
    var id: String { "\(commodity.namespace)|\(commodity.mnemonic)" }
}
