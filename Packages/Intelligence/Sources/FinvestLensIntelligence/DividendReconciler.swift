//
//  DividendReconciler.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The figures a model read off a dividend statement, before they are trusted.
///
/// Plain strings, so the checking below is reachable — and testable — without
/// Apple Intelligence being present.
struct RawDividendFigures {
    var security = ""
    var ticker = ""
    var paymentDate = ""
    var franked = ""
    var unfranked = ""
    var credits = ""
    var net = ""
}

/// Checks a dividend statement's figures against the page and recovers the one
/// the model misread.
enum DividendReconciler {

/// Turns the model's answer into details, refusing figures that are not
/// printed on the statement and recovering the one that is missing.
///
/// Split out and pure so the recovery can be tested without the model —
/// the arithmetic below is the part that has to be right.
///
/// A dividend statement carries its own proof: the unfranked and franked
/// components add up to the payment. That makes a single wrong component
/// recoverable rather than merely detectable. When one of the two is not
/// printed on the page and the other is, the missing one is the
/// difference — which is how a Plato statement reporting its franked
/// amount as `55107.272` (the dividend rate and the share count run
/// together) comes back as the $590.00 the page actually shows.
///
/// Recovery is deliberately narrow. If *both* components are printed and
/// still do not add up, nothing is invented: the mismatch stays and
/// ``DividendStatementDetails/componentsMatchPayment`` reports it, because
/// a statement that contradicts itself is a thing a person needs to see.
static func details(from model: RawDividendFigures, printedIn text: String) -> DividendStatementDetails {
    let source = SourceGrounding.folded(text)
    /// The amount, or `nil` when the page does not show it.
    func printed(_ raw: String) -> Decimal? {
        guard let value = IntelligenceParsing.amount(raw),
              SourceGrounding.isAmountPrinted(raw, in: source) else { return nil }
        return value
    }

    var net = printed(model.net)
    var franked = printed(model.franked)
    var unfranked = printed(model.unfranked)

    /// A figure the arithmetic produces is only accepted if the page
    /// shows it too. Derivation is the one place here that *creates* a
    /// number rather than refusing one, and a created number can
    /// manufacture the very agreement ``componentsMatchPayment`` exists to
    /// test: asked in the wrong field order the model once returned the
    /// $0.0055 rate for both components, and their sum was duly recorded
    /// as a payment of $0.011 — self-consistent, and nonsense. Requiring
    /// the result to be printed costs nothing real, because the figure
    /// being recovered is one the statement prints and the model misread.
    func derived(_ value: Decimal) -> Decimal? {
        SourceGrounding.isAmountPrinted("\(value)", in: source) ? value : nil
    }

    if let known = net, known != 0 {
        // The payment is printed, so a component that is not can be had
        // from the difference.
        if franked == nil, let other = unfranked { franked = derived(known - other) }
        else if unfranked == nil, let other = franked { unfranked = derived(known - other) }
    } else if let franked, let unfranked, franked + unfranked != 0 {
        // The payment is *not* printed — the model computed one, typically
        // by netting off the franking credits it was just told about. The
        // components are the better evidence.
        //
        // This is the sum before withholding tax, so on a statement that
        // deducts any (rare here, and never on a fully franked resident
        // holding) the payment would be overstated by the deduction. That
        // is the accepted cost of the alternative being zero, which reads
        // downstream as a dividend of nothing rather than as a problem.
        net = derived(franked + unfranked)
    }

    return DividendStatementDetails(
        securityName: model.security,
        ticker: model.ticker.uppercased(),
        paymentDate: IntelligenceParsing.date(model.paymentDate),
        frankedAmount: franked ?? 0,
        unfrankedAmount: unfranked ?? 0,
        // Never recovered: franking credits are attached to the dividend,
        // not part of it, so no arithmetic on the page constrains them. A
        // figure that is not printed is simply not claimed.
        frankingCredits: printed(model.credits) ?? 0,
        netPayment: net ?? 0
    )
}
}
