//
//  ReportsView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import Charts
import FinvestLensEngine
import FinvestLensReports
import FinvestLensIntelligence

/// A tabbed reports view: Balance Sheet, Income Statement, and a Net-Worth chart.
/// Wraps the reports workspace for presentation in its own window (HIG:
/// sheets are for brief, focused tasks — an analytics workspace gets a
/// window so it doesn't block the register).
public struct ReportsWindow: View {
    @Bindable var model: AppModel
    public init(model: AppModel) { self.model = model }
    public var body: some View {
        if model.isOpen {
            NavigationStack { ReportsHome(model: model) }
        } else {
            ContentUnavailableView("No book open", systemImage: "chart.pie",
                                   description: Text("Open a book to see its reports."))
                .windowFloor(minWidth: 520, minHeight: 440)
        }
    }
}

struct PriceScatterView: View {
    @Bindable var model: AppModel

    var body: some View {
        // Memoised in the model (stable ids from the price GUIDs): building
        // this in the view was O(securities × prices) per body pass — ~3M
        // comparisons on the reference book — with fresh UUID identities that
        // defeated Charts diffing every render.
        let data = model.priceScatterPoints()
        Group {
        if data.isEmpty {
            ContentUnavailableView("No prices", systemImage: "chart.dots.scatter",
                                   description: Text("Record security prices to plot them over time."))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ReportMasthead(entity: model.statementEntityName,
                               title: String(localized: "Price History"),
                               period: String(localized: "All recorded security prices"),
                               code: model.reportCurrency.mnemonic)
                    .padding(.top, 12)
                Chart(data) { point in
                    PointMark(x: .value("Date", point.date),
                              y: .value("Price", point.price))
                        .foregroundStyle(by: .value("Security", point.symbol))
                }
                .chartForegroundStyleScale(range: ReportPalette.categorical)
                .frame(minHeight: 260)
                .padding()
                .accessibilityLabel("Price scatter of all securities over time")
            }
        }
        }
        .reportPDFToolbar(title: String(localized: "Price History"), entity: model.statementEntityName) { model.priceHistoryDocument() }
    }
}

struct ForecastView: View {
    @Environment(\.appDateFormat) private var dateFormat
    @Bindable var model: AppModel
    @State private var showAddWhatIf = false
    @State private var wiDate = Date()
    @State private var wiAmount = ""
    @State private var wiLabel = ""
    @State private var insights: ForecastInsights?
    @State private var generatingOutlook = false
    @State private var outlookError: String?
    /// The projection, built by a task after the frame that asked for it —
    /// it used to be computed in `body`, so the first look after any edit
    /// held the window while it walked the book (Performance Review P3.2).
    /// Kept while a newer one builds, with a small indicator, rather than
    /// blanking the chart: a what-if added should not blink the page.
    @State private var forecast: (key: ForecastKey, points: [CashFlowPoint])?
    /// The day the projection starts from, moved on at midnight by the view
    /// itself — the projection is the book's from today, and nothing else
    /// redraws a Forecast left open overnight.
    @State private var today = AppModel.endOfToday()
    @Environment(\.appFontScale) private var appFontScale
    private var dateWidth: CGFloat { 96 * appFontScale }
    private var balanceWidth: CGFloat { 96 * appFontScale }

    /// What a projection was built for: the account, the book, the what-ifs,
    /// and the day it starts from — the memo's own key has the day, and a
    /// view key without it kept yesterday's projection past midnight
    /// (17 October review).
    struct ForecastKey: Hashable {
        var accountID: GncGUID
        var revision: Int
        var whatIf: [WhatIfEvent]
        var day: Date
    }

