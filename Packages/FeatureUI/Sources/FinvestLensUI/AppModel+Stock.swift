//
//  AppModel+Stock.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// Errors from the Stock Transaction Assistant.
public enum StockEntryError: Error, Equatable {
    case noBook
    case unknownAccount
    case invalidInput
}

@MainActor
extension AppModel {

    // MARK: Typed account lists for the assistant

    /// Security (stock / mutual-fund) accounts.
    public var securityAccountNodes: [AccountNode] {
        postableAccounts.filter { $0.typeName == "Stock" || $0.typeName == "Mutual" }
    }

    /// The **portfolios**: every account that directly parents a security
    /// account — a broker, a super fund, a self-managed pool.
    ///
    /// A portfolio is not a type in the book, because GnuCash has no such type.
    /// It is a shape: someone who holds shares through two brokers files them
    /// under two parents, and those parents are the grouping they already think
    /// in. Derived rather than configured for exactly that reason — there is
    /// nothing to set up, and a book that keeps every holding under one parent
    /// simply has one portfolio.
    ///
    /// Sorted by the name shown, so the tabs and the sidebar agree on order.
    public var portfolioAccounts: [AccountNode] {
        // **Memoised on the book revision.** Reported 16 Aug 2026: "investments
        // took a long time to display, so there is a performance issue" — and
        // this was it. `standingTabs` calls this to build the Investments tab
        // strip, and `tabs(in:)` is read by `openTabs`, `activeTabIndex` and
        // `storedSelection`, several times per SwiftUI pass. Each call walked
        // `postableAccounts` and then ran a full recursive `accountTree` search
        // **per portfolio** — on the reference book that is fifteen DFS walks
        // of a 565-account tree, repeated on every redraw.
        //
        // **Only portfolios with something still in them**, unless closed
        // positions are being shown. Reported 16 Aug 2026: "Investments shows a
        // lot of portfolio tabs, many are closed positions." A broker you last
        // held a share through in 2014 is history, not a place you work; the
        // reference book has fifteen parents and only some are live. The
        // existing Show Closed Positions toggle governs it, so one control
        // means one thing in the tab strip and the holdings table alike.
        let showClosed = showsClosedPositions
        if portfolioCacheRevision == bookRevision,
           portfolioCacheShowedClosed == showClosed { return portfolioCache }
        guard let book else { return [] }
        var seen = Set<GncGUID>()
        var parents: [GncGUID] = []
        for node in securityAccountNodes {
            // A holding is open when units remain. `balance` is the account's
            // own commodity, so this is a share count, not a valuation — a
            // security nobody has priced is still held.
            guard showClosed || node.balance != 0 else { continue }
            guard let parent = book.account(with: node.id)?.parent,
                  seen.insert(parent.guid).inserted else { continue }
            parents.append(parent.guid)
        }
        // One walk of the tree for all of them, not one walk each.
        let wanted = Set(parents)
        var found: [GncGUID: AccountNode] = [:]
        func visit(_ nodes: [AccountNode]) {
            for node in nodes {
                if wanted.contains(node.id) { found[node.id] = node }
                if let children = node.children { visit(children) }
            }
        }
        visit(accountTree)
        let out = parents.compactMap { found[$0] }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        portfolioCache = out
        portfolioCacheRevision = bookRevision
        portfolioCacheShowedClosed = showClosed
        return out
    }

    /// The securities held in one portfolio — the commodities of the security
    /// accounts directly beneath it.
    public func securityCommodities(inPortfolio id: GncGUID) -> Set<Commodity> {
        guard let book, let parent = book.account(with: id) else { return [] }
        return Set(parent.children
            .filter { $0.type.isSecurityType }
            .map(\.commodity))
    }

    /// Cash / settlement accounts (bank, cash, other assets).
    public var settlementAccountNodes: [AccountNode] {
        postableAccounts.filter { ["Bank", "Cash", "Asset"].contains($0.typeName) }
    }

    /// Income accounts (for dividends).
    public var incomeAccountNodes: [AccountNode] {
        postableAccounts.filter { $0.typeName == "Income" }
    }

    /// Expense accounts (for commission / fees).
    public var expenseAccountNodes: [AccountNode] {
        postableAccounts.filter { $0.typeName == "Expense" }
    }

    // MARK: Recording

