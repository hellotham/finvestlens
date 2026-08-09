//
//  DividendExtractor.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The details read from a dividend / distribution statement.
///
/// Follows Australian dividend statements (franked/unfranked components and
/// franking credits) but degrades gracefully for other markets: unfranked-only
/// statements simply have zero franked amounts.
public struct DividendStatementDetails: Sendable {
    public var securityName: String
    public var ticker: String
    public var paymentDate: Date?
    /// Fully franked component of the dividend.
    public var frankedAmount: Decimal
    /// Unfranked component of the dividend.
    public var unfrankedAmount: Decimal
    /// Franking (imputation) credits attached — not part of the cash payment.
    public var frankingCredits: Decimal
    /// Cash actually paid to the shareholder.
    public var netPayment: Decimal

    public init(securityName: String = "", ticker: String = "", paymentDate: Date? = nil,
                frankedAmount: Decimal = 0, unfrankedAmount: Decimal = 0,
                frankingCredits: Decimal = 0, netPayment: Decimal = 0) {
        self.securityName = securityName
        self.ticker = ticker
        self.paymentDate = paymentDate
        self.frankedAmount = frankedAmount
        self.unfrankedAmount = unfrankedAmount
        self.frankingCredits = frankingCredits
        self.netPayment = netPayment
    }

    /// The statement's own arithmetic check: cash paid should equal the sum
    /// of the components. Surfaced in review UI when it doesn't.
    public var componentsMatchPayment: Bool {
        netPayment == 0 || frankedAmount + unfrankedAmount == netPayment
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// Reads a dividend statement PDF into ``DividendStatementDetails``
/// (`FR-AI-04`), so franked/unfranked components and franking credits are
/// booked correctly instead of as one opaque deposit.
@available(macOS 26.0, iOS 26.0, *)
public enum DividendExtractor {

    /// Field order matters, and the order that works is not the printed one.
    /// Asking for Unfranked before Franked — as the table prints them — made
    /// every Plato statement come back as the $0.0055 rate in all three
    /// columns and NAB's unfranked amount as 85, the cents figure. Franked
    /// first holds the row in place. Measured, not reasoned.
    @Generable
    struct ModelDividend {
        @Guide(description: "Company or fund name paying the dividend")
        var security: String
        @Guide(description: "ASX/stock ticker code if shown, else empty")
        var ticker: String
        @Guide(description: "Payment date in yyyy-MM-dd format, empty if not shown")
        var paymentDate: String
        @Guide(description: "The figure in the Franked Amount column of the table, exactly as printed. Not the rate per share, and not the number of shares.")
        var frankedAmount: String
        @Guide(description: "The figure in the Unfranked Amount column of the table, exactly as printed.")
        var unfrankedAmount: String
        @Guide(description: "The figure in the Franking Credit column of the table, exactly as printed. Only 0 if that column is absent.")
        var frankingCredits: String
        @Guide(description: "Net cash payment to the shareholder (total paid)")
        var netPayment: String
    }

    public static func extract(text: String) async throws -> DividendStatementDetails {
        guard IntelligenceAvailability.current().isAvailable else {
            if case .unavailable(let reason) = IntelligenceAvailability.current() {
                throw IntelligenceError.unavailable(reason)
            }
            throw IntelligenceError.unavailable("Apple Intelligence is not available.")
        }

        // Two sentences, both bought with measurements on real statements.
        //
        // The franking credit has its own column whose header wraps across two
        // lines — "Franking" above "Credit" — and without being told that, the
        // model misses the column on every statement tried: it returned 0 with
        // $728.57 (NAB) and $252.86 (Plato) printed on the page. Naming the
        // column fixes both.
        //
        // "Never subtract" earns its place too. Mentioning franking credits at
        // all makes the model want to net them off the payment, and it will
        // report a $1,700.00 dividend as $971.43 given the chance.
        //
        // What is deliberately NOT here: a paragraph telling the model to
        // ignore the prose restatement of the calculation. It does fix the
        // franked amount, and on the NAB statement it also makes the request
        // fail outright — `refusal`, "May contain sensitive content". The
        // reconciliation below fixes that figure without asking the model for
        // anything, so the prompt stays short enough not to trip the guardrail.
        let session = LanguageModelSession(instructions: """
            You read dividend and distribution statements from share registries. \
            Extract the amounts exactly as printed. The franking credit has its \
            own column in the same table, headed "Franking Credit", which may be \
            split across two lines — report it when it is there. Franking \
            credits are listed separately from the cash payment: never add them \
            to it and never subtract them from it.
            """)
        do {
            let model = try await session.respond(
                to: "Dividend statement:\n\n\(String(text.prefix(6000)))",
                generating: ModelDividend.self,
                options: GenerationOptions(sampling: .greedy)
            ).content
            return DividendReconciler.details(
                from: RawDividendFigures(
                    security: model.security, ticker: model.ticker,
                    paymentDate: model.paymentDate, franked: model.frankedAmount,
                    unfranked: model.unfrankedAmount, credits: model.frankingCredits,
                    net: model.netPayment),
                printedIn: text)
        } catch {
            throw IntelligenceError.wrap(error)
        }
    }
}
#endif
