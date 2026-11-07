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
    var colour: Color { self == .buy ? .green : .negativeAmount }
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
