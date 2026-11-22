//
//  StatementView.swift
//  FinvestLens — FeatureUI
//
//  Renders a ``Statement`` in annual-report style (docs/report-redesign.md
//  §3.2): a centred masthead, a face with a Note column and right-aligned
//  tabular figures — negatives in parentheses, the currency symbol on the
//  first figure and totals only, a single rule above subtotals and a double
//  rule under closing figures — then the notes. One sheet serves both the
//  screen (scrolled) and the PDF (rendered directly), so print and screen
//  cannot drift.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine

// MARK: - Figures, statement-style

enum StatementFormat {
    /// "1,234.56", "(1,234.56)", "$1,234.56" — parentheses for negatives,
    /// the symbol only where statements put it.
    static func amount(_ value: Decimal?, code: String, symbol: Bool) -> String {
        guard let value else { return "" }
        let magnitude = abs(value)
        let text = symbol
            ? AmountFormat.string(magnitude, code: code)
            : magnitude.formatted(.number.precision(.fractionLength(2)))
        return value < 0 ? "(\(text))" : text
    }
}

// MARK: - The sheet

/// The statement itself — masthead, face, notes. Deliberately free of app
/// chrome so `ReportExport.pdf` can render the same view to paper.
struct StatementSheet: View {
    let statement: Statement
    @Environment(\.appFontScale) private var appFontScale
    /// Always `.large` on the Mac and in `ReportExport`'s renderer, so print
    /// keeps the face below.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var amountWidth: CGFloat { 108 * appFontScale }
    private var noteWidth: CGFloat { 40 * appFontScale }
    private var hasNotesColumn: Bool {
        statement.sections.contains { $0.items.contains { $0.noteRef != nil } }
    }

