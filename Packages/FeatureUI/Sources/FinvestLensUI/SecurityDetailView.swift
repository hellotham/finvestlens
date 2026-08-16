//
//  SecurityDetailView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Charts
import SwiftUI
import UniformTypeIdentifiers

import FinvestLensEngine
import FinvestLensQuotes
import FinvestLensReports

/// Surface B of the Investments hub (`FR-INV-15`) — docs/investments-design.md §7.
///
/// One scrolling page with sections, not tabs: an ASX share, a bond and a super
/// fund want different things said about them, and a tab bar would make every
/// one of them look the same before you had read a word.
struct SecurityDetailView: View {
    @Bindable var model: AppModel
    let commodity: Commodity

    @Environment(\.appDateFormat) private var dateFormat
    /// True when this is a tab in the detail pane rather than a sheet — the tab
    /// strip is then already saying the security's name, so the window title
    /// must not say it a second time.
    @Environment(\.isEmbeddedDestination) private var embedded
    @State private var range: DetailRange = .year
    @State private var exportingCSV = false
    @State private var importingCSV = false
    @State private var showingTarget = false
    @State private var showingAddPrice = false
    @State private var showingEdit = false
    @State private var confirmingDelete: SecurityPriceRow?

    private var detail: SecurityDetail? { model.securityDetail(for: commodity) }
    private var code: String { model.reportCurrency.mnemonic }

    var body: some View {
        List {
            if let detail {
                header(detail)
                performance(detail)
                chart(detail)
                profile
                financials
                declaredDividends
                checks
                activity(detail)
                lots(detail)
                prices(detail)
                settings(detail)
            } else {
                ContentUnavailableView("Nothing recorded yet", systemImage: "chart.xyaxis.line",
                                       description: Text("This security has no prices or transactions in this book."))
            }
        }
        .navigationTitle(embedded ? "" : commodity.mnemonic)
        .toolbar { toolbar }
        .sheet(isPresented: $showingTarget) { PriceTargetSheet(model: model, commodity: commodity) }
        .sheet(isPresented: $showingAddPrice) { AddPriceSheet(model: model, commodity: commodity) }
        .sheet(isPresented: $showingEdit) { EditSecuritySheet(model: model, commodity: commodity) }
        .fileExporter(isPresented: $exportingCSV,
                      document: CSVFileDocument(text: model.priceCSV(for: commodity)),
                      contentType: .commaSeparatedText,
                      defaultFilename: model.priceCSVFilename(for: commodity)) { _ in }
        // `importPrices(csv:)` satisfies `FR-XIO-03` and had no caller at all —
        // the export half of the pair was wired and the import half was not.
        // It reads a whole file, so it fills any security the file names, not
        // just this one; the toast says how many landed and what was skipped.
        .fileImporter(isPresented: $importingCSV,
                      allowedContentTypes: [.commaSeparatedText, .text]) { result in
            guard case let .success(url) = result else { return }
            importPrices(from: url)
        }
        .confirmationDialog("Delete this price?", isPresented: Binding(
            get: { confirmingDelete != nil },
            set: { if !$0 { confirmingDelete = nil } }), presenting: confirmingDelete) { row in
            Button("Delete Price", role: .destructive) {
                model.deletePrice(row.id)
                confirmingDelete = nil
            }
        } message: { row in
            Text("\(dateFormat.long(row.date)) · \(AmountFormat.string(row.value, code: row.currencyCode))")
        }
    }

