//
//  PriceChartMarks.swift
//  FinvestLens — FeatureUI
//
//  How a trade is marked on a price chart, and an entry of the chart's key:
//  one source for both price charts — the security page's and Price
//  History's — and for each chart's key, so a key cannot show a shape or a
//  colour its chart does not draw. In 1.2 both did: the security page keyed a
//  sale as a triangle while drawing a diamond, and Price History keyed it in
//  the accent colour while drawing it red (seen 4 Nov 2026).
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Charts
import SwiftUI

/// A buy or a sale on a price chart: the chart's mark, and the key's picture
/// of it. The two differ in shape as well as colour, so colour is never the
/// only thing that tells them apart.
enum TradeMark: CaseIterable {
    case buy, sale

    init(isBuy: Bool) { self = isBuy ? .buy : .sale }

    var chartSymbol: BasicChartSymbolShape { self == .buy ? .triangle : .diamond }
    /// ``chartSymbol``'s shape as an SF Symbol, for the key.
    var keySymbol: String { self == .buy ? "triangle.fill" : "diamond.fill" }
    /// The money tokens, measured for contrast (Appearance.swift): system
    /// green, which buys were drawn in, is 2.2:1 on a white row — under WCAG
    /// 1.4.11's 3:1 for a mark the chart is read by.
    var colour: Color { self == .buy ? .positiveAmount : .negativeAmount }
    /// The value a chart plots the mark by (`.symbol(by:)`): what VoiceOver's
    /// details and Audio Graph name the point, and the key's word for it.
    var name: String { self == .buy ? String(localized: "Buy") : String(localized: "Sell") }
}

/// One entry of a chart's key: a picture of the mark, then its name. The
/// picture is hidden from VoiceOver; the name is what is read.
struct ChartKeyMark: View {
    private let label: Text
    private let symbol: String
    private let colour: Color

    init(_ label: LocalizedStringKey, symbol: String, colour: Color) {
        self.label = Text(label)
        self.symbol = symbol
        self.colour = colour
    }

    /// For a name already in the reader's language — a series the chart
    /// labels with a localized string or a ticker.
    init(verbatim label: String, symbol: String, colour: Color) {
        self.label = Text(verbatim: label)
        self.symbol = symbol
        self.colour = colour
    }

    init(_ mark: TradeMark, _ label: LocalizedStringKey) {
        self.init(label, symbol: mark.keySymbol, colour: mark.colour)
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).foregroundStyle(colour).accessibilityHidden(true)
            label
        }
    }
}

/// A chart's key: its entries along a line, wrapping onto the next where they
/// do not fit, as Charts' own legend did. A key that fell back to one entry a
/// line took a third of Price History's 240-point chart on a phone at the
/// default text size, and all but a sliver at accessibility sizes (measured
/// in a replica, 7 Nov 2026); wrapped, the same entries take two lines.
struct ChartKey<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        WrappingRow(spacing: 12, lineSpacing: 4) { content }
    }
}

/// Lays its subviews out from the leading edge, each at its own size, starting
/// a new line where the next would run past the width offered. One wider than
/// a whole line is given the line's width, and its text wraps there: measured
/// at its own width it ran off a phone's screen at large text sizes, in German
/// first, and widened the page under it (found in review, 8 Nov 2026).
struct WrappingRow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = lines(of: subviews, within: width)
        let widest = lines.map(\.width).max() ?? 0
        return CGSize(width: width.isFinite ? min(widest, width) : widest,
                      height: lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(lines.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(of: subviews, within: bounds.width) {
            var x = bounds.minX
            for (index, size) in zip(line.members, line.sizes) {
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var members: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// A subview at its own width, or at `width` when that is all a line has.
    private func size(of subview: LayoutSubview, within width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard width.isFinite, ideal.width > width else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    private func lines(of subviews: Subviews, within width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = size(of: subviews[index], within: width)
            if !line.members.isEmpty, line.width + spacing + size.width > width {
                lines.append(line)
                line = Line()
            }
            line.width += (line.members.isEmpty ? 0 : spacing) + size.width
            line.height = max(line.height, size.height)
            line.members.append(index)
            line.sizes.append(size)
        }
        if !line.members.isEmpty { lines.append(line) }
        return lines
    }
}