    /// Records a security transaction built by ``StockTransaction`` and adds it
    /// to the book (`FR-INV-05`).
    ///
    /// - Parameters carry share/price/amount/commission as appropriate for
    ///   `action`; unused ones are ignored. The transaction currency is the
    ///   settlement account's commodity.
    @discardableResult
    public func recordStockTransaction(
        action: StockActionKind,
        securityID: GncGUID?,
        settlementID: GncGUID?,
        incomeID: GncGUID? = nil,
        commissionID: GncGUID? = nil,
        shares: Decimal = 0,
        pricePerShare: Decimal = 0,
        amount: Decimal = 0,
        commission: Decimal = 0,
        splitNew: Decimal = 0,
        splitOld: Decimal = 0,
        date: Date,
        description: String,
        memo: String = "",
        reference: String = "",
        // Whether `reference` is a broker-unique id. `true` for a reference a
        // person typed into the Stock Transaction sheet, which is a deliberate
        // act; the import path passes the staged row's own flag, because QIF
        // puts the *action verb* in that field — see below.
        referenceIsBankUnique: Bool = true
    ) throws -> GncGUID {
        guard let book else { throw StockEntryError.noBook }
        let commissionAccount = commissionID.flatMap { book.account(with: $0) }

        let txn: Transaction
        switch action {
        case .buy:
            guard let security = securityID.flatMap({ book.account(with: $0) }),
                  let cash = settlementID.flatMap({ book.account(with: $0) })
            else { throw StockEntryError.unknownAccount }
            guard shares > 0, pricePerShare > 0 else { throw StockEntryError.invalidInput }
            txn = StockTransaction.buy(
                security: security, cash: cash, commissionAccount: commissionAccount,
                shares: shares, pricePerShare: pricePerShare, commission: commission,
                date: date, currency: cash.commodity, description: description, memo: memo)

        case .sell:
            guard let security = securityID.flatMap({ book.account(with: $0) }),
                  let cash = settlementID.flatMap({ book.account(with: $0) })
            else { throw StockEntryError.unknownAccount }
            guard shares > 0, pricePerShare > 0 else { throw StockEntryError.invalidInput }
            txn = StockTransaction.sell(
                security: security, cash: cash, commissionAccount: commissionAccount,
                shares: shares, pricePerShare: pricePerShare, commission: commission,
                date: date, currency: cash.commodity, description: description, memo: memo)

        case .dividend:
            guard let income = incomeID.flatMap({ book.account(with: $0) }),
                  let cash = settlementID.flatMap({ book.account(with: $0) })
            else { throw StockEntryError.unknownAccount }
            guard amount > 0 else { throw StockEntryError.invalidInput }
            txn = StockTransaction.dividend(
                income: income, cash: cash, amount: amount,
                date: date, currency: cash.commodity, description: description, memo: memo)

        case .reinvestDividend:
            guard let income = incomeID.flatMap({ book.account(with: $0) }),
                  let security = securityID.flatMap({ book.account(with: $0) })
            else { throw StockEntryError.unknownAccount }
            guard amount > 0, shares > 0 else { throw StockEntryError.invalidInput }
            // The reinvested dividend is denominated in the income account's
            // currency (the cash that would otherwise have been received).
            txn = StockTransaction.reinvestDividend(
                income: income, security: security, shares: shares, amount: amount,
                date: date, currency: income.commodity, description: description, memo: memo)

        case .split:
            guard let security = securityID.flatMap({ book.account(with: $0) })
            else { throw StockEntryError.unknownAccount }
            guard splitNew > 0, splitOld > 0 else { throw StockEntryError.invalidInput }
            let current = book.costBasis(for: security).remainingQuantity
            guard current > 0 else { throw StockEntryError.invalidInput }
            let added = current * (splitNew / splitOld - 1)
            guard added != 0 else { throw StockEntryError.invalidInput }
            txn = StockTransaction.stockSplit(
                security: security, addedShares: added,
                date: date, currency: reportCurrency, description: description, memo: memo)

        case .returnOfCapital:
            guard let security = securityID.flatMap({ book.account(with: $0) }),
                  let cash = settlementID.flatMap({ book.account(with: $0) })
            else { throw StockEntryError.unknownAccount }
            guard amount > 0 else { throw StockEntryError.invalidInput }
            txn = StockTransaction.returnOfCapital(
                security: security, cash: cash, amount: amount,
                date: date, currency: cash.commodity, description: description, memo: memo)
        }

        guard txn.isBalanced else { throw StockEntryError.invalidInput }
        editing([txn.guid], named: "Add Stock Transaction") {
            // The broker's FITID rides in `online_id`, exactly as cash imports
            // stamp it — it is the only thing that lets a re-imported
            // overlapping statement recognise an already-posted trade
            // (investment rows never pass through the cash matcher).
            //
            // Only a genuinely unique id may go there, for the same reason the
            // cash path checks: `importedInvestmentReferences()` harvests every
            // `online_id` in the book and the review sheet drops any row whose
            // reference is among them. QIF writes the action verb into that
            // field, so the first imported "Buy" used to claim the slot and
            // every later Buy in every later file was silently dropped as
            // already-recorded.
            if referenceIsBankUnique, !reference.isEmpty {
                txn.splits.first?.kvp["online_id"] = .string(reference)
            }
            book.addTransaction(txn)
        }
        return txn.guid
    }
}