    /// Reads a price CSV and reports what it did — including what it refused.
    ///
    /// The refusals matter as much as the count. A row naming a currency the
    /// book does not know is skipped rather than relabelled into the base
    /// currency, which is the same mislabel the fetch path now refuses.
    private func importPrices(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            model.showToast(.failure, String(localized: "Couldn't read that file."))
            return
        }
        let outcome = model.importPrices(csv: text)
        if outcome.unrecognisedFormat {
            model.showToast(.failure, String(localized: "That file's columns weren't recognised."))
            return
        }
        var detail: [String] = []
        if !outcome.unmatchedSymbols.isEmpty {
            detail.append(String(localized: "\(outcome.unmatchedSymbols.count) unknown symbols"))
        }
        if !outcome.unknownCurrencies.isEmpty {
            detail.append(String(localized: "\(outcome.unknownCurrencies.count) unknown currencies"))
        }
        let skipped = detail.joined(separator: ", ")
        model.showToast(outcome.imported > 0 ? .success : .info,
                        skipped.isEmpty
                            ? String(localized: "Imported \(outcome.imported) prices.")
                            : String(localized: "Imported \(outcome.imported) prices — skipped \(skipped)."))
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            // Fetch scope for **this** security (`FR-INV-23`). Fill is the safe
            // default and sits on the button; replace is destructive-adjacent
            // and lives in the menu with what it does spelled out.
            ControlGroup {
                Button("Update", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await model.updatePrices(for: commodity) }
                }
                .disabled(model.quoteProgress != nil)
                Menu("Fetch Options", systemImage: "chevron.down") {
                    Button("Rebuild History from Scratch") {
                        Task { await model.refetchPrices(for: commodity) }
                    }
                    if model.availableProviders.count > 1 {
                        Divider()
                        ForEach(model.availableProviders) { provider in
                            Button("Update using \(provider.displayName)") {
                                Task { await model.updatePrices(for: commodity, using: provider) }
                            }
                        }
                    }
                }
                .disabled(model.quoteProgress != nil)
            }
        }
        ToolbarItem {
            Menu("More", systemImage: "ellipsis.circle") {
                Button("Enter a Price…", systemImage: "plus") { showingAddPrice = true }
                Button("Set Price Target…", systemImage: "target") { showingTarget = true }
                Divider()
                // `EditSecuritySheet` existed and was presented from nowhere, so
                // `renameSecurity` — the only way to correct a security's name
                // across every holding that shares it — could not be reached.
                Button("Edit Security…", systemImage: "pencil") { showingEdit = true }
                Divider()
                Button("Import Prices…", systemImage: "square.and.arrow.down") { importingCSV = true }
                Button("Export Prices…", systemImage: "square.and.arrow.up") { exportingCSV = true }
                Divider()
                Toggle("No Longer Trading", isOn: Binding(
                    get: { model.isDelisted(commodity) },
                    set: { model.setDelisted(commodity, $0) }))
                // Clears the cached profile and statements so the next fetch
                // rebuilds them — the fix for a sidecar that cached a wrong
                // match, and until now callable only from a test.
                Button("Clear Cached Fundamentals", systemImage: "trash",
                       role: .destructive) {
                    model.clearFundamentals(for: commodity)
                }
            }
        }
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ detail: SecurityDetail) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(commodity.fullName).scaledFont(.title3).fontWeight(.semibold)
                Text(subtitle(detail)).scaledFont(.caption).foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let price = detail.latestPrice {
                        Text(AmountFormat.string(price, code: code))
                            .scaledFont(.title2).monospacedDigit()
                    } else {
                        Text("No price").scaledFont(.title2).foregroundStyle(.secondary)
                    }
                    if let change = detail.priceChangeFraction {
                        Label(change.formatted(.percent.precision(.fractionLength(2))),
                              systemImage: change < 0 ? "arrow.down.right" : "arrow.up.right")
                            .scaledFont(.callout).monospacedDigit()
                            .foregroundStyle(change < 0 ? Color.negativeAmount : Color.positiveAmount)
                            .labelStyle(.titleAndIcon)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(priceVoiceOver(detail))

                // The position, in the order a person reads it: how much of the
                // thing, what it is worth, what share of the portfolio, and what
                // it cost — the last being the only one that makes the others
                // mean anything.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) { positionFacts(detail) }
                    VStack(alignment: .leading, spacing: 6) { positionFacts(detail) }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func positionFacts(_ detail: SecurityDetail) -> some View {
        if detail.units != 0 {
            fact("Units", DecimalFormat.units(detail.units))
        }
        if let value = detail.marketValue {
            fact("Value", AmountFormat.string(value, code: code))
        }
        if let allocation = detail.allocation {
            fact("Allocation", allocation.formatted(.percent.precision(.fractionLength(1))))
        }
        if let average = detail.averageCost {
            fact("Average cost", AmountFormat.string(average, code: code))
        }
    }

    private func fact(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).scaledFont(.caption2).foregroundStyle(.secondary)
            Text(value).scaledFont(.callout).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ detail: SecurityDetail) -> String {
        var parts: [String] = []
        if case let .security(exchange) = commodity.namespace { parts.append(exchange) }
        parts.append(code)
        if let identifier = model.exchangeCode(for: commodity).nilIfEmpty { parts.append(identifier) }
        if let date = detail.latestPriceDate {
            parts.append(String(localized: "priced \(dateFormat.long(date))"))
        }
        return parts.joined(separator: " · ")
    }

    private func priceVoiceOver(_ detail: SecurityDetail) -> String {
        guard let price = detail.latestPrice else { return String(localized: "No price recorded") }
        var spoken = AmountFormat.string(price, code: code)
        if let change = detail.priceChangeFraction, let previous = detail.previousPriceDate {
            spoken += ", " + String(localized: "\(change.formatted(.percent.precision(.fractionLength(2)))) since \(dateFormat.long(previous))")
        }
        return spoken
    }

    // MARK: Performance

    @ViewBuilder
    private func performance(_ detail: SecurityDetail) -> some View {
        if detail.costBasis != 0 || detail.income != 0 || detail.realizedGain != 0 {
            Section("Performance") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    figureRow("Return since holding",
                              detail.returnFraction.map {
                                  $0.formatted(.percent.precision(.fractionLength(1)))
                              },
                              tint: detail.returnFraction.map { $0 < 0 ? Color.negativeAmount : Color.positiveAmount })
                    figureRow("Unrealised", detail.unrealizedGain.map { AmountFormat.string($0, code: code) },
                              tint: detail.unrealizedGain.map { $0 < 0 ? Color.negativeAmount : Color.positiveAmount })
                    figureRow("Realised", AmountFormat.string(detail.realizedGain, code: code),
                              tint: detail.realizedGain < 0 ? Color.negativeAmount : nil)
                    figureRow("Income", AmountFormat.string(detail.income, code: code))
                    figureRow("Yield on cost",
                              detail.yieldOnCost.map { $0.formatted(.percent.precision(.fractionLength(2))) })
                    figureRow("Cost basis", AmountFormat.string(detail.costBasis, code: code))
                }
            }
        }
    }

    @ViewBuilder
    private func figureRow(_ label: LocalizedStringKey, _ value: String?,
                           tint: Color? = nil) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value ?? "—")
                .monospacedDigit()
                .foregroundStyle(value == nil ? AnyShapeStyle(.secondary)
                                              : AnyShapeStyle(tint ?? .primary))
                .gridColumnAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: The price chart (`FR-INV-16`)

    @ViewBuilder
    private func chart(_ detail: SecurityDetail) -> some View {
        Section {
            let window = range.window(for: detail)
            let points = detail.prices.filter { window.contains($0.date) }
            if points.count < 2 {
                Text("Not enough price history to draw a chart for this period.")
                    .scaledFont(.callout).foregroundStyle(.secondary)
            } else {
                PriceHistoryChart(detail: detail, window: window, points: points,
                                  currencyCode: code)
                    .frame(height: 220)
                    .padding(.vertical, 4)
                chartLegend(detail, window: window)
            }
        } header: {
            HStack {
                Text("Price history")
                Spacer()
                Picker("Period", selection: $range) {
                    ForEach(DetailRange.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Chart period")
            }
        }
    }

    /// The chart's marks named in words, because colour and shape alone do not
    /// survive a monochrome display or a screen reader.
    @ViewBuilder
    private func chartLegend(_ detail: SecurityDetail, window: ClosedRange<Date>) -> some View {
        let events = detail.events.filter { window.contains($0.date) && $0.kind != .income }
        let buys = events.filter { $0.kind == .buy }.count
        let sells = events.filter { $0.kind == .sell }.count
        HStack(spacing: 12) {
            legendMark("Price", symbol: "minus", colour: .appAccent)
            if buys > 0 { legendMark("Bought", symbol: "triangle.fill", colour: .green) }
            if sells > 0 { legendMark("Sold", symbol: "triangle.fill", colour: .red) }
            if detail.averageCost != nil {
                legendMark("Average cost", symbol: "minus", colour: .secondary)
            }
            if !detail.holdingPeriods.isEmpty {
                legendMark("Held", symbol: "square.fill", colour: .appAccent.opacity(0.12))
            }
        }
        .scaledFont(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(chartVoiceOver(detail, window: window, buys: buys, sells: sells))
    }

    private func legendMark(_ label: LocalizedStringKey, symbol: String, colour: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).foregroundStyle(colour).accessibilityHidden(true)
            Text(label)
        }
    }

    /// A chart is invisible to VoiceOver, so its whole content is spoken here:
    /// the range of the line, and what the markers on it are.
    private func chartVoiceOver(_ detail: SecurityDetail, window: ClosedRange<Date>,
                                buys: Int, sells: Int) -> String {
        let inWindow = detail.prices.filter { window.contains($0.date) }
        var parts: [String] = []
        if let low = inWindow.map(\.value).min(), let high = inWindow.map(\.value).max() {
            parts.append(String(localized: "Price from \(AmountFormat.string(low, code: code)) to \(AmountFormat.string(high, code: code)) over \(range.label)"))
        }
        if buys > 0 { parts.append(String(localized: "\(buys) purchases marked")) }
        if sells > 0 { parts.append(String(localized: "\(sells) sales marked")) }
        if let average = detail.averageCost {
            parts.append(String(localized: "average cost \(AmountFormat.string(average, code: code))"))
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Company data, fetched and cached outside the book (`FR-INV-35`)

    /// Read fresh on each body pass, keyed on `fundamentalsRevision` so a fetch
    /// that lands on disk actually redraws the page.
    private var cached: SecurityFundamentals? {
        _ = model.fundamentalsRevision
        return model.fundamentals(for: commodity)
    }

    @ViewBuilder
    private var profile: some View {
        Section {
            if let stamped = cached?.profile, !stamped.value.isEmpty {
                let shown = stamped.value
                VStack(alignment: .leading, spacing: 8) {
                    // A bond's profile is a different set of facts, and better
                    // ones than an equity service could give (§7).
                    if shown.isFixedIncome {
                        bondFacts(shown)
                    } else {
                        equityFacts(shown)
                    }
                    if let summary = shown.summary, !summary.isEmpty {
                        Text(summary).scaledFont(.callout).foregroundStyle(.secondary)
                    }
                    if let website = shown.website, let url = URL(string: website) {
                        Link(website, destination: url).scaledFont(.caption)
                    }
                }
                .padding(.vertical, 2)
            } else {
                unavailable(.profile)
            }
        } header: {
            sectionHeader("Profile", stamp: cached?.profile.map { ($0.source, $0.fetchedAt) })
        }
    }

    @ViewBuilder
    private func equityFacts(_ shown: SecurityProfile) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) { equityFactItems(shown) }
            VStack(alignment: .leading, spacing: 6) { equityFactItems(shown) }
        }
    }

    @ViewBuilder
    private func equityFactItems(_ shown: SecurityProfile) -> some View {
        if let sector = shown.sector { fact("Sector", sector) }
        if let industry = shown.industry { fact("Industry", industry) }
        if let cap = shown.marketCap {
            fact("Market capitalisation", AmountFormat.string(cap, code: shown.currencyCode ?? code))
        }
        if let employees = shown.employees {
            fact("Employees", employees.formatted(.number))
        }
        if let ratio = shown.trailingPE {
            fact("Price to earnings", ratio.formatted(.number.precision(.fractionLength(1))))
        }
    }

    @ViewBuilder
    private func bondFacts(_ shown: SecurityProfile) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) { bondFactItems(shown) }
            VStack(alignment: .leading, spacing: 6) { bondFactItems(shown) }
        }
    }

    @ViewBuilder
    private func bondFactItems(_ shown: SecurityProfile) -> some View {
        if let issuer = shown.issuer { fact("Issuer", issuer) }
        if let rate = shown.couponRate {
            // Stored as a fraction (0.04), read by a person as a percentage.
            fact("Coupon", NSDecimalNumber(decimal: rate).doubleValue
                .formatted(.percent.precision(.fractionLength(0...3))))
        }
        if let frequency = shown.couponFrequency { fact("Paid", frequency) }
        if let maturity = shown.maturityDate { fact("Matures", dateFormat.long(maturity)) }
        if let call = shown.callDate { fact("Callable from", dateFormat.long(call)) }
        if let yield = shown.yieldToMaturity {
            fact("Yield", yield.formatted(.percent.precision(.fractionLength(2))))
        }
    }

    @ViewBuilder
    private var financials: some View {
        let periods = cached?.statements?.value ?? []
        if !periods.isEmpty || cached?.profile?.value.isFixedIncome != true {
            Section {
                if periods.isEmpty {
                    unavailable(.statements)
                } else {
                    ForEach(FinancialPeriod.Statement.allCases, id: \.self) { statement in
                        let rows = periods.filter { $0.statement == statement }
                        if !rows.isEmpty {
                            DisclosureGroup(statement.title) {
                                StatementTable(periods: rows, currencyCode: code)
                            }
                        }
                    }
                }
            } header: {
                sectionHeader("Financials",
                              stamp: cached?.statements.map { ($0.source, $0.fetchedAt) })
            }
        }
    }

    @ViewBuilder
    private var declaredDividends: some View {
        let declared = cached?.dividends?.value ?? []
        if !declared.isEmpty {
            Section {
                // Newest first, and only the last few years: the point is the
                // recent run rate, and a twenty-year list buries it.
                ForEach(declared.suffix(24).reversed()) { dividend in
                    HStack {
                        Text(dateFormat.long(dividend.date))
                        Spacer()
                        Text(AmountFormat.string(dividend.amount, code: code))
                            .monospacedDigit()
                        Text("per unit").scaledFont(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                sectionHeader("Declared dividends",
                              stamp: cached?.dividends.map { ($0.source, $0.fetchedAt) })
            } footer: {
                Text("What the issuer declared per unit. What your book recorded is under Your transactions.")
                    .scaledFont(.caption2)
            }
        }
    }

    /// A section header carrying its own provenance — the design's "always
    /// stamped with the source and an as-of date" (§7).
    private func sectionHeader(_ title: LocalizedStringKey,
                               stamp: (source: String, at: Date)?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let stamp {
                Text("\(stamp.source) · \(dateFormat.long(stamp.at))")
                    .scaledFont(.caption2).foregroundStyle(.secondary)
            }
            Button("Refetch") { Task { await model.fetchFundamentals(for: commodity, force: true) } }
                .buttonStyle(.borderless)
                .scaledFont(.caption)
                .disabled(model.fundamentalsStatus(for: commodity) == .fetching)
                // Three sections each carry a Refetch, and a VoiceOver user
                // rotoring through buttons would otherwise hear "Refetch"
                // three times with no way to tell which one they were on.
                .accessibilityLabel(Text("Refetch \(Text(title))"))
        }
    }

    /// Saying "unavailable" without looking broken (decision D5): a company
    /// section that cannot be filled is a normal state, not an error.
    @ViewBuilder
    private func unavailable(_ kind: FundamentalsKind) -> some View {
        switch model.fundamentalsStatus(for: commodity) {
        case .fetching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Fetching…").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            // The spinner conveys nothing to VoiceOver and this line replaces
            // the button the user just pressed, so it says what is happening
            // and to what — not just that something is.
            .accessibilityLabel("Fetching company data for \(commodity.mnemonic)")
            .accessibilityAddTraits(.updatesFrequently)
        case .unavailable(let message):
            Text(message).scaledFont(.callout).foregroundStyle(.secondary)
        case .idle:
            HStack {
                Text("Not fetched yet.").scaledFont(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Fetch") { Task { await model.fetchFundamentals(for: commodity) } }
                    .buttonStyle(.borderless)
                    // Same problem as Refetch: several sections offer "Fetch".
                    .accessibilityLabel("Fetch company data for \(commodity.mnemonic)")
            }
        }
    }

    // MARK: Checks — declared against recorded (`FR-INV-20`, 21, 28)

    /// The section that needs the ledger *and* the market at once, which is why
    /// no portfolio tracker and no accounting package can produce it.
    ///
    /// Everything here is a **discrepancy to look at**, never a correction to
    /// apply: the planning doctrine holds, and the app reports what is
    /// inconsistent rather than deciding what is true.
    @ViewBuilder
    private var checks: some View {
        let found = model.reconciliation(for: commodity)
        if let found, !found.isClean {
            Section {
                ForEach(found.dividends) { discrepancy in
                    checkRow(symbol: discrepancy.kind.symbol,
                             tint: discrepancy.kind.tint,
                             title: discrepancy.kind.title,
                             detail: dividendDetail(discrepancy))
                }
                ForEach(found.splits) { split in
                    checkRow(symbol: "arrow.triangle.branch", tint: .red,
                             title: "A split was never recorded",
                             detail: String(localized: "\(dateFormat.long(split.date)) · \(DecimalFormat.units(split.unitsBefore)) units should have become \(DecimalFormat.units(split.expectedUnitsAfter)), and the book shows \(DecimalFormat.units(split.actualUnitsAfter))"))
                }
                ForEach(found.outliers) { outlier in
                    checkRow(symbol: "exclamationmark.triangle", tint: .orange,
                             title: outlier.likelyCause.title,
                             detail: String(localized: "\(dateFormat.long(outlier.date)) · \(AmountFormat.string(outlier.value, code: code)) against \(AmountFormat.string(outlier.neighbourMedian, code: code)) either side"))
                }
            } header: {
                HStack {
                    Text("Checks")
                    Text("\(found.count)").foregroundStyle(.secondary)
                }
            } footer: {
                Text("Nothing here is changed for you. Each line is a difference between what the issuer declared and what your book records.")
                    .scaledFont(.caption2)
            }
        }
    }

    private func checkRow(symbol: String, tint: Color,
                          title: LocalizedStringKey, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).scaledFont(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func dividendDetail(_ discrepancy: DividendDiscrepancy) -> String {
        var parts = [dateFormat.long(discrepancy.date)]
        if let expected = discrepancy.expectedAmount {
            parts.append(String(localized: "expected \(AmountFormat.string(expected, code: code))"))
        }
        if let recorded = discrepancy.recordedAmount {
            parts.append(String(localized: "recorded \(AmountFormat.string(recorded, code: code))"))
        }
        if let units = discrepancy.unitsHeld, let perUnit = discrepancy.declaredPerUnit {
            parts.append(String(localized: "\(AmountFormat.string(perUnit, code: code)) × \(DecimalFormat.units(units)) units"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Your transactions

    @ViewBuilder
    private func activity(_ detail: SecurityDetail) -> some View {
        if !detail.events.isEmpty {
            Section("Your transactions") {
                // Newest first: the movement a person is looking for is nearly
                // always the one they just made.
                ForEach(detail.events.reversed()) { event in
                    HStack(spacing: 10) {
                        Image(systemName: event.kind.symbol)
                            .foregroundStyle(event.kind.tint)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            if event.eventDescription.isEmpty {
                                event.kind.title
                            } else {
                                Text(event.eventDescription)
                            }
                            Text(dateFormat.long(event.date))
                                .scaledFont(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(AmountFormat.string(event.amount, code: code)).monospacedDigit()
                            if event.units != 0 {
                                Text(unitsAndPrice(event)).scaledFont(.caption)
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func unitsAndPrice(_ event: SecurityEvent) -> String {
        let units = DecimalFormat.units(event.units)
        guard let price = event.unitPrice else { return units }
        return "\(units) @ \(AmountFormat.string(price, code: code))"
    }

    // MARK: Lots

    @ViewBuilder
    private func lots(_ detail: SecurityDetail) -> some View {
        if !detail.lots.isEmpty {
            Section("Open lots") {
                ForEach(detail.lots) { lot in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(lot.acquisitionDate.map { dateFormat.long($0) }
                                 ?? String(localized: "Date unknown"))
                            Text(DecimalFormat.units(lot.quantity))
                                .scaledFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(AmountFormat.string(lot.costBasis, code: code)).monospacedDigit()
                            if let gain = lot.unrealizedGain {
                                Text(AmountFormat.string(gain, code: code))
                                    .scaledFont(.caption).monospacedDigit()
                                    .foregroundStyle(gain < 0 ? Color.negativeAmount : Color.positiveAmount)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: Prices — the only price table in the app (`FR-INV-27`, `FR-INV-29`)

    @ViewBuilder
    private func prices(_ detail: SecurityDetail) -> some View {
        Section {
            if detail.prices.isEmpty {
                Text("No prices recorded.").foregroundStyle(.secondary).scaledFont(.callout)
            } else {
                ForEach(detail.prices.reversed()) { row in
                    PriceEditRow(row: row, model: model,
                                 onDelete: { confirmingDelete = row })
                }
            }
        } header: {
            HStack {
                Text("Prices")
                Text("\(detail.prices.count)").foregroundStyle(.secondary)
                Spacer()
                Button("Export…") { exportingCSV = true }
                    .buttonStyle(.borderless)
                    .disabled(detail.prices.isEmpty)
            }
        } footer: {
            if !detail.sources.isEmpty {
                // Provenance stated once for the whole series, then per row.
                // On the reference book 68% of prices were hand-entered and
                // nothing on screen ever said so.
                Text(sourceSummary(detail)).scaledFont(.caption2)
            }
        }
    }

    private func sourceSummary(_ detail: SecurityDetail) -> String {
        detail.sources
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(4)
            .map { "\(PriceSourceName.short($0.key)) \($0.value)" }
            .joined(separator: " · ")
    }

    // MARK: Settings (`FR-INV-32`)

    @ViewBuilder
    private func settings(_ detail: SecurityDetail) -> some View {
        Section {
            LabeledContent("Ticker", value: commodity.mnemonic)
            IdentifierField(
                label: "Quote symbol",
                help: "Overrides the ticker sent to the price provider.",
                value: model.quoteSymbol(for: commodity) ?? "",
                commit: { model.setQuoteSymbol($0, for: commodity) })
            IdentifierField(
                label: "ISIN or exchange code",
                help: "Used to match this security at providers that key by identifier rather than ticker.",
                value: model.exchangeCode(for: commodity),
                commit: { model.setExchangeCode($0, for: commodity) })
            VStack(alignment: .leading, spacing: 2) {
                Picker("Price provider", selection: Binding(
                    get: { model.quoteProvider(for: commodity)?.rawValue ?? "" },
                    set: { model.setQuoteProvider(QuoteProviderKind(rawValue: $0), for: commodity) })) {
                    Text("Use the run's provider").tag("")
                    ForEach(model.availableProviders) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                Text("A bond is priced by its identifier at a service only bonds use; a share is not. Choosing here lets one update run serve both.")
                    .scaledFont(.caption2).foregroundStyle(.secondary)
            }
            if !detail.accountNames.isEmpty {
                LabeledContent("Held in") {
                    VStack(alignment: .trailing, spacing: 1) {
                        ForEach(detail.accountNames, id: \.self) { name in
                            Text(name).scaledFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let target = model.priceTarget(for: commodity) {
                LabeledContent("Price target",
                               value: AmountFormat.string(target.target, code: code))
            }
        } header: {
            Text("Settings")
        }
    }
}

// MARK: - Financial statements

/// One statement's periods side by side, newest first.
///
/// Rows are the union of every period's line labels rather than a fixed
/// schema: providers disagree about which lines they publish, and for some
/// issuers most come back empty. A missing line shows as **—**, never as zero —
/// "this bank does not report a gross profit" and "this bank's gross profit was
/// nothing" are different claims.
private struct StatementTable: View {
    let periods: [FinancialPeriod]
    let currencyCode: String

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Line").gridColumnAlignment(.leading)
                        .scaledFont(.caption).foregroundStyle(.secondary)
                    ForEach(periods) { period in
                        Text(period.endDate, format: .dateTime.year().month(.abbreviated))
                            .scaledFont(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(labels, id: \.self) { label in
                    GridRow {
                        Text(StatementLabel.readable(label))
                            .gridColumnAlignment(.leading)
                            .scaledFont(.callout)
                        ForEach(periods) { period in
                            Text(period.lines[label].map {
                                AmountFormat.compact($0, code: currencyCode)
                            } ?? "—")
                                .scaledFont(.callout).monospacedDigit()
                                .foregroundStyle(period.lines[label] == nil
                                                 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Every label any period reports, ordered by how many periods report it —
    /// so the lines present throughout come first and the one-off appearances
    /// fall to the bottom.
    private var labels: [String] {
        var counts: [String: Int] = [:]
        for period in periods {
            for label in period.lines.keys { counts[label, default: 0] += 1 }
        }
        return counts.keys.sorted {
            counts[$0]! == counts[$1]! ? $0 < $1 : counts[$0]! > counts[$1]!
        }
    }
}

/// Turns a provider's camel-cased line name into something a person reads.
///
/// Not a translation table: the labels are the provider's own vocabulary and
/// there are hundreds of them across issuers. Splitting the camel case and
/// capitalising the first word turns `totalStockholderEquity` into "Total
/// stockholder equity", which is honest about being the provider's wording
/// rather than pretending to be a localized accounting term.
enum StatementLabel {
    static func readable(_ raw: String) -> String {
        var out = ""
        for character in raw {
            if character.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(character)
        }
        return out.prefix(1).uppercased() + out.dropFirst().lowercased()
    }
}

private extension FinancialPeriod.Statement {
    var title: LocalizedStringKey {
        switch self {
        case .income: "Income statement"
        case .balance: "Balance sheet"
        case .cashflow: "Cash flow"
        }
    }
}

// MARK: - The chart

/// The price line with the book drawn on it: your buys and sells, your average
/// cost, and the periods you actually held it (`FR-INV-16`).
private struct PriceHistoryChart: View {
    let detail: SecurityDetail
    let window: ClosedRange<Date>
    let points: [SecurityPriceRow]
    let currencyCode: String

    var body: some View {
        Chart {
            // Held-period shading first, so everything else draws over it.
            ForEach(Array(shadedPeriods.enumerated()), id: \.offset) { _, period in
                RectangleMark(xStart: .value("From", period.lowerBound),
                              xEnd: .value("To", period.upperBound))
                    .foregroundStyle(Color.appAccent.opacity(0.10))
            }

            // The price line, broken at gaps so an absence reads as an absence
            // rather than as a straight line nobody has data for (`FR-INV-12`).
            ForEach(segments) { segment in
                ForEach(segment.rows) { row in
                    LineMark(x: .value("Date", row.date),
                             y: .value("Price", asDouble(row.value)),
                             series: .value("Series", segment.id))
                        .foregroundStyle(Color.appAccent)
                        .interpolationMethod(.linear)
                }
            }

            if let average = detail.averageCost, average > 0 {
                RuleMark(y: .value("Average cost", asDouble(average)))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
            }

            // Your movements, placed at what you actually paid or received, so
            // a marker sitting above the line is a purchase above the market.
            ForEach(markers) { marker in
                PointMark(x: .value("Date", marker.date),
                          y: .value("Price", marker.price))
                    .symbol(marker.kind == .buy ? .triangle : .diamond)
                    .symbolSize(70)
                    .foregroundStyle(marker.kind == .buy ? Color.green : Color.red)
            }
        }
        .chartXScale(domain: window)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(AmountFormat.string(Decimal(number), code: currencyCode))
                    }
                }
            }
        }
        .chartLegend(.hidden)
        // The legend below carries the spoken description; the plot itself is
        // decorative to VoiceOver rather than an unnavigable wall of marks.
        .accessibilityHidden(true)
    }

    private func asDouble(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }

    /// Held periods clipped to the visible window, so shading never extends the
    /// x-domain and squashes the line into a corner.
    private var shadedPeriods: [ClosedRange<Date>] {
        detail.holdingPeriods.compactMap { period in
            let start = max(period.start, window.lowerBound)
            let end = min(period.end ?? window.upperBound, window.upperBound)
            return start < end ? start...end : nil
        }
    }

    private struct Segment: Identifiable {
        let id: Int
        let rows: [SecurityPriceRow]
    }

    /// Contiguous runs, broken where more than a fortnight passes with no
    /// price. Two weeks rather than one: a fortnight is unambiguously a hole
    /// even across a public holiday week, and a shorter threshold shattered
    /// thin securities into confetti.
    private var segments: [Segment] {
        var out: [Segment] = []
        var current: [SecurityPriceRow] = []
        for row in points {
            if let last = current.last,
               row.date.timeIntervalSince(last.date) > 14 * 86_400 {
                if current.count > 1 { out.append(Segment(id: out.count, rows: current)) }
                current = []
            }
            current.append(row)
        }
        if current.count > 1 { out.append(Segment(id: out.count, rows: current)) }
        return out
    }

    private struct Marker: Identifiable {
        let id: String
        let kind: SecurityEvent.Kind
        let date: Date
        let price: Double
    }

    private var markers: [Marker] {
        detail.events.compactMap { event in
            guard event.kind != .income, window.contains(event.date),
                  let price = event.unitPrice else { return nil }
            return Marker(id: event.id, kind: event.kind, date: event.date,
                          price: asDouble(price))
        }
    }
}

// MARK: - Chart range

/// The periods the detail chart can show.
///
/// **Held** is the one no other app offers and the only range that judges your
/// own decisions: the period you actually owned the thing. Everything before
/// you bought it is somebody else's story.
private enum DetailRange: String, CaseIterable, Identifiable {
    case month, halfYear, year, fiveYears, all, held
    var id: String { rawValue }

    var label: String {
        switch self {
        case .month: String(localized: "1 month")
        case .halfYear: String(localized: "6 months")
        case .year: String(localized: "1 year")
        case .fiveYears: String(localized: "5 years")
        case .all: String(localized: "All")
        case .held: String(localized: "While held")
        }
    }

    private var days: Int? {
        switch self {
        case .month: 30
        case .halfYear: 183
        case .year: 365
        case .fiveYears: 1826
        case .all, .held: nil
        }
    }

    func window(for detail: SecurityDetail) -> ClosedRange<Date> {
        let end = detail.asOf
        let earliest = detail.prices.first?.date ?? Calendar.current.date(
            byAdding: .year, value: -1, to: end) ?? end
        switch self {
        case .all:
            return earliest...max(end, earliest.addingTimeInterval(1))
        case .held:
            // Falls back to everything when nothing was ever held — a watched
            // security has no holding period, and an empty range would draw an
            // empty chart with no explanation.
            guard let first = detail.holdingPeriods.map(\.start).min() else {
                return earliest...max(end, earliest.addingTimeInterval(1))
            }
            let last = detail.holdingPeriods.contains { $0.end == nil }
                ? end
                : (detail.holdingPeriods.compactMap(\.end).max() ?? end)
            return first...max(last, first.addingTimeInterval(1))
        default:
            let start = Calendar.current.date(byAdding: .day, value: -(days ?? 365), to: end) ?? end
            return start...end
        }
    }
}

// MARK: - One editable price row

/// A price with its provenance, editable in place.
///
/// Per CLAUDE.md ▸ Theming: no border and no fill at rest, a ring and nothing
/// else on focus, and the same box in both states so the row does not move when
/// it is edited.
private struct PriceEditRow: View {
    let row: SecurityPriceRow
    @Bindable var model: AppModel
    let onDelete: () -> Void

    @Environment(\.appDateFormat) private var dateFormat
    @FocusState private var editing: Bool
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 10) {
            Text(dateFormat.long(row.date))
                .monospacedDigit()
                .frame(minWidth: 90, alignment: .leading)

            Text(PriceSourceName.short(row.source))
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextField("Price", text: $draft)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 110)
                .focused($editing)
                .overlay {
                    if editing {
                        RoundedRectangle(cornerRadius: 4).strokeBorder(.tint, lineWidth: 2)
                    }
                }
                .onSubmit(commit)
                .onChange(of: editing) { _, nowEditing in
                    if nowEditing { draft = text } else { commit() }
                }
                .onAppear { draft = text }
                .onChange(of: row.value) { _, _ in if !editing { draft = text } }
                .accessibilityLabel("Price on \(dateFormat.long(row.date))")

            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .accessibilityLabel("Delete the price for \(dateFormat.long(row.date))")
        }
        .scaledFont(.callout)
    }

    /// The stored figure, unrounded: the price database keeps four decimals for
    /// a reason and a display rounding typed back would silently truncate it.
    private var text: String { NSDecimalNumber(decimal: row.value).stringValue }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard let value = EditableSplit.strictDecimal(trimmed), value > 0 else {
            draft = text          // reject silently by reverting, never by writing nonsense
            return
        }
        model.updatePriceValue(row.id, to: value)
    }
}

// MARK: - A per-security identifier field

/// A labelled field that commits on blur or return, used for the quote symbol
/// and the ISIN.
///
/// The label is a real label, not a placeholder: HIG *Text fields* — "it can
/// also be useful to include a separate label describing the field" — and a
/// placeholder vanishes the moment there is a value, taking the only
/// explanation of what the field is with it.
private struct IdentifierField: View {
    let label: LocalizedStringKey
    let help: LocalizedStringKey
    let value: String
    let commit: (String) -> Void

    @FocusState private var editing: Bool
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(label) {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    // `LabeledContent` associates the label visually; the field
                    // itself still reaches the accessibility API unnamed.
                    .accessibilityLabel(label)
                    .focused($editing)
                    .overlay {
                        if editing {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(.tint, lineWidth: 2)
                        }
                    }
                    .onSubmit { commit(draft) }
                    .onChange(of: editing) { _, nowEditing in
                        if nowEditing { draft = value } else { commit(draft) }
                    }
                    .onAppear { draft = value }
                    .onChange(of: value) { _, now in if !editing { draft = now } }
                    .accessibilityLabel(label)
            }
            Text(help).scaledFont(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Presentation

extension SecurityEvent.Kind {
    var symbol: String {
        switch self {
        case .buy: "arrow.down.circle.fill"
        case .sell: "arrow.up.circle.fill"
        case .income: "dollarsign.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .buy: .green
        case .sell: .red
        case .income: .appAccent
        }
    }

    var title: Text {
        switch self {
        case .buy: Text("Bought")
        case .sell: Text("Sold")
        case .income: Text("Income")
        }
    }
}

extension DividendDiscrepancy.Kind {
    var symbol: String {
        switch self {
        case .missing: "tray.and.arrow.down"
        case .unexpected: "questionmark.circle"
        case .amountDiffers: "notequal.circle"
        }
    }

    /// A missing dividend understates income and therefore tax; the other two
    /// are worth checking but not wrong on their face.
    var tint: Color {
        switch self {
        case .missing: .red
        case .unexpected, .amountDiffers: .orange
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .missing: "A declared dividend is not in your book"
        case .unexpected: "Income with no matching declaration"
        case .amountDiffers: "The amount received differs from the declaration"
        }
    }
}

extension PriceOutlier.Likely {
    var title: LocalizedStringKey {
        switch self {
        case .decimalSlip: "A price looks like a decimal-point slip"
        case .wrongScale: "A price looks like the wrong scale or currency"
        case .unexplained: "A price is far from the ones around it"
        }
    }
}

/// Turns a stored `Price.source` into something a person reads.
///
/// The stored strings are GnuCash's — `Finance::Quote:yahoo`, `user:price`,
/// `user:xfer-dialog` — and printing them raw makes the provenance column look
/// like a debug log. The provider's own name is what matters; how the app spelt
/// it internally is not.
enum PriceSourceName {
    static func short(_ source: String) -> String {
        if source.hasPrefix("Finance::Quote") {
            let provider = source.split(separator: ":").last.map(String.init) ?? source
            return provider.capitalized
        }
        switch source {
        case "user:price", "user:price-editor": return String(localized: "Typed")
        case "user:split-import": return String(localized: "Imported")
        case "user:xfer-dialog": return String(localized: "From a transfer")
        default: return source
        }
    }
}

/// Unit quantities, which are not money: a share count has no currency and
/// four decimals of a unit is meaningful where four decimals of a dollar is
/// not.
enum DecimalFormat {
    static func units(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 4
        formatter.minimumFractionDigits = 0
        return formatter.string(from: number) ?? number.stringValue
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