    var body: some View {
        Group {
        if let accountID = model.defaultForecastAccountID {
            let key = ForecastKey(accountID: accountID, revision: model.bookRevision,
                                  whatIf: model.whatIfEvents, day: today)
            // The projection for this key once built, or the memo's if it is
            // already there — drawn in the first frame rather than a
            // placeholder — or the last one, under an indicator, while this
            // one builds.
            let current = forecast?.key == key ? forecast
                : model.cachedCashFlowForecast(accountID: accountID).map { (key: key, points: $0) }
            let shown = current ?? forecast
            VStack(spacing: 0) {
                ReportMasthead(entity: model.statementEntityName,
                               title: String(localized: "Forecast"),
                               period: model.accountName(accountID) ?? String(localized: "Projected balances"),
                               code: model.reportCurrency.mnemonic)
                    .padding(.top, 12)
                    .overlay(alignment: .topTrailing) {
                        if shown != nil, current == nil {
                            ProgressView().controlSize(.small).padding(12)
                                .accessibilityLabel("Updating the forecast")
                        }
                    }
                whatIfBar
                Divider()
                if let points = shown?.points {
                    projection(points)
                } else {
                    LoadingPlaceholder("Projecting balances…")
                }
            }
            .task(id: key) {
                let requested = key
                // One yield so the frame paints first, as the other reports
                // do — unless the projection is already built.
                if model.cachedCashFlowForecast(accountID: requested.accountID) == nil { await Task.yield() }
                let points = model.cashFlowForecast(accountID: requested.accountID)
                guard !Task.isCancelled else { return }
                forecast = (requested, points)
            }
            .reportPDFToolbar(title: String(localized: "Forecast"), entity: model.statementEntityName) {
                // From the projection on screen — never a second walk of the
                // book inside the toolbar's own body — under the account it
                // was built for, which during a rebuild is not always the one
                // now chosen.
                shown.flatMap { model.forecastDocument(accountID: $0.key.accountID, points: $0.points) }
            }
        } else {
            ContentUnavailableView("No account to forecast", systemImage: "banknote",
                                   description: Text("Create an asset account first."))
        }
        }
        // Wakes at midnight, so the projection moves on with the day — and
        // sleeps again if it woke a moment early.
        .task(id: today) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(1, today.timeIntervalSinceNow)))
                let day = AppModel.endOfToday()
                if day != today, !Task.isCancelled { today = day; return }
            }
        }
    }

    /// The chart, the outlook and the list of what moves the balance.
    @ViewBuilder
    private func projection(_ points: [CashFlowPoint]) -> some View {
        let events = points.filter { $0.change != 0 }
                if events.isEmpty {
                    ContentUnavailableView("No upcoming activity", systemImage: "calendar",
                                           description: Text("Add scheduled transactions or a what-if event to forecast cash flow."))
                } else {
                    Chart {
                        ForEach(points) { point in
                            LineMark(x: .value("Date", point.date), y: .value("Balance", point.balance))
                                .interpolationMethod(.stepEnd)
                        }
                        ForEach(points.filter(\.isWhatIf)) { point in
                            // Hypotheticals in a reserved tint, distinct from
                            // the accent-coloured actual projection.
                            PointMark(x: .value("Date", point.date), y: .value("Balance", point.balance))
                                .foregroundStyle(.purple)
                        }
                        RuleMark(y: .value("Zero", 0))
                            .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [4]))
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 170)
                    .padding()
                    .accessibilityLabel("Projected cash-flow balance")
                    Divider()
                    if model.isIntelligenceAvailable(for: .forecastNarrator) {
                        outlookBar
                        Divider()
                    }
                    List(events) { event in
                        HStack {
                            AdaptiveDate(event.date)
                                .foregroundStyle(.secondary)
                                .frame(width: dateWidth, alignment: .leading)
                            Text(event.label)
                            if event.isWhatIf {
                                Text("what-if").scaledFont(.caption2)
                                    .padding(.horizontal, 4).background(.purple.opacity(0.2)).clipShape(Capsule())
                            }
                            Spacer()
                            Text(AmountFormat.string(event.change, code: model.reportCurrency.mnemonic))
                                .monospacedDigit()
                                .foregroundStyle(event.change < 0 ? Color.negativeAmount : Color.positiveAmount)
                            Text(AmountFormat.string(event.balance, code: model.reportCurrency.mnemonic))
                                .monospacedDigit()
                                .frame(width: balanceWidth, alignment: .trailing)
                                .foregroundStyle(event.balance < 0 ? Color.negativeAmount : Color.primary)
                        }
                    }
                }
    }

    private var whatIfBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("What-if scenario").scaledFont(.subheadline).fontWeight(.medium)
                Spacer()
                Button(showAddWhatIf ? "Close" : "Add event", systemImage: "plus") {
                    showAddWhatIf.toggle()
                }
                .scaledFont(.caption)
            }
            if showAddWhatIf {
                HStack {
                    DatePicker("", selection: $wiDate, displayedComponents: .date).labelsHidden()
                    TextField("Amount (+in / −out)", text: $wiAmount)
                        .frame(width: 130).multilineTextAlignment(.trailing)
                    TextField("Label", text: $wiLabel).frame(width: 120)
                    Button("Add") { addWhatIf() }.disabled(EditableSplit.strictDecimal(wiAmount.trimmingCharacters(in: .whitespaces)) == nil)
                }
                .scaledFont(.caption)
            }
            ForEach(model.whatIfEvents) { event in
                HStack(spacing: 4) {
                    Button(role: .destructive) { model.removeWhatIfEvent(event.id) } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Remove what-if event \(event.label)")
                    Text("\(event.label): \(AmountFormat.string(event.amount, code: model.reportCurrency.mnemonic)) on \(dateFormat.short(event.date))")
                        .scaledFont(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal).padding(.vertical, 8)
    }

    private func addWhatIf() {
        guard let amount = EditableSplit.strictDecimal(wiAmount.trimmingCharacters(in: .whitespaces)) else { return }
        model.addWhatIfEvent(date: wiDate, amount: amount, label: wiLabel)
        wiAmount = ""; wiLabel = ""; showAddWhatIf = false
    }

    /// Plain-language outlook on the forecast, written from the computed
    /// numbers (`FR-AI-06`) — on the model the person chose, which the bar
    /// says when that is not this device.
    private var outlookBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Outlook", systemImage: "sparkles")
                    .scaledFont(.subheadline).fontWeight(.medium)
                Spacer()
                Button {
                    generateOutlook()
                } label: {
                    // A spinner while the model writes, not only new words.
                    if generatingOutlook {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Generating…")
                        }
                    } else {
                        Text(insights == nil ? "Generate" : "Refresh")
                    }
                }
                .scaledFont(.caption)
                .disabled(generatingOutlook)
            }
            IntelligenceRunsNote(.forecast)
            if let insights {
                Text(insights.headline).scaledFont(.callout).fontWeight(.medium)
                ForEach(insights.insights, id: \.self) { insight in
                    Text("•  \(insight)").scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
            if let outlookError {
                Text(outlookError).scaledFont(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal).padding(.vertical, 8)
    }

    private func generateOutlook() {
        generatingOutlook = true
        outlookError = nil
        Task {
            defer { generatingOutlook = false }
            do {
                insights = try await model.forecastInsights()
            } catch {
                outlookError = error.localizedDescription
            }
        }
    }
}