    /// The statement's form at the accessibility text sizes: each line's
    /// caption on a line of its own, then every period's figure against that
    /// period's heading. The face's fixed 108-point columns follow only the
    /// Mac's Text Size, so at AX3 (Apple's 200% bar for Larger Text) an iPad
    /// split figures mid-number ("$23,07 / 9.27") and the Note heading broke
    /// in two (22 Nov 2026). Widening the columns instead would push a
    /// comparative statement's two figures off a phone's width.
    private var stacked: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            masthead
            if !stacked { columnHeadings }
            ForEach(statement.sections) { section in
                sectionView(section)
            }
            if let grand = statement.grandTotal {
                grandTotalRow(grand.label, grand.amounts, firstSymbol: true)
            }
            if !statement.notes.isEmpty {
                notesView
            }
        }
    }

    // MARK: Masthead

    private var masthead: some View {
        VStack(spacing: 3) {
            Text(statement.entityName)
                .scaledFont(.title3, weight: .semibold)
            Text(statement.title)
                .scaledFont(.title, weight: .bold)
                .fontDesign(.serif)
            Text(statement.periodLabel)
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
            Text(statement.unitsLabel)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
    }

    /// The column headings row: Note · period columns.
    private var columnHeadings: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Spacer()
            if hasNotesColumn {
                Text("Note")
                    .frame(width: noteWidth, alignment: .trailing)
            }
            ForEach(Array(statement.columns.enumerated()), id: \.offset) { _, column in
                Text(column)
                    .frame(width: amountWidth, alignment: .trailing)
            }
        }
        .scaledFont(.caption, weight: .medium)
        .foregroundStyle(.secondary)
        .overlay(alignment: .bottom) { Divider().offset(y: 4) }
    }

    // MARK: Face

    private func sectionView(_ section: StatementSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title)
                .scaledFont(.footnote, weight: .semibold)
                .textCase(.uppercase)
                .kerning(0.8)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                faceRow(item, firstSymbol: index == 0)
            }
            subtotalRow(section.totalLabel, section.totalAmounts)
        }
    }

    @ViewBuilder
    private func faceRow(_ item: StatementItem, firstSymbol: Bool) -> some View {
        let font: Font.TextStyle = item.role == .childLine ? .callout : .body
        if stacked {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.caption)
                        .scaledFont(font)
                        .foregroundStyle(item.role == .childLine ? .secondary : .primary)
                    if let note = item.noteRef {
                        Text("Note \(note)")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                figureLines(item.amounts, symbol: firstSymbol, font: font)
            }
            .padding(.leading, CGFloat(item.depth) * 18)
            .padding(.vertical, 3.5)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.caption)
                    .scaledFont(font)
                    .foregroundStyle(item.role == .childLine ? .secondary : .primary)
                    .padding(.leading, CGFloat(item.depth) * 18)
                Spacer(minLength: 12)
                if hasNotesColumn {
                    Text(item.noteRef.map(String.init) ?? "")
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: noteWidth, alignment: .trailing)
                }
                amounts(item.amounts, symbol: firstSymbol, font: font)
            }
            .padding(.vertical, 3.5)
        }
    }

    /// A caption and its figures: side by side, or stacked at the
    /// accessibility sizes (``stacked``).
    @ViewBuilder
    private func labelledFigures(_ label: String, _ values: [Decimal?], weight: Font.Weight) -> some View {
        if stacked {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).scaledFont(.body, weight: weight)
                figureLines(values, symbol: true, font: .body, weight: weight)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).scaledFont(.body, weight: weight)
                Spacer(minLength: 12)
                if hasNotesColumn { Color.clear.frame(width: noteWidth, height: 1) }
                amounts(values, symbol: true, font: .body, weight: weight)
            }
        }
    }

    /// Section subtotal: a single rule above, medium weight.
    private func subtotalRow(_ label: String, _ values: [Decimal?]) -> some View {
        labelledFigures(label, values, weight: .medium)
        .padding(.vertical, 5)
        .overlay(alignment: .top) {
            singleRule.padding(.leading, ruleIndent)
        }
    }

    /// The statement's closing figure: semibold, double rule beneath.
    private func grandTotalRow(_ label: String, _ values: [Decimal?],
                               firstSymbol: Bool) -> some View {
        labelledFigures(label, values, weight: .semibold)
        .padding(.vertical, 6)
        .overlay(alignment: .top) { singleRule.padding(.leading, ruleIndent) }
        .overlay(alignment: .bottom) {
            VStack(spacing: 1.5) { singleRule; singleRule }
                .padding(.leading, ruleIndent)
        }
    }

    /// Rules cover the figures, not the caption — the accounting convention.
    private var ruleIndent: CGFloat { 0 }
    private var singleRule: some View {
        Rectangle().fill(Color.primary.opacity(0.35)).frame(height: 0.75)
    }

    private func amounts(_ values: [Decimal?], symbol: Bool,
                         font: Font.TextStyle, weight: Font.Weight = .regular) -> some View {
        ForEach(Array(values.enumerated()), id: \.offset) { _, value in
            Text(StatementFormat.amount(value, code: statement.currencyCode, symbol: symbol))
                .scaledFont(font, weight: weight)
                .monospacedDigit()
                .frame(width: amountWidth, alignment: .trailing)
        }
    }

    /// The stacked form's figures: one line per period, its heading at the
    /// left and the figure, whole, at the right. A figure is one word; it
    /// shrinks before it ever wraps.
    private func figureLines(_ values: [Decimal?], symbol: Bool,
                             font: Font.TextStyle, weight: Font.Weight = .regular) -> some View {
        ForEach(Array(values.enumerated()), id: \.offset) { index, value in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(index < statement.columns.count ? statement.columns[index] : "")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(StatementFormat.amount(value, code: statement.currencyCode, symbol: symbol))
                    .scaledFont(font, weight: weight)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.leading, 12)
        }
    }

    // MARK: Notes

    private var notesView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Notes to the financial statements")
                .scaledFont(.title3, weight: .bold)
                .fontDesign(.serif)
                .padding(.top, 10)
            ForEach(statement.notes) { note in
                noteView(note)
            }
        }
    }

    private func noteView(_ note: StatementNote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(note.number). \(note.title)")
                .scaledFont(.body, weight: .semibold)
            ForEach(note.body, id: \.self) { line in
                Text(line)
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(note.rows) { row in
                if stacked {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label)
                            .scaledFont(.callout)
                            .foregroundStyle(row.depth > 0 ? .secondary : .primary)
                        figureLines(row.amounts, symbol: false, font: .callout)
                    }
                    .padding(.leading, CGFloat(row.depth) * 16)
                    .padding(.vertical, 2)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.label)
                            .scaledFont(.callout)
                            .foregroundStyle(row.depth > 0 ? .secondary : .primary)
                            .padding(.leading, CGFloat(row.depth) * 16)
                        Spacer(minLength: 12)
                        ForEach(Array(row.amounts.enumerated()), id: \.offset) { _, value in
                            Text(StatementFormat.amount(value, code: statement.currencyCode, symbol: false))
                                .scaledFont(.callout)
                                .monospacedDigit()
                                .frame(width: amountWidth, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            if let totalLabel = note.totalLabel {
                Group {
                    if stacked {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(totalLabel).scaledFont(.callout, weight: .medium)
                            figureLines(note.totalAmounts, symbol: true, font: .callout, weight: .medium)
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(totalLabel).scaledFont(.callout, weight: .medium)
                            Spacer(minLength: 12)
                            ForEach(Array(note.totalAmounts.enumerated()), id: \.offset) { _, value in
                                Text(StatementFormat.amount(value, code: statement.currencyCode, symbol: true))
                                    .scaledFont(.callout, weight: .medium)
                                    .monospacedDigit()
                                    .frame(width: amountWidth, alignment: .trailing)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
                .overlay(alignment: .top) { singleRule }
            }
        }
    }
}

// MARK: - Screen wrapper

/// The statement in the report screen: scrolled, page-width, printable.
struct StatementView: View {
    let statement: Statement

    var body: some View {
        ScrollView {
            StatementSheet(statement: statement)
                .padding(28)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
    }
}
