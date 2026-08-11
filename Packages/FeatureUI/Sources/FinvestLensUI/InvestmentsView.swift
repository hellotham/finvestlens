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
    @Environment(\.appDateFormat) private var dateFormat
    @State private var expanded: Set<InvestmentGroup> = [.held, .manual]
    @State private var showingQuotes = false
    @State private var showingAddRate = false
    @State private var showingAddWatch = false
    @State private var showingAddPrice = false
    @State private var targeting: CommodityTarget?

    private var rows: [InvestmentRow] { model.investmentRows() }
    private var issues: [InvestmentIssue] { model.investmentIssues() }

    var body: some View {
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
        .navigationTitle("Investments")
        .toolbar { toolbar }
        .sheet(isPresented: $showingQuotes) { QuotesView(model: model) }
        .sheet(isPresented: $showingAddRate) { AddRateSheet(model: model) }
        .sheet(isPresented: $showingAddWatch) { AddWatchSheet(model: model) }
        .sheet(isPresented: $showingAddPrice) { AddPriceSheet(model: model) }
        .sheet(item: $targeting) { target in
            PriceTargetSheet(model: model, commodity: target.commodity)
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
                    Task { await model.updateAllPrices() }
                }
                .disabled(model.pricableSecurities.isEmpty || model.quoteProgress != nil)
                Menu("Update Options", systemImage: "chevron.down") {
                    ForEach(model.availableProviders) { provider in
                        Button("Update using \(provider.displayName)") {
                            Task { await model.updatePriceHistory(using: provider) }
                        }
                    }
                    Divider()
                    Button("Quote Settings…") { showingQuotes = true }
                }
                .disabled(model.quoteProgress != nil)
            }
        }
        ToolbarItem {
            Menu("More", systemImage: "ellipsis.circle") {
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
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Holdings (`FR-INV-11`)

    @ViewBuilder
    private var holdings: some View {
        ForEach(InvestmentGroup.allCases, id: \.self) { group in
            let members = rows.filter { $0.group == group }
            if !members.isEmpty && (group != .closed || model.showsClosedPositions) {
                Section {
                    if expanded.contains(group) {
                        ForEach(members) { row in
                            InvestmentRowView(row: row, model: model,
                                              onTarget: { targeting = CommodityTarget(commodity: row.commodity) })
                        }
                    }
                } header: {
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
    let onTarget: () -> Void
    @Environment(\.appDateFormat) private var dateFormat

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.freshness.symbol)
                .foregroundStyle(row.freshness.style)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.symbol).fontWeight(.medium)
                Text(row.name).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minWidth: 90, alignment: .leading)

            Sparkline(segments: row.spark)
                .frame(width: 72, height: 22)
                .accessibilityHidden(true)

            Spacer(minLength: 4)

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
                        .foregroundStyle(fraction < 0 ? .red : .green)
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
            Button("Set Price Target…", action: onTarget)
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
        case .stale, .old: return String(localized: "\(row.tradingDaysBehind)d")
        }
    }

    /// The sparkline is decorative to VoiceOver, so everything it conveys has
    /// to be said here (`FR-INV-12` accessibility).
    private var voiceOver: String {
        var parts = [row.symbol, row.name]
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

    var body: some View {
        if segments.isEmpty {
            Rectangle().fill(.quaternary).frame(height: 1)
                .accessibilityHidden(true)
        } else {
            Canvas { context, size in
                guard let bounds = Self.bounds(of: segments) else { return }
                for segment in segments {
                    var path = Path()
                    for (index, point) in segment.points.enumerated() {
                        let position = Self.point(point, in: bounds, size: size)
                        if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                    }
                    context.stroke(path, with: .color(.appAccent), lineWidth: 1.2)
                }
            }
        }
    }

    // Drawn by hand rather than with Swift Charts, for two reasons. A `Chart`
    // per row is heavy for a 72×22 line repeated down a long list; and marking
    // the segments as distinct chart series — the only way to stop Charts
    // joining across a gap — requires a `PlottableValue` label, which the
    // string extractor then demands a translation for in eight languages, for
    // text that is never displayed.

    private static func bounds(of segments: [SparkSegment]) -> (x: ClosedRange<Double>, y: ClosedRange<Double>)? {
        let points = segments.flatMap(\.points)
        guard let firstDate = points.map(\.date).min(), let lastDate = points.map(\.date).max(),
              let low = points.map(\.value).min(), let high = points.map(\.value).max()
        else { return nil }
        let x = firstDate.timeIntervalSinceReferenceDate...max(lastDate.timeIntervalSinceReferenceDate,
                                                              firstDate.timeIntervalSinceReferenceDate + 1)
        // A flat series would divide by zero; give it a hair of height so it
        // draws as the horizontal line it is.
        let y = low...(high > low ? high : low + 1)
        return (x, y)
    }

    private static func point(_ point: SparkPoint,
                              in bounds: (x: ClosedRange<Double>, y: ClosedRange<Double>),
                              size: CGSize) -> CGPoint {
        let spanX = bounds.x.upperBound - bounds.x.lowerBound
        let spanY = bounds.y.upperBound - bounds.y.lowerBound
        let fractionX = (point.date.timeIntervalSinceReferenceDate - bounds.x.lowerBound) / spanX
        let fractionY = (point.value - bounds.y.lowerBound) / spanY
        return CGPoint(x: fractionX * size.width,
                       y: size.height - fractionY * size.height)   // y grows downward
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
        }
    }

    var style: Color {
        switch self {
        case .current: .green
        case .stale: .orange
        case .old: .red
        case .missing: .secondary
        }
    }

    func spokenAge(tradingDaysBehind: Int) -> String {
        switch self {
        case .current: String(localized: "priced today")
        case .missing: String(localized: "never priced")
        case .stale, .old:
            String(localized: "\(tradingDaysBehind) trading days behind")
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
