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

    /// The Australian corporate tax rate a fully franked dividend is grossed
    /// up at. Used only to *guess where to look* — see
    /// ``grossedUpCredit(on:printedIn:)`` — never to state a figure.
    static let corporateTaxRate = Decimal(30) / Decimal(100)

    /// The franking credit implied by a fully franked dividend, but only if
    /// the page turns out to print it.
    ///
    /// The model reads the credit column reliably on some registries and
    /// misses it on others — its header wraps as "Franking" above "Credit",
    /// and where the surrounding text is noisy it goes unread, leaving a
    /// statement that prints $252.86 reported as nothing. A fully franked
    /// dividend implies its credit exactly, at franked × rate / (1 − rate), so
    /// the figure can be computed and then *looked for*.
    ///
    /// The distinction matters and is the whole design. This does not claim
    /// the computed value: it uses it as a search key, and returns it only
    /// when the statement shows that number. So a partly franked dividend,
    /// where the formula does not hold, finds nothing and stays unclaimed —
    /// which is the right answer, since the credit would be some other figure.
    /// Nothing is ever reported that is not on the page.
    static func grossedUpCredit(on franked: Decimal?, printedIn source: String) -> Decimal? {
        guard let franked, franked > 0 else { return nil }
        var raw = franked * corporateTaxRate / (1 - corporateTaxRate)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &raw, 2, .plain)
        // Demonstrably printed: this returns a *computed* credit, so an
        // abstention must read as "not proven" rather than "fine".
        guard rounded > 0,
              SourceGrounding.isAmountDemonstrablyPrinted("\(rounded)", in: source)
        else { return nil }
        return rounded
    }

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
            // Demonstrably printed, not merely un-refused: this call *accepts*
            // a figure the arithmetic invented, so the short-amount abstention
            // in `isAmountPrinted` would wave through anything under $10.
            SourceGrounding.isAmountDemonstrablyPrinted("\(value)", in: source) ? value : nil
        }

        if let known = net, known != 0 {
            // The payment is printed, so a component that is not can be had
            // from the difference.
            if franked == nil, let other = unfranked { franked = derived(known - other) }
            else if unfranked == nil, let other = franked { unfranked = derived(known - other) }

            // If one component already accounts for the whole payment, the other
            // is necessarily zero — they sum to it. Worth stating explicitly,
            // because the figure that turns up in the column that should be empty
            // is a *rate* read as an amount: NAB capital-note statements print a
            // distribution of $0.9338 per note, and that figure is on the page, so
            // the printed-check has no grounds to refuse it. The arithmetic does.
            if franked == known, unfranked != 0 { unfranked = 0 }
            else if unfranked == known, franked != 0 { franked = 0 }
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
            frankingCredits: printed(model.credits).flatMap { credit in
                // A reported zero is treated as *absent*, not as an answer: the
                // model says "0.00" for a column it failed to find, and at three
                // digits that is too short for the printed-check to reject, so it
                // would otherwise stand as a claim that the statement shows no
                // credit when it shows one.
                guard credit != 0 else { return nil }
                // And a credit cannot be as large as the dividend it attaches to.
                // At the 30% corporate rate it is three sevenths of it, at the
                // 25% base rate one third; there is no rate at which they are
                // equal. On a real NAB capital-note statement the model returned
                // the franked amount in both columns, and because that figure is
                // genuinely printed the grounding check had no objection.
                guard let franked, credit < franked else { return nil }
                return credit
            } ?? grossedUpCredit(on: franked, printedIn: source) ?? 0,
            netPayment: net ?? 0
        )
    }
}
